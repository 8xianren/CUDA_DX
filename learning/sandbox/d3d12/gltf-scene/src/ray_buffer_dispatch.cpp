#include "ray_buffer_dispatch.h"
#include <cstring>
#include <stdexcept>
std::vector<uint8_t> DispatchRayBuffer(UploadContext& c,const InstanceFrame& frame,const void* data,size_t configBytes,
    UINT width,UINT height,size_t bytes,const std::filesystem::path& dxil){
    if(!data||!configBytes||!width||!height||uint64_t(width)*height>(1ull<<30)||!bytes)
        throw std::runtime_error("invalid ray buffer dispatch");
    D3D12_ROOT_PARAMETER p[4]{};
    // 根描述符直接传GPU地址：t0=TLAS，t1=80B对象表，t2=调用者配置，u0=调用者输出布局。
    // 不访问纹理，因此不需要本课未使用的texture/sampler descriptor heap。
    for(UINT i=0;i<3;++i){p[i].ParameterType=D3D12_ROOT_PARAMETER_TYPE_SRV;p[i].Descriptor={i,0};}
    p[3].ParameterType=D3D12_ROOT_PARAMETER_TYPE_UAV;p[3].Descriptor={0,0};
    D3D12_ROOT_SIGNATURE_DESC desc{};desc.NumParameters=4;desc.pParameters=p;
    ComPtr<ID3DBlob> blob,error;Check(D3D12SerializeRootSignature(&desc,D3D_ROOT_SIGNATURE_VERSION_1,&blob,&error),"MIS serialize");
    ComPtr<ID3D12RootSignature> root;Check(c.device->CreateRootSignature(0,blob->GetBufferPointer(),blob->GetBufferSize(),IID_PPV_ARGS(&root)),"MIS root");
    auto pipeline=CreateLessonRayPipeline(c,root.Get(),dxil); // payload16B，TraceRay嵌套深度1。
    auto config=InstanceUpload(c,data,configBytes);
    auto d=BufferDesc(bytes);d.Flags=D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
    auto result=MakeResource(c,d,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    auto readback=MakeResource(c,BufferDesc(bytes),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
    c.list->SetComputeRootSignature(root.Get());
    c.list->SetComputeRootShaderResourceView(0,frame.tlas.result->GetGPUVirtualAddress());
    c.list->SetComputeRootShaderResourceView(1,frame.objects->GetGPUVirtualAddress());
    c.list->SetComputeRootShaderResourceView(2,config->GetGPUVirtualAddress());
    c.list->SetComputeRootUnorderedAccessView(3,result->GetGPUVirtualAddress());
    c.list->SetPipelineState1(pipeline.state.Get());auto table=pipeline.table->GetGPUVirtualAddress();
    D3D12_DISPATCH_RAYS_DESC dispatch{};dispatch.RayGenerationShaderRecord={table,32};
    dispatch.MissShaderTable={table+64,64,64};dispatch.HitGroupTable={table+128,64,64};
    dispatch.Width=width;dispatch.Height=height;dispatch.Depth=1;c.list->DispatchRays(&dispatch);
    // 同队列的transition使UAV结果可供复制；Fence完成才允许CPU读取，Map本身不等GPU。
    Transition(c,result.Get(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_COPY_SOURCE);
    c.list->CopyBufferRegion(readback.Get(),0,result.Get(),0,bytes);c.SubmitWait();
    std::vector<uint8_t> pixels(bytes);void* mapped=nullptr;
    D3D12_RANGE read{0,bytes},noWrite{0,0};Check(readback->Map(0,&read,&mapped),"ray buffer readback");
    std::memcpy(pixels.data(),mapped,bytes);readback->Unmap(0,&noWrite);
    // 所有ComPtr在Fence后析构。HRESULT/等待失败抛异常，验收进程退出，不复用失败帧。
    return pixels;
}
