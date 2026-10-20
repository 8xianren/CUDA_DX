#include "gpu_upload.h"
#include <d3dcompiler.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <algorithm>
#include <cmath>
#include <cstring>
static ComPtr<ID3DBlob> Shader(const std::wstring& path,const char* entry,const char* profile) {
    ComPtr<ID3DBlob> code,error;
    HRESULT hr=D3DCompileFromFile(path.c_str(),nullptr,D3D_COMPILE_STANDARD_FILE_INCLUDE,entry,profile,D3DCOMPILE_ENABLE_STRICTNESS,0,&code,&error);
    if(error) std::cerr<<static_cast<char*>(error->GetBufferPointer())<<"\n";
    Check(hr,"compile preview shader");return code;
}
static void Preview(UploadContext& c,const GpuScene& scene,const std::filesystem::path& shader,const std::filesystem::path& output) {
    // Root constants按值复制8个float，descriptor table引用实际SRV heap；二者都不是纹理数据本身。
    D3D12_DESCRIPTOR_RANGE range{};range.RangeType=D3D12_DESCRIPTOR_RANGE_TYPE_SRV;range.NumDescriptors=1;
    D3D12_ROOT_PARAMETER root[2]{};root[0].ParameterType=D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;root[0].Constants={0,0,8};
    root[1].ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;root[1].DescriptorTable={1,&range};root[1].ShaderVisibility=D3D12_SHADER_VISIBILITY_PIXEL;
    D3D12_STATIC_SAMPLER_DESC sampler{};sampler.Filter=D3D12_FILTER_MIN_MAG_MIP_POINT;
    sampler.AddressU=sampler.AddressV=sampler.AddressW=D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    sampler.ComparisonFunc=D3D12_COMPARISON_FUNC_ALWAYS;sampler.MaxLOD=D3D12_FLOAT32_MAX;sampler.ShaderVisibility=D3D12_SHADER_VISIBILITY_PIXEL;
    // D.1固定point/clamp/mip0诊断。源sampler记录仍保留，D.3负责完整策略。
    D3D12_ROOT_SIGNATURE_DESC rd{};rd.NumParameters=2;rd.pParameters=root;rd.NumStaticSamplers=1;rd.pStaticSamplers=&sampler;
    rd.Flags=D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
    ComPtr<ID3DBlob> serialized,error;Check(D3D12SerializeRootSignature(&rd,D3D_ROOT_SIGNATURE_VERSION_1,&serialized,&error),"root serialize");
    ComPtr<ID3D12RootSignature> signature;Check(c.device->CreateRootSignature(0,serialized->GetBufferPointer(),serialized->GetBufferSize(),IID_PPV_ARGS(&signature)),"root signature");
    auto vs=Shader(shader.wstring(),"VS","vs_5_1"),ps=Shader(shader.wstring(),"PS","ps_5_1");
    const D3D12_INPUT_ELEMENT_DESC input[]={
        {"POSITION",0,DXGI_FORMAT_R32G32B32_FLOAT,0,0,D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,0},
        {"TEXCOORD",0,DXGI_FORMAT_R32G32_FLOAT,0,24,D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,0},
        {"COLOR",0,DXGI_FORMAT_R32G32B32A32_FLOAT,0,32,D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,0}};
    D3D12_GRAPHICS_PIPELINE_STATE_DESC pd{};pd.pRootSignature=signature.Get();pd.VS={vs->GetBufferPointer(),vs->GetBufferSize()};pd.PS={ps->GetBufferPointer(),ps->GetBufferSize()};
    pd.InputLayout={input,3};pd.SampleMask=UINT_MAX;pd.SampleDesc.Count=1;pd.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    pd.NumRenderTargets=1;pd.RTVFormats[0]=DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;
    pd.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;pd.RasterizerState.CullMode=D3D12_CULL_MODE_NONE;pd.RasterizerState.DepthClipEnable=TRUE;
    pd.DepthStencilState.DepthEnable=FALSE;pd.DepthStencilState.DepthFunc=D3D12_COMPARISON_FUNC_ALWAYS;
    auto& blend=pd.BlendState.RenderTarget[0];blend.SrcBlend=blend.SrcBlendAlpha=D3D12_BLEND_ONE;blend.DestBlend=blend.DestBlendAlpha=D3D12_BLEND_ZERO;
    blend.BlendOp=blend.BlendOpAlpha=D3D12_BLEND_OP_ADD;blend.LogicOp=D3D12_LOGIC_OP_NOOP;blend.RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;
    ComPtr<ID3D12PipelineState> pipeline;Check(c.device->CreateGraphicsPipelineState(&pd,IID_PPV_ARGS(&pipeline)),"preview PSO");
    constexpr UINT width=256,height=256;
    D3D12_RESOURCE_DESC td{};td.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;td.Width=width;td.Height=height;td.DepthOrArraySize=1;td.MipLevels=1;
    td.Format=DXGI_FORMAT_R8G8B8A8_TYPELESS;td.SampleDesc.Count=1;td.Flags=D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    auto target=MakeResource(c,td,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_RENDER_TARGET);
    D3D12_DESCRIPTOR_HEAP_DESC hd{};hd.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV;hd.NumDescriptors=1;
    ComPtr<ID3D12DescriptorHeap> rtvHeap;Check(c.device->CreateDescriptorHeap(&hd,IID_PPV_ARGS(&rtvHeap)),"RTV heap");
    D3D12_RENDER_TARGET_VIEW_DESC rtv{};rtv.Format=pd.RTVFormats[0];rtv.ViewDimension=D3D12_RTV_DIMENSION_TEXTURE2D;
    auto handle=rtvHeap->GetCPUDescriptorHandleForHeapStart();c.device->CreateRenderTargetView(target.Get(),&rtv,handle);
    const float clear[4]={0,0,0,1};c.list->ClearRenderTargetView(handle,clear,0,nullptr);c.list->OMSetRenderTargets(1,&handle,FALSE,nullptr);
    D3D12_VIEWPORT viewport{0,0,float(width),float(height),0,1};D3D12_RECT rect{0,0,width,height};
    c.list->RSSetViewports(1,&viewport);c.list->RSSetScissorRects(1,&rect);
    c.list->SetPipelineState(pipeline.Get());c.list->SetGraphicsRootSignature(signature.Get());
    ID3D12DescriptorHeap* heaps[]={scene.descriptors.Get()};c.list->SetDescriptorHeaps(1,heaps);
    c.list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);c.list->IASetVertexBuffers(0,1,&scene.vb);c.list->IASetIndexBuffer(&scene.ib);
    float lo[2]={INFINITY,INFINITY},hi[2]={-INFINITY,-INFINITY};
    for(const auto& v:scene.referenceVertices) for(int k=0;k<2;++k){lo[k]=std::min(lo[k],v.position[k]);hi[k]=std::max(hi[k],v.position[k]);}
    float scale=1.6f/std::max(hi[0]-lo[0],hi[1]-lo[1]);
    if(!std::isfinite(scale)) throw std::runtime_error("preview requires nondegenerate XY extent");
    for(const auto& mesh:scene.meshes) {
        const auto& material=scene.materials.at(mesh.material);
        float constants[8]={scale,scale,-(lo[0]+hi[0])*.5f*scale,-(lo[1]+hi[1])*.5f*scale};
        memcpy(constants+4,material.factor.data(),16);c.list->SetGraphicsRoot32BitConstants(0,8,constants,0);
        auto srv=scene.descriptors->GetGPUDescriptorHandleForHeapStart();srv.ptr+=UINT64(material.srv[0])*scene.descriptorStride;
        c.list->SetGraphicsRootDescriptorTable(1,srv);c.list->DrawIndexedInstanced(mesh.indexCount,1,mesh.firstIndex,INT(mesh.firstVertex),0);
    }
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};UINT64 bytes=0;c.device->GetCopyableFootprints(&td,0,1,0,&footprint,nullptr,nullptr,&bytes);
    auto readback=MakeResource(c,BufferDesc(bytes),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
    Transition(c,target.Get(),D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_COPY_SOURCE);
    D3D12_TEXTURE_COPY_LOCATION src{};src.pResource=target.Get();src.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    D3D12_TEXTURE_COPY_LOCATION dst{};dst.pResource=readback.Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;dst.PlacedFootprint=footprint;
    c.list->CopyTextureRegion(&dst,0,0,0,&src,nullptr);c.SubmitWait();
    uint8_t* pixels=nullptr;D3D12_RANGE read{0,SIZE_T(bytes)};Check(readback->Map(0,&read,reinterpret_cast<void**>(&pixels)),"preview read");
    // 直接保存GPU读回像素。BMP为顶向下BGRA，PPM为顶向下RGB，不再进行渲染或颜色变换。
    std::ofstream ppm(output/"preview.ppm",std::ios::binary);ppm<<"P6\n"<<width<<" "<<height<<"\n255\n";
    BITMAPFILEHEADER file{};BITMAPINFOHEADER bitmap{};file.bfType=0x4d42;file.bfOffBits=sizeof(file)+sizeof(bitmap);file.bfSize=file.bfOffBits+width*height*4;
    bitmap.biSize=sizeof(bitmap);bitmap.biWidth=width;bitmap.biHeight=-LONG(height);bitmap.biPlanes=1;bitmap.biBitCount=32;bitmap.biSizeImage=width*height*4;
    std::ofstream bmp(output/"preview.bmp",std::ios::binary);bmp.write(reinterpret_cast<char*>(&file),sizeof(file));bmp.write(reinterpret_cast<char*>(&bitmap),sizeof(bitmap));
    unsigned covered=0;
    for(UINT y=0;y<height;++y) for(UINT x=0;x<width;++x) {
        auto p=pixels+footprint.Offset+y*footprint.Footprint.RowPitch+x*4;
        ppm.write(reinterpret_cast<char*>(p),3);uint8_t bgra[]={p[2],p[1],p[0],p[3]};bmp.write(reinterpret_cast<char*>(bgra),4);
        if(p[0]||p[1]||p[2]) ++covered;
    }
    D3D12_RANGE noWrite{0,0};readback->Unmap(0,&noWrite);
    if(!ppm||!bmp||covered==0) throw std::runtime_error("preview output empty/failed");
    std::cout<<"PASS raster_preview nonblack_pixels="<<covered<<" size="<<width<<"x"<<height<<"\n";
}
int main(int argc,char** argv) {
    if(argc!=4){std::cerr<<"usage: gpu_upload_test model shader output-dir\n";return 2;}
    HRESULT com=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    try {
        Check(com,"COM initialize");std::filesystem::create_directories(argv[3]);
        // 单独exe不等于规范校验；组合脚本先走C.6 Validator入口。CPU导入成功后才创建GPU资源。
        auto cpu=LoadCpuScene(argv[1]);UploadContext context;auto gpu=UploadScene(context,cpu);
        VerifyCopiesAndBuildBlas(context,gpu);Preview(context,gpu,argv[2],argv[3]);
        std::cout<<"primitive_meshes="<<gpu.meshes.size()<<" vertices="<<gpu.referenceVertices.size()<<" indices="<<gpu.referenceIndices.size()
                 <<" source_images="<<cpu.materialAssets.images.size()<<" gpu_images_with_fallback="<<gpu.images.size()
                 <<" materials="<<gpu.materials.size()<<" BLAS_geometry="<<gpu.geometry.size()<<"\n";
        if(context.CheckDebug()) throw std::runtime_error("D3D12 validation messages");
        std::cout<<"PASS D.1 GPU upload and local-space preview (no TLAS/no ray dispatch)\n";
    } catch(const std::exception& e) {std::cerr<<"FAIL "<<e.what()<<"\n";if(SUCCEEDED(com))CoUninitialize();return 1;}
    CoUninitialize();return 0;
}
