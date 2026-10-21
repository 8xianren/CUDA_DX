#include "gpu_instances.h"
#include <d3dcompiler.h>
#include <fstream>
#include <iostream>
#include <cstring>
#include <stdexcept>
static ComPtr<ID3DBlob> Compile(const std::filesystem::path& path,const char* entry,const char* profile) {
    ComPtr<ID3DBlob> code,error;
    HRESULT hr=D3DCompileFromFile(path.c_str(),nullptr,D3D_COMPILE_STANDARD_FILE_INCLUDE,entry,profile,D3DCOMPILE_ENABLE_STRICTNESS,0,&code,&error);
    if(error) std::cerr<<static_cast<char*>(error->GetBufferPointer())<<"\n";
    Check(hr,"instance raster compile");return code;
}
static ComPtr<ID3D12RootSignature> Signature(UploadContext& c) {
    // 同一根签名服务光栅和DXR：b0相机、t1对象表、t0 TLAS、u0命中输出、b1每draw对象编号。
    D3D12_ROOT_PARAMETER p[5]{};
    p[0].ParameterType=D3D12_ROOT_PARAMETER_TYPE_CBV;p[0].Descriptor={0,0};
    p[1].ParameterType=D3D12_ROOT_PARAMETER_TYPE_SRV;p[1].Descriptor={1,0};
    p[2].ParameterType=D3D12_ROOT_PARAMETER_TYPE_SRV;p[2].Descriptor={0,0};
    p[3].ParameterType=D3D12_ROOT_PARAMETER_TYPE_UAV;p[3].Descriptor={0,0};
    p[4].ParameterType=D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;p[4].Constants={1,0,1};
    D3D12_ROOT_SIGNATURE_DESC d{};d.NumParameters=5;d.pParameters=p;d.Flags=D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
    ComPtr<ID3DBlob> blob,error;Check(D3D12SerializeRootSignature(&d,D3D_ROOT_SIGNATURE_VERSION_1,&blob,&error),"instance root serialize");
    ComPtr<ID3D12RootSignature> root;Check(c.device->CreateRootSignature(0,blob->GetBufferPointer(),blob->GetBufferSize(),IID_PPV_ARGS(&root)),"instance root");
    return root;
}
RayPipeline CreateLessonRayPipeline(UploadContext& c,ID3D12RootSignature* root,const std::filesystem::path& path) {
    std::ifstream file(path,std::ios::binary);std::vector<char> bytes((std::istreambuf_iterator<char>(file)),{});
    if(bytes.empty()) throw std::runtime_error("missing instance DXIL");
    const D3D12_EXPORT_DESC exports[]={{L"RayGen",nullptr,D3D12_EXPORT_FLAG_NONE},{L"Miss",nullptr,D3D12_EXPORT_FLAG_NONE},{L"ClosestHit",nullptr,D3D12_EXPORT_FLAG_NONE}};
    D3D12_DXIL_LIBRARY_DESC library{{bytes.data(),bytes.size()},3,exports};
    D3D12_HIT_GROUP_DESC hit{};hit.HitGroupExport=L"HitGroup";hit.Type=D3D12_HIT_GROUP_TYPE_TRIANGLES;hit.ClosestHitShaderImport=L"ClosestHit";
    D3D12_RAYTRACING_SHADER_CONFIG shaderConfig{16,8}; // payload=uint4，三角形属性float2
    D3D12_GLOBAL_ROOT_SIGNATURE global{root};
    D3D12_RAYTRACING_PIPELINE_CONFIG pipelineConfig{1}; // TraceRay嵌套深度1；RayGen可顺序发多条射线，ClosestHit不递归。
    D3D12_STATE_SUBOBJECT objects[]={
        {D3D12_STATE_SUBOBJECT_TYPE_DXIL_LIBRARY,&library},
        {D3D12_STATE_SUBOBJECT_TYPE_HIT_GROUP,&hit},
        {D3D12_STATE_SUBOBJECT_TYPE_RAYTRACING_SHADER_CONFIG,&shaderConfig},
        {D3D12_STATE_SUBOBJECT_TYPE_GLOBAL_ROOT_SIGNATURE,&global},
        {D3D12_STATE_SUBOBJECT_TYPE_RAYTRACING_PIPELINE_CONFIG,&pipelineConfig}};
    D3D12_STATE_OBJECT_DESC desc{D3D12_STATE_OBJECT_TYPE_RAYTRACING_PIPELINE,5,objects};RayPipeline out;
    Check(c.device->CreateStateObject(&desc,IID_PPV_ARGS(&out.state)),"instance ray pipeline");
    ComPtr<ID3D12StateObjectProperties> properties;Check(out.state.As(&properties),"state properties");
    // 每个表起点64B对齐；identifier32B，剩余padding清零；没有local root arguments。
    uint8_t records[192]{};const wchar_t* names[]={L"RayGen",L"Miss",L"HitGroup"};
    for(unsigned i=0;i<3;++i){const void* id=properties->GetShaderIdentifier(names[i]);if(!id)throw std::runtime_error("shader identifier missing");memcpy(records+i*64,id,32);}
    out.table=InstanceUpload(c,records,sizeof(records));return out;
}
InstanceImages RenderInstances(UploadContext& c,const GpuScene& gpu,const InstanceFrame& frame,
    const InstanceCamera& camera,const std::filesystem::path& rasterShader,const std::filesystem::path& dxil) {
    auto root=Signature(c);auto rays=CreateLessonRayPipeline(c,root.Get(),dxil);
    // 根CBV地址按256B对齐；实际Camera144B，分配256B并初始化padding，GPU/CPU布局由static_assert保证。
    uint8_t cameraBytes[256]{};memcpy(cameraBytes,&camera,sizeof(camera));auto cameraBuffer=InstanceUpload(c,cameraBytes,sizeof(cameraBytes));
    const UINT64 resultBytes=UINT64(camera.width)*camera.height*sizeof(HitIds);
    auto resultDesc=BufferDesc(resultBytes);resultDesc.Flags=D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
    auto rayResult=MakeResource(c,resultDesc,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    c.list->SetComputeRootSignature(root.Get());c.list->SetComputeRootConstantBufferView(0,cameraBuffer->GetGPUVirtualAddress());
    c.list->SetComputeRootShaderResourceView(1,frame.objects->GetGPUVirtualAddress());
    c.list->SetComputeRootShaderResourceView(2,frame.tlas.result->GetGPUVirtualAddress());
    c.list->SetComputeRootUnorderedAccessView(3,rayResult->GetGPUVirtualAddress());c.list->SetComputeRoot32BitConstant(4,0,0);
    c.list->SetPipelineState1(rays.state.Get());
    auto table=rays.table->GetGPUVirtualAddress();D3D12_DISPATCH_RAYS_DESC dispatch{};
    dispatch.RayGenerationShaderRecord={table,32};dispatch.MissShaderTable={table+64,64,64};dispatch.HitGroupTable={table+128,64,64};
    dispatch.Width=camera.width;dispatch.Height=camera.height;dispatch.Depth=1;c.list->DispatchRays(&dispatch);
    Transition(c,rayResult.Get(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_COPY_SOURCE);
    auto rayRead=MakeResource(c,BufferDesc(resultBytes),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
    c.list->CopyBufferRegion(rayRead.Get(),0,rayResult.Get(),0,resultBytes);

    auto vs=Compile(rasterShader,"VS","vs_5_1"),ps=Compile(rasterShader,"PS","ps_5_1");
    D3D12_INPUT_ELEMENT_DESC input{"POSITION",0,DXGI_FORMAT_R32G32B32_FLOAT,0,0,D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,0};
    D3D12_GRAPHICS_PIPELINE_STATE_DESC pd{};pd.pRootSignature=root.Get();
    pd.VS={vs->GetBufferPointer(),vs->GetBufferSize()};pd.PS={ps->GetBufferPointer(),ps->GetBufferSize()};pd.InputLayout={&input,1};
    pd.SampleMask=UINT_MAX;pd.SampleDesc.Count=1;pd.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    pd.NumRenderTargets=1;pd.RTVFormats[0]=DXGI_FORMAT_R32G32B32A32_UINT;
    pd.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;pd.RasterizerState.CullMode=D3D12_CULL_MODE_NONE;pd.RasterizerState.DepthClipEnable=TRUE;
    pd.DepthStencilState.DepthEnable=FALSE;pd.DepthStencilState.DepthFunc=D3D12_COMPARISON_FUNC_ALWAYS;
    // 测试几何位于同一平面且不同物体不重叠；不把无深度诊断当作通用场景绘制。
    auto& b=pd.BlendState.RenderTarget[0];b.SrcBlend=b.SrcBlendAlpha=D3D12_BLEND_ONE;b.DestBlend=b.DestBlendAlpha=D3D12_BLEND_ZERO;
    b.BlendOp=b.BlendOpAlpha=D3D12_BLEND_OP_ADD;b.LogicOp=D3D12_LOGIC_OP_NOOP;b.RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;
    ComPtr<ID3D12PipelineState> pso;Check(c.device->CreateGraphicsPipelineState(&pd,IID_PPV_ARGS(&pso)),"instance raster PSO");
    D3D12_RESOURCE_DESC td{};td.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;td.Width=camera.width;td.Height=camera.height;
    td.DepthOrArraySize=td.MipLevels=1;td.SampleDesc.Count=1;td.Format=pd.RTVFormats[0];td.Flags=D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    auto target=MakeResource(c,td,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_RENDER_TARGET);
    D3D12_DESCRIPTOR_HEAP_DESC hd{};hd.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV;hd.NumDescriptors=1;
    ComPtr<ID3D12DescriptorHeap> rtv;Check(c.device->CreateDescriptorHeap(&hd,IID_PPV_ARGS(&rtv)),"instance RTV heap");
    auto handle=rtv->GetCPUDescriptorHandleForHeapStart();c.device->CreateRenderTargetView(target.Get(),nullptr,handle);
    const float clear[4]={0,0,0,0};c.list->ClearRenderTargetView(handle,clear,0,nullptr);c.list->OMSetRenderTargets(1,&handle,FALSE,nullptr);
    D3D12_VIEWPORT viewport{0,0,float(camera.width),float(camera.height),0,1};
    D3D12_RECT scissor{0,0,LONG(camera.width),LONG(camera.height)};c.list->RSSetViewports(1,&viewport);c.list->RSSetScissorRects(1,&scissor);
    c.list->SetGraphicsRootSignature(root.Get());c.list->SetPipelineState(pso.Get());
    c.list->SetGraphicsRootConstantBufferView(0,cameraBuffer->GetGPUVirtualAddress());c.list->SetGraphicsRootShaderResourceView(1,frame.objects->GetGPUVirtualAddress());
    c.list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);c.list->IASetVertexBuffers(0,1,&gpu.vb);c.list->IASetIndexBuffer(&gpu.ib);
    for(UINT i=0;i<frame.records.size();++i) {
        if(!frame.descriptors[i].InstanceMask) continue; // 与TraceRay mask保持同一可见性条件。
        c.list->SetGraphicsRoot32BitConstant(4,i,0);const auto& mesh=gpu.meshes.at(frame.records[i].mesh);
        c.list->DrawIndexedInstanced(mesh.indexCount,1,mesh.firstIndex,INT(mesh.firstVertex),0);
    }
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};UINT64 copyBytes=0;
    c.device->GetCopyableFootprints(&td,0,1,0,&footprint,nullptr,nullptr,&copyBytes);
    auto rasterRead=MakeResource(c,BufferDesc(copyBytes),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
    Transition(c,target.Get(),D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_COPY_SOURCE);
    D3D12_TEXTURE_COPY_LOCATION src{};src.pResource=target.Get();src.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    D3D12_TEXTURE_COPY_LOCATION dst{};dst.pResource=rasterRead.Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;dst.PlacedFootprint=footprint;
    c.list->CopyTextureRegion(&dst,0,0,0,&src,nullptr);
    // TLAS/objects/CBV/shader table/RTV/输出资源全都活到这次提交的Fence完成；之后才Map读回。
    c.SubmitWait();InstanceImages out;out.ray.resize(size_t(camera.width)*camera.height);out.raster.resize(out.ray.size());
    void* data=nullptr;D3D12_RANGE read{0,SIZE_T(resultBytes)},noWrite{0,0};Check(rayRead->Map(0,&read,&data),"ray IDs Map");
    memcpy(out.ray.data(),data,SIZE_T(resultBytes));rayRead->Unmap(0,&noWrite);
    read.End=SIZE_T(copyBytes);Check(rasterRead->Map(0,&read,&data),"raster IDs Map");
    for(UINT y=0;y<camera.height;++y) memcpy(out.raster.data()+size_t(y)*camera.width,static_cast<uint8_t*>(data)+footprint.Offset+y*footprint.Footprint.RowPitch,size_t(camera.width)*16);
    rasterRead->Unmap(0,&noWrite);return out;
}
