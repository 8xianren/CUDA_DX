#include "external.h"
#include <cstring>
#include <iostream>
#include <stdexcept>

namespace {
// CUDA导入NT HANDLE并不接管该句柄；成功或异常都由创建者CloseHandle。
struct Handle { HANDLE value=nullptr; ~Handle(){if(value)CloseHandle(value);} };
}
void CudaCheck(cudaError_t e,const char* what) {
    if(e!=cudaSuccess)throw std::runtime_error(std::string(what)+": "+cudaGetErrorString(e));
}
void SelectMatchingCudaDevice(ID3D12Device* d) {
    if(d->GetNodeCount()!=1)throw std::runtime_error("single-node adapter required");
    auto luid=d->GetAdapterLuid();int count=0;
    CudaCheck(cudaGetDeviceCount(&count),"device count");
    for(int i=0;i<count;++i){
        cudaDeviceProp p{};CudaCheck(cudaGetDeviceProperties(&p,i),"device properties");
        if(std::memcmp(p.luid,&luid,sizeof(luid))==0 && p.luidDeviceNodeMask==1){
            CudaCheck(cudaSetDevice(i),"set matching device");
            std::cout<<"cuda_device="<<p.name<<" ordinal="<<i<<" sm="<<p.major<<p.minor<<" luid_match=1\n";return;
        }
    }
    throw std::runtime_error("no CUDA device matches DXGI LUID");
}
ExternalBuffer::ExternalBuffer(UploadContext& c,uint64_t bytes):logicalBytes(bytes) {
    if(!bytes)throw std::runtime_error("zero shared buffer");
    auto desc=BufferDesc(bytes);D3D12_HEAP_PROPERTIES hp{};hp.Type=D3D12_HEAP_TYPE_DEFAULT;
    hp.CreationNodeMask=hp.VisibleNodeMask=1;
    // committed资源专属分配，D3D12逻辑Width与底层allocation大小不能混用。
    allocationBytes=c.device->GetResourceAllocationInfo(0,1,&desc).SizeInBytes;
    Check(c.device->CreateCommittedResource(&hp,D3D12_HEAP_FLAG_SHARED,&desc,
        D3D12_RESOURCE_STATE_COMMON,nullptr,IID_PPV_ARGS(&resource)),"shared buffer");
    Handle h;Check(c.device->CreateSharedHandle(resource.Get(),nullptr,GENERIC_ALL,nullptr,&h.value),"memory handle");
    cudaExternalMemoryHandleDesc e{};e.type=cudaExternalMemoryHandleTypeD3D12Resource;
    e.handle.win32.handle=h.value;e.size=allocationBytes;e.flags=cudaExternalMemoryDedicated;
    CudaCheck(cudaImportExternalMemory(&memory,&e),"import memory");
    cudaExternalMemoryBufferDesc m{};m.offset=0;m.size=logicalBytes;
    auto result=cudaExternalMemoryGetMappedBuffer(&pointer,memory,&m);
    if(result!=cudaSuccess){cudaDestroyExternalMemory(memory);memory=nullptr;CudaCheck(result,"map external buffer");}
}
ExternalBuffer::~ExternalBuffer(){
    // 映射必须先释放；COM resource成员随后析构，底层D3D分配最后释放。
    if(pointer)cudaFree(pointer);
    if(memory)cudaDestroyExternalMemory(memory);
}
ExternalFence::ExternalFence(UploadContext& c){
    Check(c.device->CreateFence(0,D3D12_FENCE_FLAG_SHARED,IID_PPV_ARGS(&fence)),"shared fence");
    Handle h;Check(c.device->CreateSharedHandle(fence.Get(),nullptr,GENERIC_ALL,nullptr,&h.value),"fence handle");
    cudaExternalSemaphoreHandleDesc d{};d.type=cudaExternalSemaphoreHandleTypeD3D12Fence;d.handle.win32.handle=h.value;
    CudaCheck(cudaImportExternalSemaphore(&semaphore,&d),"import fence");
}
ExternalFence::~ExternalFence(){if(semaphore)cudaDestroyExternalSemaphore(semaphore);}
void ExternalFence::WaitCuda(uint64_t v,cudaStream_t s){
    cudaExternalSemaphoreWaitParams p{};p.params.fence.value=v;
    CudaCheck(cudaWaitExternalSemaphoresAsync(&semaphore,&p,1,s),"CUDA wait");
}
void ExternalFence::SignalCuda(uint64_t v,cudaStream_t s){
    cudaExternalSemaphoreSignalParams p{};p.params.fence.value=v;
    CudaCheck(cudaSignalExternalSemaphoresAsync(&semaphore,&p,1,s),"CUDA signal");
}
void DrainFence(ID3D12Fence* f,uint64_t v){
    Handle event;event.value=CreateEventW(nullptr,FALSE,FALSE,nullptr);
    if(!event.value)throw std::runtime_error("event creation failed");
    Check(f->SetEventOnCompletion(v,event.value),"drain event");
    if(WaitForSingleObject(event.value,30000)!=WAIT_OBJECT_0 || f->GetCompletedValue()==UINT64_MAX)
        throw std::runtime_error("GPU drain timed out or device removed");
}
void Barrier(ID3D12GraphicsCommandList* l,ID3D12Resource* r,D3D12_RESOURCE_STATES b,D3D12_RESOURCE_STATES a){
    D3D12_RESOURCE_BARRIER barrier{};barrier.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition={r,D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,b,a};l->ResourceBarrier(1,&barrier);
}
