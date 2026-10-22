#pragma once
#include "gpu_resources.h"
#include "external.h"

namespace neural {
// 共享纹理仍是 D3D12 的 tiled texture，不能当成 CUDA 线性地址。
// 本对象拥有 D3D resource、CUDA external memory、mipmapped array 三层资源。
// 释放顺序为 mapped array -> external memory -> COM resource；释放前由调用者排空队列。
class SharedTexture {
public:
    aa::Texture texture;
    cudaArray_t array=nullptr; // 借用 mip 0，不能独立 cudaFreeArray。
    uint64_t allocationBytes=0;
    SharedTexture(UploadContext&,UINT width,UINT height,bool rgba);
    ~SharedTexture();
    SharedTexture(const SharedTexture&)=delete;
    SharedTexture& operator=(const SharedTexture&)=delete;
    void CopyFrom(const void* deviceLinear,cudaStream_t);
    void CopyTo(void* deviceLinear,cudaStream_t);
private:
    cudaExternalMemory_t memory=nullptr;
    cudaMipmappedArray_t mip=nullptr;
    size_t pixelBytes=0;
};
}
