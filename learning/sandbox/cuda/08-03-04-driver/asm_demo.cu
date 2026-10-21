#include <cuda_runtime.h>

// 一次乘加：期望编译成单条硬件 FMA 指令（SASS: FFMA）
__global__ void fma_kernel(const float* a, const float* b, const float* c, float* out, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) out[i] = a[i] * b[i] + c[i];
}

// 快速近似 sin：期望走特殊功能单元 SFU（SASS: MUFU.SIN）
__global__ void sin_kernel(const float* x, float* out, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) out[i] = __sinf(x[i]);
}
