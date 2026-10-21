#pragma once
#include <cuda_runtime.h>
#include "scene_io.h"
#include <string>
namespace cuda_pt {
inline void CheckCuda(cudaError_t error,const char* operation){if(error!=cudaSuccess)throw std::runtime_error(std::string(operation)+": "+cudaGetErrorString(error));}
// 本节提交后均在离开作用域前完成stream同步；RAII拥有单个device分配，不提供隐式共享所有权。
template<class T> struct DeviceBuffer {
    T* pointer=nullptr;size_t count=0;
    explicit DeviceBuffer(size_t n):count(n){if(n)CheckCuda(cudaMalloc(reinterpret_cast<void**>(&pointer),n*sizeof(T)),"cudaMalloc");}
    explicit DeviceBuffer(const std::vector<T>& source):DeviceBuffer(source.size()){if(count)CheckCuda(cudaMemcpy(pointer,source.data(),count*sizeof(T),cudaMemcpyHostToDevice),"upload");}
    ~DeviceBuffer(){if(pointer)cudaFree(pointer);}DeviceBuffer(const DeviceBuffer&)=delete;DeviceBuffer& operator=(const DeviceBuffer&)=delete;
    std::vector<T> Download() const{std::vector<T> result(count);if(count)CheckCuda(cudaMemcpy(result.data(),pointer,count*sizeof(T),cudaMemcpyDeviceToHost),"download");return result;}
};
struct CudaStream {cudaStream_t value=nullptr;CudaStream(){CheckCuda(cudaStreamCreateWithFlags(&value,cudaStreamNonBlocking),"stream create");}~CudaStream(){if(value)cudaStreamDestroy(value);}};
struct CudaEvents {cudaEvent_t begin=nullptr,end=nullptr;CudaEvents(){CheckCuda(cudaEventCreate(&begin),"event begin");try{CheckCuda(cudaEventCreate(&end),"event end");}catch(...){cudaEventDestroy(begin);throw;}}
    ~CudaEvents(){cudaEventDestroy(begin);cudaEventDestroy(end);}};
}
