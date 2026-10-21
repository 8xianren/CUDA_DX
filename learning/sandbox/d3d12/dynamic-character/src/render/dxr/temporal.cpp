#include "render/dxr/temporal.h"
#include <fstream>
#include <iterator>
#include <cstring>
namespace character {
TemporalFilter::TemporalFilter(UploadContext& c,unsigned width,unsigned height,uint64_t vertexBytes,const std::filesystem::path& shaders)
 :context_(c),width_(width),height_(height),guidePipeline_(c,shaders/"guides.dxil"){
    for(unsigned i=0;i<2;++i){auto desc=BufferDesc(uint64_t(width)*height*sizeof(MotionGuide));desc.Flags=D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
        guides_[i]=MakeResource(c,desc,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        desc.Width=uint64_t(width)*height*16;colors_[i]=MakeResource(c,desc,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);}
    previousVertices_=MakeResource(c,BufferDesc(vertexBytes),D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    D3D12_ROOT_PARAMETER p[6]{};for(unsigned i=0;i<4;++i){p[i].ParameterType=D3D12_ROOT_PARAMETER_TYPE_SRV;p[i].Descriptor={i,0};}
    p[4].ParameterType=D3D12_ROOT_PARAMETER_TYPE_UAV;p[4].Descriptor={0,0};p[5].ParameterType=D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;p[5].Constants={0,0,12};
    D3D12_ROOT_SIGNATURE_DESC rd{};rd.NumParameters=6;rd.pParameters=p;ComPtr<ID3DBlob> code,error;
    Check(D3D12SerializeRootSignature(&rd,D3D_ROOT_SIGNATURE_VERSION_1,&code,&error),"temporal root serialize");Check(c.device->CreateRootSignature(0,code->GetBufferPointer(),code->GetBufferSize(),IID_PPV_ARGS(&root_)),"temporal root");
    std::ifstream file(shaders/"temporal.dxil",std::ios::binary);std::vector<char> shader{std::istreambuf_iterator<char>(file),std::istreambuf_iterator<char>()};if(shader.empty())throw std::runtime_error("missing temporal shader");
    D3D12_COMPUTE_PIPELINE_STATE_DESC desc{};desc.pRootSignature=root_.Get();desc.CS={shader.data(),shader.size()};Check(c.device->CreateComputePipelineState(&desc,IID_PPV_ARGS(&pipeline_)),"temporal PSO");
}
ID3D12Resource* TemporalFilter::Record(const MaterialBindings& bindings,const GpuScene& gpu,const InstanceFrame& instances,const PathConfig& cfg,ID3D12Resource* raw,bool reset){
    auto& c=context_;auto copyVertices=[&]{
        Transition(c,gpu.vertices.Get(),D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_COPY_SOURCE);
        Transition(c,previousVertices_.Get(),D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_COPY_DEST);
        c.list->CopyBufferRegion(previousVertices_.Get(),0,gpu.vertices.Get(),0,previousVertices_->GetDesc().Width);
        Transition(c,previousVertices_.Get(),D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        Transition(c,gpu.vertices.Get(),D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);};
    if(!valid_){previousConfig_=cfg;for(const auto& record:instances.records)previousWorlds_.push_back(record.world);copyVertices();}
    if(previousWorlds_.size()!=instances.records.size())throw std::runtime_error("temporal topology changed; recreate filter");
    struct GuideHeader{PathConfig current;float eye[4],forward[4],right[4],up[4];uint32_t count,pad[3];};static_assert(sizeof(GuideHeader)==208);
    GuideHeader header{};header.current=cfg;std::copy_n(previousConfig_.eye,3,header.eye);std::copy_n(previousConfig_.forward,3,header.forward);header.forward[3]=previousConfig_.tanHalfFovY;
    std::copy_n(previousConfig_.right,3,header.right);std::copy_n(previousConfig_.up,3,header.up);header.count=unsigned(previousWorlds_.size());
    std::vector<uint8_t> bytes(sizeof(header)+previousWorlds_.size()*sizeof(Matrix4));memcpy(bytes.data(),&header,sizeof(header));memcpy(bytes.data()+sizeof(header),previousWorlds_.data(),previousWorlds_.size()*sizeof(Matrix4));
    auto config=InstanceUpload(c,bytes.data(),bytes.size());uploads_.push_back(config);
    MaterialBindings guideBindings=bindings;guideBindings.energy=previousVertices_;
    Transition(c,guides_[slot_].Get(),D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    guidePipeline_.Record(c,guideBindings,gpu,instances,config.Get(),guides_[slot_].Get(),width_,height_);
    Transition(c,guides_[slot_].Get(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    Transition(c,raw,D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    Transition(c,colors_[slot_].Get(),D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    c.list->SetComputeRootSignature(root_.Get());c.list->SetPipelineState(pipeline_.Get());
    ID3D12Resource* sources[]={raw,guides_[slot_].Get(),guides_[slot_^1].Get(),colors_[slot_^1].Get()};for(unsigned i=0;i<4;++i)c.list->SetComputeRootShaderResourceView(i,sources[i]->GetGPUVirtualAddress());
    c.list->SetComputeRootUnorderedAccessView(4,colors_[slot_]->GetGPUVirtualAddress());
    struct Controls{unsigned w,h,reset,maxHistory;float eye[4],forward[4];} controls{};controls.w=width_;controls.h=height_;controls.reset=reset||!valid_;controls.maxHistory=8;std::copy_n(previousConfig_.eye,3,controls.eye);std::copy_n(previousConfig_.forward,3,controls.forward);
    c.list->SetComputeRoot32BitConstants(5,12,&controls,0);c.list->Dispatch((width_+7)/8,(height_+7)/8,1);
    Transition(c,colors_[slot_].Get(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    Transition(c,raw,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    copyVertices();previousConfig_=cfg;for(size_t i=0;i<instances.records.size();++i)previousWorlds_[i]=instances.records[i].world;
    auto result=colors_[slot_].Get();slot_^=1;valid_=true;return result;
}
}
