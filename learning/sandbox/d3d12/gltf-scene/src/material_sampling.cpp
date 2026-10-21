#include "material_sampling.h"
#include <cstring>
#include <stdexcept>
MaterialRayPipeline::MaterialRayPipeline(UploadContext& c,const std::filesystem::path& dxil){
    // Texture和Sampler分别占两种shader-visible heap；根SRV只适用于buffer/AS，不能拿纹理GPU地址代替SRV。
    D3D12_DESCRIPTOR_RANGE ranges[2]{};
    ranges[0]={D3D12_DESCRIPTOR_RANGE_TYPE_SRV,UINT_MAX,0,1,0};
    ranges[1]={D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER,UINT_MAX,0,0,0};
    D3D12_ROOT_PARAMETER parameters[11]{};
    for(UINT i=0;i<7;++i){parameters[i].ParameterType=D3D12_ROOT_PARAMETER_TYPE_SRV;parameters[i].Descriptor={i,0};}
    parameters[7].ParameterType=D3D12_ROOT_PARAMETER_TYPE_UAV;parameters[7].Descriptor={0,0};
    for(UINT i=0;i<2;++i){parameters[8+i].ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;parameters[8+i].DescriptorTable={1,&ranges[i]};}
    parameters[10].ParameterType=D3D12_ROOT_PARAMETER_TYPE_SRV;parameters[10].Descriptor={7,0};
    D3D12_ROOT_SIGNATURE_DESC desc{};desc.NumParameters=11;desc.pParameters=parameters;
    ComPtr<ID3DBlob> blob,error;Check(D3D12SerializeRootSignature(&desc,D3D_ROOT_SIGNATURE_VERSION_1,&blob,&error),"material root serialize");
    Check(c.device->CreateRootSignature(0,blob->GetBufferPointer(),blob->GetBufferSize(),IID_PPV_ARGS(&root_)),"material root");
    pipeline_=CreateLessonRayPipeline(c,root_.Get(),dxil);
}
void MaterialRayPipeline::Record(UploadContext& c,const MaterialBindings& bindings,const GpuScene& gpu,
    const InstanceFrame& frame,ID3D12Resource* configuration,ID3D12Resource* output,UINT width,UINT height) const {
    if(!configuration||!output||!width||!height||!bindings.samplers||!bindings.meshes||!bindings.materials)
        throw std::runtime_error("empty material record input");
    ID3D12DescriptorHeap* heaps[]={gpu.descriptors.Get(),bindings.samplers.Get()};c.list->SetDescriptorHeaps(2,heaps);
    c.list->SetComputeRootSignature(root_.Get());
    ID3D12Resource* buffers[]={frame.tlas.result.Get(),frame.objects.Get(),gpu.vertices.Get(),gpu.indices.Get(),bindings.meshes.Get(),bindings.materials.Get(),configuration};
    for(UINT i=0;i<7;++i)c.list->SetComputeRootShaderResourceView(i,buffers[i]->GetGPUVirtualAddress());
    c.list->SetComputeRootUnorderedAccessView(7,output->GetGPUVirtualAddress());
    c.list->SetComputeRootDescriptorTable(8,gpu.descriptors->GetGPUDescriptorHandleForHeapStart());
    c.list->SetComputeRootDescriptorTable(9,bindings.samplers->GetGPUDescriptorHandleForHeapStart());
    c.list->SetComputeRootShaderResourceView(10,(bindings.energy?bindings.energy.Get():bindings.materials.Get())->GetGPUVirtualAddress());
    c.list->SetPipelineState1(pipeline_.state.Get());const auto table=pipeline_.table->GetGPUVirtualAddress();
    D3D12_DISPATCH_RAYS_DESC dispatch{};dispatch.RayGenerationShaderRecord={table,32};
    dispatch.MissShaderTable={table+64,64,64};dispatch.HitGroupTable={table+128,64,64};
    dispatch.Width=width;dispatch.Height=height;dispatch.Depth=1;c.list->DispatchRays(&dispatch);
}
std::vector<uint8_t> DispatchMaterialBuffer(UploadContext& c,const MaterialBindings& bindings,const GpuScene& gpu,
    const InstanceFrame& frame,const void* config,size_t configBytes,UINT width,UINT height,size_t bytes,const std::filesystem::path& dxil){
    if(!config||!configBytes||!width||!height||!bytes)throw std::runtime_error("empty material dispatch input");
    // 保留前课同步API，但根签名/绑定/Dispatch的实现只保留一份。
    MaterialRayPipeline pipeline(c,dxil);
    auto rayBuffer=InstanceUpload(c,config,configBytes);
    auto resultDesc=BufferDesc(bytes);resultDesc.Flags=D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
    auto result=MakeResource(c,resultDesc,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    auto readback=MakeResource(c,BufferDesc(bytes),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
    pipeline.Record(c,bindings,gpu,frame,rayBuffer.Get(),result.Get(),width,height);
    // UAV写完成→COPY_SOURCE读，随后同队列Copy到Readback。CPU仅在Fence完成后Map。
    Transition(c,result.Get(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_COPY_SOURCE);
    c.list->CopyBufferRegion(readback.Get(),0,result.Get(),0,bytes);c.SubmitWait();
    std::vector<uint8_t> out(bytes);void* mapped=nullptr;D3D12_RANGE read{0,bytes},noWrite{0,0};
    Check(readback->Map(0,&read,&mapped),"material readback");memcpy(out.data(),mapped,bytes);readback->Unmap(0,&noWrite);
    // Fence结束后局部射线表、SBT、输出/readback才可析构；材质绑定与GpuScene/BLAS/TLAS由调用者持有。
    return out;
}
std::vector<LinearRGBA> SampleHitMaterials(UploadContext& c,const MaterialBindings& bindings,const GpuScene& gpu,
    const InstanceFrame& frame,const std::vector<MaterialRay>& rays,const std::filesystem::path& dxil){
    if(rays.empty())throw std::runtime_error("empty material sampling input");
    auto bytes=DispatchMaterialBuffer(c,bindings,gpu,frame,rays.data(),rays.size()*sizeof(MaterialRay),
        UINT(rays.size()),1,rays.size()*sizeof(LinearRGBA),dxil);
    std::vector<LinearRGBA> out(rays.size());memcpy(out.data(),bytes.data(),bytes.size());return out;
}
