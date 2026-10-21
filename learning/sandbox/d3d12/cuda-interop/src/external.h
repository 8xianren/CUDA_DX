#pragma once
#include "gpu_upload.h"
#include <cuda_runtime.h>

void CudaCheck(cudaError_t result,const char* operation);
void SelectMatchingCudaDevice(ID3D12Device* device);

// 共享对象不拥有队列；调用者必须先排空两侧工作才能销毁。禁止复制双重释放。
struct ExternalBuffer {
    ComPtr<ID3D12Resource> resource;
    cudaExternalMemory_t memory=nullptr;
    void* pointer=nullptr;
    uint64_t logicalBytes=0,allocationBytes=0;
    ExternalBuffer(UploadContext& c,uint64_t bytes);
    ~ExternalBuffer();
    ExternalBuffer(const ExternalBuffer&)=delete;
    ExternalBuffer& operator=(const ExternalBuffer&)=delete;
};
struct ExternalFence {
    ComPtr<ID3D12Fence> fence;
    cudaExternalSemaphore_t semaphore=nullptr;
    explicit ExternalFence(UploadContext& c);
    ~ExternalFence();
    ExternalFence(const ExternalFence&)=delete;
    ExternalFence& operator=(const ExternalFence&)=delete;
    void WaitCuda(uint64_t value,cudaStream_t stream);
    void SignalCuda(uint64_t value,cudaStream_t stream);
};
// 一个CPU事件用于最后收尾；不用于每帧CUDA->D3D12交接。
void DrainFence(ID3D12Fence* fence,uint64_t value);
void Barrier(ID3D12GraphicsCommandList* list,ID3D12Resource* resource,
             D3D12_RESOURCE_STATES before,D3D12_RESOURCE_STATES after);
