#include "path_interop.h"
#include <fstream>
#include <iterator>
#include <iostream>
#include <cstdlib>

void CudaCheck(cudaError_t error,const char* operation){
    if(error!=cudaSuccess)throw std::runtime_error(std::string(operation)+": "+cudaGetErrorString(error));
}
namespace {
// NT句柄归本进程所有。CUDA import并不接管这个HANDLE；成功和失败路径均关闭它。
struct Handle {HANDLE value=nullptr;~Handle(){if(value)CloseHandle(value);}};
void Barrier(ID3D12GraphicsCommandList* list,ID3D12Resource* resource,D3D12_RESOURCE_STATES before,D3D12_RESOURCE_STATES after){
    D3D12_RESOURCE_BARRIER b{};b.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b.Transition={resource,D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,before,after};list->ResourceBarrier(1,&b);
}
template<class T> std::vector<T> Read(ID3D12Resource* resource,size_t count){
    std::vector<T> result(count);void* data=nullptr;D3D12_RANGE range{0,count*sizeof(T)},empty{0,0};
    Check(resource->Map(0,&range,&data),"interop readback Map");memcpy(result.data(),data,range.End);resource->Unmap(0,&empty);return result;
}
}
PathInterop::PathInterop(UploadContext& c,UINT width,UINT height,const std::filesystem::path& dxil)
    :c_(c),width_(width),height_(height),pixels_(size_t(width)*height),bytes_(pixels_*6*sizeof(float4)),clock_(c){
    try{
        Require(width>0&&height>0&&width<=4096&&height<=4096,"interop extent range");
        Require(c.device->GetNodeCount()==1,"interop lesson requires single-node adapter");
        LUID luid=c.device->GetAdapterLuid();int devices=0;CudaCheck(cudaGetDeviceCount(&devices),"cudaGetDeviceCount");
        // CUDA ordinal与DXGI枚举序号没有对应保证；用Windows适配器LUID逐字节匹配。
        for(int i=0;i<devices;++i){cudaDeviceProp p{};CudaCheck(cudaGetDeviceProperties(&p,i),"cudaGetDeviceProperties");
            if(memcmp(p.luid,&luid,sizeof(luid))==0&&p.luidDeviceNodeMask==1){cudaDevice_=i;std::cout<<"CUDA/D3D LUID match: "<<p.name<<" sm_"<<p.major<<p.minor<<'\n';break;}}
        Require(cudaDevice_>=0,"no matching CUDA device for D3D adapter");CudaCheck(cudaSetDevice(cudaDevice_),"cudaSetDevice");
        CudaCheck(cudaStreamCreateWithFlags(&stream_,cudaStreamNonBlocking),"cudaStreamCreateWithFlags");
        CudaCheck(cudaEventCreate(&begin_),"cudaEventCreate begin");CudaCheck(cudaEventCreate(&end_),"cudaEventCreate end");
        auto desc=BufferDesc(bytes_);desc.Flags=D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
        D3D12_HEAP_PROPERTIES heap{};heap.Type=D3D12_HEAP_TYPE_DEFAULT;heap.CreationNodeMask=heap.VisibleNodeMask=1;
        Check(c.device->CreateCommittedResource(&heap,D3D12_HEAP_FLAG_SHARED,&desc,D3D12_RESOURCE_STATE_COMMON,nullptr,IID_PPV_ARGS(&shared_)),"shared DEFAULT buffer");
        // import size必须是底层allocation大小，不是逻辑图像字节数；map只暴露有效六平面范围。
        allocation_=c.device->GetResourceAllocationInfo(0,1,&desc).SizeInBytes;
        Handle memoryHandle;Check(c.device->CreateSharedHandle(shared_.Get(),nullptr,GENERIC_ALL,nullptr,&memoryHandle.value),"shared memory HANDLE");
        cudaExternalMemoryHandleDesc external{};external.type=cudaExternalMemoryHandleTypeD3D12Resource;
        external.handle.win32.handle=memoryHandle.value;external.size=allocation_;external.flags=cudaExternalMemoryDedicated;
        CudaCheck(cudaImportExternalMemory(&memory_,&external),"cudaImportExternalMemory");
        cudaExternalMemoryBufferDesc mapping{};mapping.offset=0;mapping.size=bytes_;
        CudaCheck(cudaExternalMemoryGetMappedBuffer(reinterpret_cast<void**>(&pointer_),memory_,&mapping),"cudaExternalMemoryGetMappedBuffer");
        Check(c.device->CreateFence(0,D3D12_FENCE_FLAG_SHARED,IID_PPV_ARGS(&fence_)),"shared fence");
        Handle fenceHandle;Check(c.device->CreateSharedHandle(fence_.Get(),nullptr,GENERIC_ALL,nullptr,&fenceHandle.value),"shared fence HANDLE");
        cudaExternalSemaphoreHandleDesc semaphore{};semaphore.type=cudaExternalSemaphoreHandleTypeD3D12Fence;semaphore.handle.win32.handle=fenceHandle.value;
        CudaCheck(cudaImportExternalSemaphore(&semaphore_,&semaphore),"cudaImportExternalSemaphore");
        readback_=MakeResource(c,BufferDesc(bytes_),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
        sourceReadback_=MakeResource(c,BufferDesc(pixels_*sizeof(PathHistoryPixel)),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
        Check(c.device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&allocator_)),"consumer allocator");
        Check(c.device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,allocator_.Get(),nullptr,IID_PPV_ARGS(&consumerList_)),"consumer command list");
        Check(consumerList_->Close(),"initial consumer Close");
        D3D12_ROOT_PARAMETER p[3]{};p[0].ParameterType=D3D12_ROOT_PARAMETER_TYPE_SRV;p[0].Descriptor={0,0};
        p[1].ParameterType=D3D12_ROOT_PARAMETER_TYPE_UAV;p[1].Descriptor={0,0};
        p[2].ParameterType=D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;p[2].Constants={0,0,4};
        D3D12_ROOT_SIGNATURE_DESC r{};r.NumParameters=3;r.pParameters=p;ComPtr<ID3DBlob> blob,error;
        Check(D3D12SerializeRootSignature(&r,D3D_ROOT_SIGNATURE_VERSION_1,&blob,&error),"pack root serialize");
        Check(c.device->CreateRootSignature(0,blob->GetBufferPointer(),blob->GetBufferSize(),IID_PPV_ARGS(&root_)),"pack root");
        std::ifstream f(dxil,std::ios::binary);std::vector<char> code{std::istreambuf_iterator<char>(f),std::istreambuf_iterator<char>()};Require(!code.empty(),"missing pack DXIL");
        D3D12_COMPUTE_PIPELINE_STATE_DESC pipeline{};pipeline.pRootSignature=root_.Get();pipeline.CS={code.data(),code.size()};
        Check(c.device->CreateComputePipelineState(&pipeline,IID_PPV_ARGS(&pack_)),"pack PSO");
    }catch(...){ReleaseCuda();throw;}
}
void PathInterop::ReleaseCuda() noexcept{
    // 只在构造未提交或Run完成后调用。映射是CUDA拥有的地址映射，底层资源仍归D3D对象所有。
    // 先销毁映射，再销毁import对象，最后COM释放shared_。外部消费者必须更早析构。
    if(pointer_)cudaFree(pointer_);if(memory_)cudaDestroyExternalMemory(memory_);
    if(semaphore_)cudaDestroyExternalSemaphore(semaphore_);
    if(begin_)cudaEventDestroy(begin_);if(end_)cudaEventDestroy(end_);if(stream_)cudaStreamDestroy(stream_);
    pointer_=nullptr;memory_=nullptr;semaphore_=nullptr;begin_=end_=nullptr;stream_=nullptr;
}
PathInterop::~PathInterop(){ReleaseCuda();}
InteropResult PathInterop::Run(PathHistory& history,PathConsumer* consumer,
    const std::function<void(ID3D12GraphicsCommandList*,ID3D12Resource*)>& recordDisplay,const std::function<void()>& present){
    Require(history.Resource()&&history.Resource()->GetDesc().Width==pixels_*sizeof(PathHistoryPixel),"interop history extent mismatch");
    Require(c_.fence->GetCompletedValue()==c_.submitted,"previous GPU group not retired");
    Require(round_<0xffff,"audit stamp sequence exhausted");
    const uint64_t ready=2*round_+1,done=ready+1;const unsigned stamp=0xc0da0000u|unsigned(++round_);
    if(!frameBegun_)clock_.Mark(c_.list.Get(),0);clock_.Mark(c_.list.Get(),1);
    // 生产者command list已有DXR与累积。状态转换只负责D3D访问；跨API先后由外部Fence负责。
    Barrier(c_.list.Get(),history.Resource(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    Barrier(c_.list.Get(),shared_.Get(),D3D12_RESOURCE_STATE_COMMON,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    c_.list->SetComputeRootSignature(root_.Get());c_.list->SetPipelineState(pack_.Get());
    c_.list->SetComputeRootShaderResourceView(0,history.Resource()->GetGPUVirtualAddress());
    c_.list->SetComputeRootUnorderedAccessView(1,shared_->GetGPUVirtualAddress());
    UINT constants[]{width_,height_,history.Count(),history.Generation()};c_.list->SetComputeRoot32BitConstants(2,4,constants,0);
    c_.list->Dispatch((width_+7)/8,(height_+7)/8,1);
    Barrier(c_.list.Get(),shared_.Get(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_COMMON);
    Barrier(c_.list.Get(),history.Resource(),D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    clock_.Mark(c_.list.Get(),2);
    // 预先录制回接列表；它只有排在queue.Wait(done)之后才能执行。此时还没有提交。
    Check(allocator_->Reset(),"consumer allocator Reset");Check(consumerList_->Reset(allocator_.Get(),nullptr),"consumer list Reset");
    clock_.Mark(consumerList_.Get(),3);
    if(recordDisplay)recordDisplay(consumerList_.Get(),shared_.Get());
    clock_.Mark(consumerList_.Get(),4);
    Barrier(consumerList_.Get(),shared_.Get(),D3D12_RESOURCE_STATE_COMMON,D3D12_RESOURCE_STATE_COPY_SOURCE);
    consumerList_->CopyBufferRegion(readback_.Get(),0,shared_.Get(),0,bytes_);
    Barrier(consumerList_.Get(),shared_.Get(),D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_COMMON);
    Barrier(consumerList_.Get(),history.Resource(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_COPY_SOURCE);
    consumerList_->CopyBufferRegion(sourceReadback_.Get(),0,history.Resource(),0,pixels_*sizeof(PathHistoryPixel));
    Barrier(consumerList_.Get(),history.Resource(),D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    clock_.Mark(consumerList_.Get(),5);clock_.Resolve(consumerList_.Get());
    Check(consumerList_->Close(),"consumer list Close");
    try{
        history.Flush([&]{
            // SubmitWait已经Execute生产者，但CPU不等待生产者完成。下面全部为设备队列依赖。
            Check(c_.queue->Signal(fence_.Get(),ready),"D3D Signal ready");
            cudaExternalSemaphoreWaitParams wait{};wait.params.fence.value=ready;
            CudaCheck(cudaWaitExternalSemaphoresAsync(&semaphore_,&wait,1,stream_),"CUDA wait ready");
            CudaCheck(cudaEventRecord(begin_,stream_),"consumer begin event");
            if(consumer)consumer->Enqueue();
            CudaCheck(AuditPacket(pointer_,unsigned(pixels_),history.Count(),history.Generation(),stamp,!consumer,stream_),"CUDA packet audit launch");
            CudaCheck(cudaEventRecord(end_,stream_),"consumer end event");
            cudaExternalSemaphoreSignalParams signal{};signal.params.fence.value=done;
            CudaCheck(cudaSignalExternalSemaphoresAsync(&semaphore_,&signal,1,stream_),"CUDA signal done");
            Check(c_.queue->Wait(fence_.Get(),done),"D3D queue Wait done");
            ID3D12CommandList* lists[]{consumerList_.Get()};c_.queue->ExecuteCommandLists(1,lists);
            if(present)present();
            // 返回后SubmitWait追加本地Fence并等一次CPU，涵盖消费者和readback，不只是DXR。
        });
        CudaCheck(cudaStreamSynchronize(stream_),"completed CUDA stream status"); // 末尾错误检查，无中间CPU交接。
        if(consumer)consumer->CheckCompleted();
    }catch(const std::exception& e){
        // 提交后若外部signal失败，队列可能已等待永远不会到来的值。教学程序不尝试继续或
        // 析构正在使用的资源：输出明确失败后终止进程，让OS回收。生产应走设备丢失恢复路径。
        std::cerr<<"fatal submitted interop failure: "<<e.what()<<std::endl;std::_Exit(EXIT_FAILURE);
    }
    Require(fence_->GetCompletedValue()==done,"external fence completion mismatch");
    // GPU完成还不等于所有CPU侧命令引用都消失。清空回接列表，避免下一次ResizeBuffers仍被
    // 已关闭的旧command list引用Back Buffer；此时allocator也已由末尾Fence保护，可以复用。
    Check(allocator_->Reset(),"retire consumer allocator");Check(consumerList_->Reset(allocator_.Get(),nullptr),"clear consumer references");
    Check(consumerList_->Close(),"close empty consumer list");
    InteropResult result;result.packet=Read<float4>(readback_.Get(),pixels_*6);result.source=Read<PathHistoryPixel>(sourceReadback_.Get(),pixels_);
    result.ready=ready;result.done=done;result.stamp=stamp;result.allocationBytes=allocation_;
    result.gpuMilliseconds=clock_.ReadCompleted();frameBegun_=false;
    CudaCheck(cudaEventElapsedTime(&result.consumerMilliseconds,begin_,end_),"consumer event time");return result;
}
