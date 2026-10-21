#include "path_history.h"
#include <fstream>
#include <iterator>

PathHistoryKey MakeHistoryKey(const PathConfig& c,uint64_t scene,uint64_t material){
    PathHistoryKey k;size_t at=0;
    for(const float* v:{c.eye,c.forward,c.right,c.up,c.environment})for(unsigned i=0;i<3;++i)k.floats[at++]=v[i];
    for(float v:{c.tanHalfFovY,c.environmentIntensity,c.offset,c.lightScale,c.totalArea})k.floats[at++]=v;
    k.integers={c.width,c.height,c.seed,c.maxScatters,c.mode,c.rrStart,c.flags,c.lightCount};
    k.sceneRevision=scene;k.materialRevision=material;return k;
}
PathHistory::PathHistory(UploadContext& c,const std::filesystem::path& rayDxil,const std::filesystem::path& accumulateDxil)
    :context_(c),rays_(c,rayDxil){
    // 根参数0=t0批结果，1=u0持久历史，2=b0六个32位常量。根索引与寄存器编号不是一回事。
    D3D12_ROOT_PARAMETER p[3]{};
    p[0].ParameterType=D3D12_ROOT_PARAMETER_TYPE_SRV;p[0].Descriptor={0,0};
    p[1].ParameterType=D3D12_ROOT_PARAMETER_TYPE_UAV;p[1].Descriptor={0,0};
    p[2].ParameterType=D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;p[2].Constants={0,0,6};
    D3D12_ROOT_SIGNATURE_DESC desc{};desc.NumParameters=3;desc.pParameters=p;
    ComPtr<ID3DBlob> blob,error;
    Check(D3D12SerializeRootSignature(&desc,D3D_ROOT_SIGNATURE_VERSION_1,&blob,&error),"history root serialize");
    Check(c.device->CreateRootSignature(0,blob->GetBufferPointer(),blob->GetBufferSize(),IID_PPV_ARGS(&root_)),"history root");
    std::ifstream file(accumulateDxil,std::ios::binary);
    std::vector<char> code{std::istreambuf_iterator<char>(file),std::istreambuf_iterator<char>()};
    Require(!code.empty(),"missing accumulation DXIL");
    D3D12_COMPUTE_PIPELINE_STATE_DESC pipeline{};pipeline.pRootSignature=root_.Get();pipeline.CS={code.data(),code.size()};
    Check(c.device->CreateComputePipelineState(&pipeline,IID_PPV_ARGS(&accumulate_)),"history compute PSO");
}
bool PathHistory::Record(const MaterialBindings& bindings,const GpuScene& gpu,const InstanceFrame& frame,
    PathConfig cfg,const std::vector<PathLight>& lights,uint64_t sceneRevision,uint64_t materialRevision,bool forceReset){
    Require(cfg.width>0&&cfg.width<=4096&&cfg.height>0&&cfg.height<=4096&&cfg.spp>0&&cfg.spp<=32,"history dispatch extent/batch range");
    const auto nextKey=MakeHistoryKey(cfg,sceneRevision,materialRevision);
    for(float v:nextKey.floats)Require(std::isfinite(v),"nonfinite history configuration");
    bool reset=forceReset||!valid_||!(key_==nextKey);
    // count上限使float权重与uint32诊断累计保留充分余量；超过时显式失败，不静默溢出或偷偷换目标。
    Require(reset||count_<=1048576-cfg.spp,"history sample limit");
    const UINT previous=reset?0:count_;
    if(width_!=cfg.width||height_!=cfg.height){
        Require(uploads_.empty(),"flush pending batches before resize");
        Require(context_.fence->GetCompletedValue()==context_.submitted,"resize requires completed fence");
        auto b=BufferDesc(uint64_t(cfg.width)*cfg.height*sizeof(PathPixel));b.Flags=D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
        auto h=BufferDesc(uint64_t(cfg.width)*cfg.height*sizeof(PathHistoryPixel));h.Flags=D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
        // 先成功创建两份新资源再替换旧对象，避免部分分配失败后继续使用一半新尺寸。
        auto nextBatch=MakeResource(context_,b,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        auto nextHistory=MakeResource(context_,h,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        batch_=std::move(nextBatch);history_=std::move(nextHistory);width_=cfg.width;height_=cfg.height;
    }
    if(reset){Require(generation_!=UINT_MAX,"history generation overflow");++generation_;}
    cfg.sampleOffset=previous;auto bytes=PackPathConfig(cfg,lights);
    uploads_.push_back(InstanceUpload(context_,bytes.data(),bytes.size()));
    rays_.Record(context_,bindings,gpu,frame,uploads_.back().Get(),batch_.Get(),width_,height_);
    // DXR生产者写UAV -> compute消费者读SRV。同队列先后次序之外，还必须声明访问依赖与状态。
    Transition(context_,batch_.Get(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    context_.list->SetComputeRootSignature(root_.Get());context_.list->SetPipelineState(accumulate_.Get());
    context_.list->SetComputeRootShaderResourceView(0,batch_->GetGPUVirtualAddress());
    context_.list->SetComputeRootUnorderedAccessView(1,history_->GetGPUVirtualAddress());
    UINT constants[]{width_,height_,cfg.spp,previous,generation_,cfg.flags};
    context_.list->SetComputeRoot32BitConstants(2,6,constants,0);
    context_.list->Dispatch((width_+7)/8,(height_+7)/8,1);
    // 历史保持UAV状态，但下一批会读取本批写入值，因此仍需要UAV barrier。
    D3D12_RESOURCE_BARRIER barrier{};barrier.Type=D3D12_RESOURCE_BARRIER_TYPE_UAV;barrier.UAV.pResource=history_.Get();
    context_.list->ResourceBarrier(1,&barrier);
    Transition(context_,batch_.Get(),D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    key_=nextKey;valid_=true;count_=previous+cfg.spp;return reset;
}
void PathHistory::Flush(const std::function<void()>& beforeSignal){
    // 本课批次组只等一次。等待失败立即抛异常，禁止清理后继续使用同一渲染器。
    context_.SubmitWait(beforeSignal);uploads_.clear();
}
std::vector<PathHistoryPixel> PathHistory::Readback(const std::function<void()>& beforeSignal){
    Require(valid_,"readback before history record");
    const size_t bytes=size_t(width_)*height_*sizeof(PathHistoryPixel);
    auto readback=MakeResource(context_,BufferDesc(bytes),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
    Transition(context_,history_.Get(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_COPY_SOURCE);
    context_.list->CopyBufferRegion(readback.Get(),0,history_.Get(),0,bytes);
    Transition(context_,history_.Get(),D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    Flush(beforeSignal);
    void* data=nullptr;D3D12_RANGE range{0,bytes},noWrite{0,0};
    Check(readback->Map(0,&range,&data),"history readback Map");
    std::vector<PathHistoryPixel> result(size_t(width_)*height_);memcpy(result.data(),data,bytes);readback->Unmap(0,&noWrite);
    return result;
}
