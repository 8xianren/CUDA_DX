#pragma once
#include "cpu_mesh.h"
#include <cuda_runtime.h>
namespace character {
// CUDA二进制布局独立于Assimp类型；按行保存4x4位置矩阵和3x4逆转置法线矩阵。
struct SkinMatrix {float position[16];float normal[12];};
static_assert(sizeof(SkinMatrix)==112);
struct GpuInfluence {unsigned joint[4];float weight[4];};
static_assert(sizeof(GpuInfluence)==32);
struct SkinDevice {
    Vertex *bind=nullptr,*output=nullptr;GpuInfluence* influence=nullptr;SkinMatrix* matrices=nullptr;
    unsigned vertices=0,joints=0;
    SkinDevice(const Vertex*,const GpuInfluence*,unsigned vertices,unsigned joints);
    ~SkinDevice();
    SkinDevice(const SkinDevice&)=delete;SkinDevice& operator=(const SkinDevice&)=delete;
    // paletteHost必须保持有效到stream完成；externalOutput可指向E章导入的共享缓存。
    // 本函数只排队；读回和销毁前由调用者显式完成stream/跨API Fence依赖。
    void Record(const SkinMatrix* paletteHost,cudaStream_t stream,Vertex* externalOutput=nullptr);
};
void CheckCuda(cudaError_t,const char*);
}
