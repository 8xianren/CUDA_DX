#pragma once
#include "dxr_progressive_reference.h"
#include <functional>
// R.13.6/7共用的提交层。场景与管线由调用方持有；本类只拥有两槽和一块共享历史。
// 回调在对应Fence完成后读取记录；调用者必须在销毁回调引用的状态前flush。
struct RaySubmission {
    view_reference::ViewData view{};
    std::array<UINT,4> controls{};
};
class GpuRaySequence {
public:
    using Readback=std::function<void(const progressive_reference::Record*,const RaySubmission&)>;
    // 可选显示扩展：record在DispatchRays之后记录命令，必须把history恢复为UAV。
    // submitted在Execute之后、Signal之前调用（窗口模式在这里Present）。旧课程留空不改变行为。
    using RecordTail=std::function<void(ID3D12GraphicsCommandList4*,ID3D12Resource*)>;
    GpuRaySequence(ID3D12Device5* dev,ID3D12CommandQueue* queue,ID3D12Fence* fence,
        ID3D12RootSignature* root,ID3D12StateObject* state,ID3D12Resource* tlas,
        ID3D12Resource* vb,ID3D12Resource* ib,ID3D12Resource* sbt,
        std::function<void(UINT64)> wait):queue_(queue),fence_(fence),root_(root),state_(state),tlas_(tlas),vb_(vb),ib_(ib),sbt_(sbt),wait_(std::move(wait)){
        // 前提：调用方已等待此前提交全部完成，且本序列独占该Fence的Signal计数。
        // 只有此前队列已排空，才能用completed值作为下一次Signal的基数；history reset不回退Fence。
        lastFence_=fence_->GetCompletedValue();require(lastFence_!=UINT64_MAX,"Removed device before sequence");
        auto flags=D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
        history_=make_buffer(dev,D3D12_HEAP_TYPE_DEFAULT,UINT64(progressive_reference::Pixels)*16,flags,D3D12_RESOURCE_STATE_COMMON);
        camera_=make_buffer(dev,D3D12_HEAP_TYPE_UPLOAD,512,D3D12_RESOURCE_FLAG_NONE,D3D12_RESOURCE_STATE_GENERIC_READ);
        D3D12_RANGE noRead{0,0};check(camera_->Map(0,&noRead,reinterpret_cast<void**>(&mapped_)),"Map sequence camera");
        for(auto& s:slots_){
            check(dev->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&s.allocator)),"Create sequence allocator");
            check(dev->CreateCommandList1(0,D3D12_COMMAND_LIST_TYPE_DIRECT,D3D12_COMMAND_LIST_FLAG_NONE,IID_PPV_ARGS(&s.list)),"Create sequence list");
            s.output=make_buffer(dev,D3D12_HEAP_TYPE_DEFAULT,Bytes,flags,D3D12_RESOURCE_STATE_COMMON);
            s.readback=make_buffer(dev,D3D12_HEAP_TYPE_READBACK,Bytes,D3D12_RESOURCE_FLAG_NONE,D3D12_RESOURCE_STATE_COPY_DEST);
        }
    }
    GpuRaySequence(const GpuRaySequence&)=delete;
    GpuRaySequence& operator=(const GpuRaySequence&)=delete;
    ~GpuRaySequence(){
        // 正常调用路径必须已flush；不让包含悬空引用的回调在析构中意外执行。
        require(slots_[0].fence==0&&slots_[1].fence==0,"Sequence must be flushed before destruction");
        D3D12_RANGE written{0,512};camera_->Unmap(0,&written);
    }
    void enqueue(const RaySubmission& input,Readback callback,RecordTail record={},std::function<void()> submitted={}){
        UINT index=issued_%2;Slot& s=slots_[index];retire(s);
        s.input=input;s.callback=std::move(callback);
        std::memcpy(mapped_+index*256,&input.view,sizeof(input.view));
        check(s.allocator->Reset(),"Reset sequence allocator");check(s.list->Reset(s.allocator.Get(),nullptr),"Reset sequence list");
        transition(s.list.Get(),s.output.Get(),s.outputState,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        if(issued_==0)transition(s.list.Get(),history_.Get(),D3D12_RESOURCE_STATE_COMMON,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        else uav_barrier(s.list.Get(),history_.Get());
        s.list->SetComputeRootSignature(root_);
        s.list->SetComputeRootShaderResourceView(0,tlas_->GetGPUVirtualAddress());
        s.list->SetComputeRootUnorderedAccessView(1,s.output->GetGPUVirtualAddress());
        s.list->SetComputeRootConstantBufferView(2,camera_->GetGPUVirtualAddress()+index*256);
        s.list->SetComputeRootShaderResourceView(3,vb_->GetGPUVirtualAddress());
        s.list->SetComputeRootShaderResourceView(4,ib_->GetGPUVirtualAddress());
        s.list->SetComputeRootUnorderedAccessView(5,history_->GetGPUVirtualAddress());
        s.list->SetComputeRoot32BitConstants(6,4,input.controls.data(),0);
        s.list->SetPipelineState1(state_);
        auto base=sbt_->GetGPUVirtualAddress();D3D12_DISPATCH_RAYS_DESC dispatch{};
        dispatch.RayGenerationShaderRecord={base,32};dispatch.MissShaderTable={base+64,64,32};
        dispatch.HitGroupTable={base+128,32,32};dispatch.Width=progressive_reference::Width;dispatch.Height=progressive_reference::Height;dispatch.Depth=1;
        s.list->DispatchRays(&dispatch);
        if(record)record(s.list.Get(),history_.Get());
        transition(s.list.Get(),s.output.Get(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_COPY_SOURCE);
        s.outputState=D3D12_RESOURCE_STATE_COPY_SOURCE;s.list->CopyResource(s.readback.Get(),s.output.Get());
        check(s.list->Close(),"Close sequence list");ID3D12CommandList* lists[]={s.list.Get()};queue_->ExecuteCommandLists(1,lists);
        if(submitted)submitted(); // Present不代表GPU已完成；后面的Fence才是CPU回收条件。
        s.fence=++lastFence_;++issued_;check(queue_->Signal(fence_,s.fence),"Signal sequence fence");
    }
    void flush(){
        if(slots_[0].fence&&slots_[1].fence&&slots_[0].fence>slots_[1].fence){retire(slots_[1]);retire(slots_[0]);}
        else {retire(slots_[0]);retire(slots_[1]);}
    }
    UINT64 last_fence()const{return lastFence_;}
    // resize前由调用方执行：先退役所有在途提交/读回，再丢弃录有旧Back Buffer的命令。
    // 不销毁history、不回退样本序号或Fence；Reset allocator只有Fence完成后才安全。
    void discard_recordings(){
        flush();
        for(auto& s:slots_){check(s.allocator->Reset(),"Resize allocator reset");
            check(s.list->Reset(s.allocator.Get(),nullptr),"Resize list reset");check(s.list->Close(),"Close empty resize list");}
    }
private:
    static constexpr UINT64 Bytes=UINT64(progressive_reference::Pixels)*sizeof(progressive_reference::Record);
    struct Slot {ComPtr<ID3D12CommandAllocator> allocator;ComPtr<ID3D12GraphicsCommandList4> list;
        ComPtr<ID3D12Resource> output,readback;UINT64 fence=0;RaySubmission input;Readback callback;
        D3D12_RESOURCE_STATES outputState=D3D12_RESOURCE_STATE_COMMON;};
    void retire(Slot& s){if(!s.fence)return;wait_(s.fence);
        progressive_reference::Record* data=nullptr;D3D12_RANGE range{0,SIZE_T(Bytes)};
        check(s.readback->Map(0,&range,reinterpret_cast<void**>(&data)),"Map sequence readback");
        s.callback(data,s.input);D3D12_RANGE noWrite{0,0};s.readback->Unmap(0,&noWrite);
        s.callback={};s.fence=0;
    }
    // 借用调用方的对象，调用期间由main持有COM引用；新增资源则由本类持有。
    ID3D12CommandQueue* queue_;ID3D12Fence* fence_;ID3D12RootSignature* root_;ID3D12StateObject* state_;
    ID3D12Resource *tlas_,*vb_,*ib_,*sbt_;std::function<void(UINT64)> wait_;
    ComPtr<ID3D12Resource> history_,camera_;unsigned char* mapped_=nullptr;
    Slot slots_[2];UINT64 lastFence_=0,issued_=0;
};
