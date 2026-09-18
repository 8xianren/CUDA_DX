#include <cstdio>
#include <cuda_runtime.h>

#define CK(x) do{ cudaError_t e=(x); if(e){printf("err %s\n",cudaGetErrorString(e));return 1;} }while(0)

// 轻量 kernel:很少寄存器、无 shared
__global__ void light(float* a, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) a[i] = a[i] * 2.0f + 1.0f;
}

// 重寄存器 kernel:故意用很多局部变量撑高寄存器占用
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

// 动态 shared kernel:shared 用量运行时给定
__global__ void heavyShared(float* a, int n) {
    extern __shared__ float s[];
    int t = threadIdx.x;
    s[t] = a[(blockIdx.x * blockDim.x + t) % n];
    __syncthreads();
    if (blockIdx.x * blockDim.x + t < n) a[blockIdx.x * blockDim.x + t] = s[t];
}

void report(const char* name, const void* k, int block, size_t shmem) {
    int maxBlocks = 0;
    cudaOccupancyMaxActiveBlocksPerMultiprocessor(&maxBlocks, k, block, shmem);
    cudaFuncAttributes attr; cudaFuncGetAttributes(&attr, k);
    int dev; cudaGetDevice(&dev);
    cudaDeviceProp p; cudaGetDeviceProperties(&p, dev);
    int warpsPerBlock = (block + p.warpSize - 1) / p.warpSize;
    int activeWarps = maxBlocks * warpsPerBlock;
    int maxWarps = p.maxThreadsPerMultiProcessor / p.warpSize;
    printf("%-14s 每线程寄存器=%3d  静态shared=%zuB  block=%d\n", name, attr.numRegs, attr.sharedSizeBytes, block);
    printf("   -> 每SM可驻留 %d 个block, %d/%d warps, occupancy = %.0f%%\n\n",
           maxBlocks, activeWarps, maxWarps, 100.0 * activeWarps / maxWarps);
}

int main() {
    int dev; cudaGetDevice(&dev);
    cudaDeviceProp p; cudaGetDeviceProperties(&p, dev);
    printf("=== %s (sm_%d%d) ===\n", p.name, p.major, p.minor);
    printf("SM 数量: %d\n", p.multiProcessorCount);
    printf("每SM: 最多 %d 线程 / %d warp / %d 个block\n",
           p.maxThreadsPerMultiProcessor, p.maxThreadsPerMultiProcessor / p.warpSize, p.maxBlocksPerMultiProcessor);
    printf("每SM: 寄存器 %d 个 / shared %zu KB\n", p.regsPerMultiprocessor, p.sharedMemPerMultiprocessor / 1024);
    printf("每block上限: 寄存器 %d / shared %zu KB\n\n", p.regsPerBlock, p.sharedMemPerBlock / 1024);

    report("light",       (const void*)light,       256, 0);
    report("heavyReg",    (const void*)heavyReg,     256, 0);
    report("heavyShared", (const void*)heavyShared,  256, 256 * 48 * sizeof(float)); // 48KB/block

    // 用 API 让 CUDA 自动挑“occupancy 最优”的 block 大小
    int minGrid, bestBlock;
    cudaOccupancyMaxPotentialBlockSize(&minGrid, &bestBlock, light, 0, 0);
    printf("CUDA 建议 light 的最优 block 大小 = %d\n", bestBlock);
    return 0;
}
