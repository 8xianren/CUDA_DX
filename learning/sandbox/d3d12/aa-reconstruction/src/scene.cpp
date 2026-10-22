#include "scene.h"
#include <cstring>
#include <cmath>
#include <stdexcept>
using namespace DirectX;
namespace aa {
// 五行依次对应color/motionDepth/linearDepth/velocity/reactive的清除值。
// guide深度用100表示尚未写入场景的远处/背景候选；它不是D32附件的清除值1。
static const float SceneClear[5][4]={{.025f,.04f,.08f,1},{0,0,100,100},{100,0,0,1},{0,0,0,1},{0,0,0,1}};
// 顶点是紧密的float3 position + float2 UV，共20B，输入布局的UV偏移因此为12B。
struct V{float x,y,z,u,v;};
// 每次draw一份常量：current矩阵64B、previous矩阵64B，color/options/jitter
// 各16B，共176B有效数据；末尾80B填充使对象步长为256B。D3D12根CBV的GPU地址
// 必须256B对齐，故不能把下一对象放在176B处。HLSL相应矩阵显式row_major，
// 与XMStoreFloat4x4的行主序及mul(rowVector,matrix)一致，不需要暗中转置。
struct alignas(256) Object{XMFLOAT4X4 current,previous;float color[4],options[4],jitter[4];char padding[80];};
static_assert(sizeof(Object)==256);
// 本场景相机只沿X平移：View是相机世界变换的逆，所以平移量为-x。
// DirectXMath采用行向量组合：world * view * projection。LH透视沿+Z观察，
// 垂直FOV=45度，宽高比w/h，near=.1、far=100；D3D深度映射到0..1。
// 此函数刻意不注入jitter，使前后矩阵能产生纯几何motion，jitter由VS另加。
static XMMATRIX Camera(float x,UINT w,UINT h,float outputAspect){return XMMatrixTranslation(-x,0,0)*XMMatrixPerspectiveFovLH(XM_PIDIV4,outputAspect>0?outputAspect:float(w)/h,.1f,100.f);}
Scene::Scene(UploadContext& context,const fs::path& p):c(context),shaders(p){
    // root参数0是b0的GPU虚拟地址（不占CBV描述符槽），参数1是t0的SRV表。
    // sampler s0为静态linear+mip-linear、wrap；它被root signature拥有，
    // 无需每帧向另一个sampler heap写描述符。checker是合成线性灰度纹理。
    D3D12_DESCRIPTOR_RANGE range{D3D12_DESCRIPTOR_RANGE_TYPE_SRV,1,0,0,0};D3D12_ROOT_PARAMETER rp[2]{};
    rp[0].ParameterType=D3D12_ROOT_PARAMETER_TYPE_CBV;rp[0].Descriptor.ShaderRegister=0;
    rp[1].ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;rp[1].DescriptorTable={1,&range};
    D3D12_STATIC_SAMPLER_DESC sm{};sm.Filter=D3D12_FILTER_MIN_MAG_MIP_LINEAR;sm.AddressU=sm.AddressV=sm.AddressW=D3D12_TEXTURE_ADDRESS_MODE_WRAP;sm.MaxLOD=D3D12_FLOAT32_MAX;sm.ShaderRegister=0;sm.ShaderVisibility=D3D12_SHADER_VISIBILITY_PIXEL;
    D3D12_ROOT_SIGNATURE_DESC rd{2,rp,1,&sm,D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT};root=Root(c,rd);
    rtv=Heap(c,D3D12_DESCRIPTOR_HEAP_TYPE_RTV,5);dsv=Heap(c,D3D12_DESCRIPTOR_HEAP_TYPE_DSV,1);checkerSrv=Heap(c,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,1,true);
    // 同一个单位四边形由每个对象矩阵复用；24条窄线也复用这份顶点数据。
    // 六个顶点组成两个triangle，不需要索引buffer。顶点只上传一次，UPLOAD
    // 资源直接作为VB是小型教学场景的简化；大场景一般复制到DEFAULT堆。
    const V data[]={{-1,-1,0,0,1},{-1,1,0,0,0},{1,-1,0,1,1},{1,-1,0,1,1},{-1,1,0,0,0},{1,1,0,1,0}};
    vertices=MakeResource(c,BufferDesc(sizeof(data)),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);void* mem;D3D12_RANGE noRead{0,0};Check(vertices->Map(0,&noRead,&mem),"vertices Map");memcpy(mem,data,sizeof(data));vertices->Unmap(0,nullptr);vb={vertices->GetGPUVirtualAddress(),sizeof(data),sizeof(V)};
    // 固定容量为96个对象，当前场景31次draw（1背景+24细线+1植被+1移动物+4粒子）。
    // 一帧内顺序写不同槽，避免后一次CPU写覆盖前一次draw尚未读取的常量；
    // 跨帧由宿主Fence保证安全，多帧引擎应换成按frame分区的上传环。
    constants=MakeResource(c,BufferDesc(256*96),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);
    D3D12_RESOURCE_DESC td{};td.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;td.Width=td.Height=256;td.DepthOrArraySize=1;td.MipLevels=9;td.Format=DXGI_FORMAT_R8G8B8A8_UNORM;td.SampleDesc.Count=1;
    checker=MakeResource(c,td,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_COPY_DEST);
    // 256→128→...→1共9级mip，各级有独立footprint；Offset和RowPitch由设备
    // 返回，不能把它们假定为紧密排列。checkerUpload暂存所有级的CPU数据。
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp[9];UINT rows[9];UINT64 rowBytes[9],bytes;c.device->GetCopyableFootprints(&td,0,9,0,fp,rows,rowBytes,&bytes);checkerUpload=MakeResource(c,BufferDesc(bytes),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);
    uint8_t* dst;Check(checkerUpload->Map(0,&noRead,reinterpret_cast<void**>(&dst)),"mips Map");
    // 每格8×8纹素的棋盘，逐级2×2 box平均。不能让mip1就全变灰，
    // 否则虽然“存在高频纹理”，实际画面却没有可评测的纹理细节。
    std::vector<uint8_t> mipPixels(256*256);for(UINT y=0;y<256;++y)for(UINT x=0;x<256;++x)mipPixels[y*256+x]=((x/8+y/8)&1)?235:20;
    UINT mipWidth=256;for(UINT mip=0;mip<9;++mip){
        for(UINT y=0;y<mipWidth;++y)for(UINT x=0;x<mipWidth;++x){auto* q=dst+fp[mip].Offset+y*fp[mip].Footprint.RowPitch+x*4;q[0]=q[1]=q[2]=mipPixels[y*mipWidth+x];q[3]=255;}
        if(mipWidth>1){UINT next=mipWidth/2;std::vector<uint8_t> reduced(next*next);for(UINT y=0;y<next;++y)for(UINT x=0;x<next;++x){unsigned sum=0;for(UINT dy=0;dy<2;++dy)for(UINT dx=0;dx<2;++dx)sum+=mipPixels[(2*y+dy)*mipWidth+2*x+dx];reduced[y*next+x]=uint8_t((sum+2)/4);}mipPixels=std::move(reduced);mipWidth=next;}
    }
    // Copy逐级将UPLOAD数据传入纹理；统一转PIXEL_SHADER_RESOURCE后建立覆盖
    // 全9级的SRV。SubmitWait覆盖拷贝和transition，随后Reset上传资源才安全。
    checkerUpload->Unmap(0,nullptr);for(UINT i=0;i<9;++i){D3D12_TEXTURE_COPY_LOCATION a{},b{};a.pResource=checker.Get();a.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;a.SubresourceIndex=i;b.pResource=checkerUpload.Get();b.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;b.PlacedFootprint=fp[i];c.list->CopyTextureRegion(&a,0,0,0,&b,nullptr);}Transition(c,checker.Get(),D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
    D3D12_SHADER_RESOURCE_VIEW_DESC sv{};sv.Format=td.Format;sv.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2D;sv.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;sv.Texture2D.MipLevels=9;c.device->CreateShaderResourceView(checker.Get(),&sv,Cpu(c,checkerSrv.Get()));c.SubmitWait();checkerUpload.Reset();
}
ID3D12PipelineState* Scene::Pso(UINT samples,DXGI_FORMAT color,bool a2c,bool transparent){
    // sample数、RT0格式、A2C和混合模式都属于PSO不可变状态，作为缓存键。
    // MRT其余格式固定；不能拿1x的PSO绘制4x附件，也不能只检查RT0支持MSAA。
    uint64_t key=samples|(uint64_t(color)<<8)|(uint64_t(a2c)<<32)|(uint64_t(transparent)<<33);if(psos.count(key))return psos[key].Get();
    auto vs=Shader(shaders/"scene_vs.dxil"),ps=Shader(shaders/"scene_ps.dxil");D3D12_GRAPHICS_PIPELINE_STATE_DESC d{};d.pRootSignature=root.Get();d.VS={vs.data(),vs.size()};d.PS={ps.data(),ps.size()};
    D3D12_INPUT_ELEMENT_DESC input[]={{"POSITION",0,DXGI_FORMAT_R32G32B32_FLOAT,0,0,D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,0},{"TEXCOORD",0,DXGI_FORMAT_R32G32_FLOAT,0,12,D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,0}};d.InputLayout={input,2};
    d.BlendState.AlphaToCoverageEnable=a2c;d.BlendState.IndependentBlendEnable=TRUE;
    // IndependentBlend让只有RT0参与透明颜色混合：src*alpha+dst*(1-alpha)。
    // motion/depth/reactive不能按颜色alpha同样混合，因此保留最后写入的guide。
    // 这是单层透明guide近似，无法描述背景与前景粒子的多层运动/深度；FSR可
    // 用reactive区域降低旧颜色权重，但该标记不是多层透明的完整解决方案。
    for(auto& b:d.BlendState.RenderTarget){b.RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;b.SrcBlend=D3D12_BLEND_ONE;b.DestBlend=D3D12_BLEND_ZERO;b.BlendOp=D3D12_BLEND_OP_ADD;b.SrcBlendAlpha=D3D12_BLEND_ONE;b.DestBlendAlpha=D3D12_BLEND_ZERO;b.BlendOpAlpha=D3D12_BLEND_OP_ADD;}
    if(transparent){auto& b=d.BlendState.RenderTarget[0];b.BlendEnable=TRUE;b.SrcBlend=D3D12_BLEND_SRC_ALPHA;b.DestBlend=D3D12_BLEND_INV_SRC_ALPHA;}
    // 普通Z用LESS：更近片元覆盖更远片元。透明仍做深度测试但不写D32，
    // 所以线性guide可来自粒子，而硬件深度仍来自其后的不透明表面。
    d.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;d.RasterizerState.CullMode=D3D12_CULL_MODE_NONE;d.RasterizerState.DepthClipEnable=TRUE;d.RasterizerState.MultisampleEnable=samples>1;
    d.DepthStencilState.DepthEnable=TRUE;d.DepthStencilState.DepthWriteMask=transparent?D3D12_DEPTH_WRITE_MASK_ZERO:D3D12_DEPTH_WRITE_MASK_ALL;d.DepthStencilState.DepthFunc=D3D12_COMPARISON_FUNC_LESS;
    d.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;d.SampleMask=UINT_MAX;d.SampleDesc.Count=samples;d.NumRenderTargets=5;
    // slot0 RGBA16F线性HDR；slot1 RGBA32F保留UV+两个线性深度的精度；
    // slot2 R32F供TAA存上一帧线性深度；slot3 RG16F为SDK像素motion；
    // slot4 R8_UNORM是[0,1]reactive。颜色和深度附件样本数必须全部相同。
    d.RTVFormats[0]=color;d.RTVFormats[1]=DXGI_FORMAT_R32G32B32A32_FLOAT;d.RTVFormats[2]=DXGI_FORMAT_R32_FLOAT;d.RTVFormats[3]=DXGI_FORMAT_R16G16_FLOAT;d.RTVFormats[4]=DXGI_FORMAT_R8_UNORM;d.DSVFormat=DXGI_FORMAT_D32_FLOAT;
    Check(c.device->CreateGraphicsPipelineState(&d,IID_PPV_ARGS(&psos[key])),"F Scene PSO");return psos[key].Get();
}
Targets Scene::Create(UINT w,UINT h,UINT samples,DXGI_FORMAT format){
    // 对每一种实际绑定格式查询NumQualityLevels；quality=0是本课采用的质量级。
    // 某格式/sample组合不支持时直接失败，不能静默降成1x后仍标成4x MSAA。
    for(auto f:{format,DXGI_FORMAT_R32G32B32A32_FLOAT,DXGI_FORMAT_R32_FLOAT,DXGI_FORMAT_R16G16_FLOAT,DXGI_FORMAT_R8_UNORM,DXGI_FORMAT_D32_FLOAT}){D3D12_FEATURE_DATA_MULTISAMPLE_QUALITY_LEVELS q{f,samples,D3D12_MULTISAMPLE_QUALITY_LEVELS_FLAG_NONE,0};Check(c.device->CheckFeatureSupport(D3D12_FEATURE_MULTISAMPLE_QUALITY_LEVELS,&q,sizeof(q)),"MSAA capability");if(!q.NumQualityLevels)throw std::runtime_error("MSAA format/sample combination unsupported");}
    Targets t;auto flag=D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;t.color=MakeTexture(c,w,h,format,flag,samples,SceneClear[0]);t.motionDepth=MakeTexture(c,w,h,DXGI_FORMAT_R32G32B32A32_FLOAT,flag,samples,SceneClear[1]);t.linearDepth=MakeTexture(c,w,h,DXGI_FORMAT_R32_FLOAT,flag,samples,SceneClear[2]);t.velocity=MakeTexture(c,w,h,DXGI_FORMAT_R16G16_FLOAT,flag,samples,SceneClear[3]);t.reactive=MakeTexture(c,w,h,DXGI_FORMAT_R8_UNORM,flag,samples,SceneClear[4]);t.depth=MakeTexture(c,w,h,DXGI_FORMAT_R32_TYPELESS,D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL,samples);return t;
}
void Scene::Render(Targets& t,const SceneFrame& f){
    // Targets拥有像素资源，Scene只在自己的CPU描述符heap中重建RTV/DSV。
    // 与GPU可见SRV表不同，RTV/DSV的描述符内容在API记录调用时被使用；无论
    // 哪种view，底层资源仍须一直活到GPU完成。这里所有批次都由宿主Fence串行。
    Texture* rt[]={&t.color,&t.motionDepth,&t.linearDepth,&t.velocity,&t.reactive};std::array<D3D12_CPU_DESCRIPTOR_HANDLE,5> handles;
    for(UINT i=0;i<5;++i){rt[i]->To(c,D3D12_RESOURCE_STATE_RENDER_TARGET);D3D12_RENDER_TARGET_VIEW_DESC d{};d.Format=rt[i]->format;d.ViewDimension=t.color.samples>1?D3D12_RTV_DIMENSION_TEXTURE2DMS:D3D12_RTV_DIMENSION_TEXTURE2D;handles[i]=Cpu(c,rtv.Get(),i);c.device->CreateRenderTargetView(rt[i]->resource.Get(),&d,handles[i]);c.list->ClearRenderTargetView(handles[i],SceneClear[i],0,nullptr);}
    // 同一R32_TYPELESS存储通过D32_FLOAT DSV写入投影深度；SDK随后以R32_FLOAT
    // SRV读取。MSAA的view维度必须TEXTURE2DMS，不能装作普通Texture2D使用。
    t.depth.To(c,D3D12_RESOURCE_STATE_DEPTH_WRITE);D3D12_DEPTH_STENCIL_VIEW_DESC ds{};ds.Format=DXGI_FORMAT_D32_FLOAT;ds.ViewDimension=t.color.samples>1?D3D12_DSV_DIMENSION_TEXTURE2DMS:D3D12_DSV_DIMENSION_TEXTURE2D;c.device->CreateDepthStencilView(t.depth.resource.Get(),&ds,Cpu(c,dsv.Get()));auto dh=Cpu(c,dsv.Get());c.list->ClearDepthStencilView(dh,D3D12_CLEAR_FLAG_DEPTH,1,0,0,nullptr);
    c.list->OMSetRenderTargets(5,handles.data(),FALSE,&dh);Viewport(c,t.color.width,t.color.height);c.list->SetGraphicsRootSignature(root.Get());ID3D12DescriptorHeap* heaps[]={checkerSrv.Get()};c.list->SetDescriptorHeaps(1,heaps);c.list->SetGraphicsRootDescriptorTable(1,Gpu(c,checkerSrv.Get()));c.list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);c.list->IASetVertexBuffers(0,1,&vb);
    // Map只暴露CPU可写地址，不等待旧draw；调用者已在上帧SubmitWait后才能到此。
    // noRead=(0,0)说明不读旧内容。绘制命令保存的是GPU地址，不是此时常量的副本，
    // 因而必须为每个draw使用独立256B槽，且Unmap后也不能过早改写同一字节。
    Object* objects;D3D12_RANGE noRead{0,0};Check(constants->Map(0,&noRead,reinterpret_cast<void**>(&objects)),"F object Map");UINT index=0;
    auto draw=[&](XMMATRIX world,XMMATRIX prev,std::array<float,4> color,int kind,bool transparent=false){
        // current/previous各自用对应物体world和相机View，才能同时包含物体运动
        // 与相机运动。VS保留这两个无jitter clip位置，最终得到prevUV-currentUV；
        // UV的x右/y下为正。jitter独立经(+2jx/W,-2jy/H)*clip.w加到SV_Position。
        // motion因此不含jitter：TAA另加jprev-jcur，SDK收到同一几何偏移(jx,jy)。
        // options=(kind,A2C开关,材质LOD偏置,保留)；jitter=(jx,jy,渲染宽,渲染高)。
        auto& o=objects[index];XMStoreFloat4x4(&o.current,world*Camera(f.camera,t.color.width,t.color.height,f.outputAspect));XMStoreFloat4x4(&o.previous,prev*Camera(f.previousCamera,t.color.width,t.color.height,f.outputAspect));memcpy(o.color,color.data(),16);o.options[0]=float(kind);o.options[1]=f.a2c?1.f:0.f;o.options[2]=f.lodBias;o.options[3]=0;o.jitter[0]=f.jitterX;o.jitter[1]=f.jitterY;o.jitter[2]=float(t.color.width);o.jitter[3]=float(t.color.height);
        c.list->SetPipelineState(Pso(t.color.samples,t.color.format,f.a2c&&!transparent,transparent));c.list->SetGraphicsRootConstantBufferView(0,constants->GetGPUVirtualAddress()+256*index++);c.list->DrawInstanced(6,1,0,0);
    };
    // 行向量从左至右依次缩放、绕原点转Z、平移；对象几何沿+Z排布。
    // 相同场景与时间提供给每种重建算法，避免把改变内容误当成算法质量差异。
    auto quad=[](float sx,float sy,float x,float y,float z,float angle=0.f){return XMMatrixScaling(sx,sy,1)*XMMatrixRotationZ(angle)*XMMatrixTranslation(x,y,z);};
    auto back=quad(3.7f,2.f,0,0,7);draw(back,back,{.4f,.6f,1.2f,1},1);
    // 斜边和细线让空间/时域退化都可观测，所有模式使用相同几何与曝光。
    for(int i=0;i<24;++i){auto m=quad(.008f,.65f,-1.5f+i*.085f,.25f,4.5f,.3f);draw(m,m,{2.f,1.5f,.2f,1},0);}
    auto foliage=quad(.62f,.8f,1.25f,.05f,4.2f,-.12f);draw(foliage,foliage,{.08f,1.4f,.15f,1},2);
    auto moving=[&](float time){return quad(.46f,.6f,1.35f*std::sin(time*1.7f),-.08f,3.4f,time*.9f);};draw(moving(f.time),moving(f.previousTime),{2.2f,.16f,.05f,1},0);
    for(int i=0;i<4;++i){auto particle=[&](float time){return quad(.07f,.07f,-1.5f+.65f*i+.3f*std::sin(time*3+i),-.65f,3.f,time);};draw(particle(f.time),particle(f.previousTime),{.2f,2.1f,2.4f,.35f},3,true);}
    constants->Unmap(0,nullptr);
    // Unmap声明CPU写入结束，不是提交或Fence。宿主在后处理消费附件后统一提交；
    // 下一次Render覆写同一常量区之前必须SubmitWait，生产引擎则需资源环/延迟回收。
}
// CPU独立推导：先减相机X，除以正viewZ，乘cot(FOV/2)，x再除aspect；
// NDC→UV使用(.5*x+.5, .5-.5*y)。不含jitter，可检查GPU motion号和单位。
std::array<float,2> Scene::PointUV(float x,float y,float z,float camera,UINT w,UINT h){double scale=1/std::tan(double(XM_PIDIV4)*.5);return{float(.5+(x-camera)/z*scale*double(h)/w*.5),float(.5-y/z*scale*.5)};}
}
