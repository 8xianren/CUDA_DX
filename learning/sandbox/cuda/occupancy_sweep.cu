#include <cstdio>
#include <cuda_runtime.h>

// 轻寄存器 kernel
__global__ void light(float* a, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) a[i] = a[i] * 2.0f + 1.0f;
}
// 重寄存器 kernel
__global__ void heavyReg(float* a, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    float r[32];
    #pragma unroll
    for (int k = 0; k < 32; ++k) r[k] = a[(i + k) % n] * (k + 1);
    float s = 0;
    #pragma unroll
    for (int k = 0; k < 32; ++k) s += r[k] * r[(k * 7) % 32];
    if (i < n) a[i] = s;
}

void sweep(const char* name, const void* k) {
    int dev; cudaGetDevice(&dev);
    cudaDeviceProp p; cudaGetDeviceProperties(&p, dev);
    cudaFuncAttributes attr; cudaFuncGetAttributes(&attr, k);
    int maxWarps = p.maxThreadsPerMultiProcessor / p.warpSize;   // 48
    printf("\n=== %s (每线程 %d 寄存器) | SM上限:%d线程/%dwarp/%dblock/%d寄存器 ===\n",
           name, attr.numRegs, p.maxThreadsPerMultiProcessor, maxWarps,
           p.maxBlocksPerMultiProcessor, p.regsPerMultiprocessor);
    printf("block   驻留block/SM   活跃warp   occupancy\n");
    for (int block : {32, 64, 128, 256, 512, 768, 1024}) {
        int nb = 0;
        cudaOccupancyMaxActiveBlocksPerMultiprocessor(&nb, k, block, 0);
        int warps = nb * (block / p.warpSize);
        printf("%5d   %6d        %5d/%d     %.0f%%\n",
               block, nb, warps, maxWarps, 100.0 * warps / maxWarps);
    }
}

int main() {
    sweep("light", (const void*)light);
    sweep("heavyReg", (const void*)heavyReg);
    return 0;
}
