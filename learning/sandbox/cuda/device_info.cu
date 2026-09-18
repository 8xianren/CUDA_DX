#include <cstdio>
#include <cuda_runtime.h>

int main() {
    int dev = 0;
    cudaDeviceProp p;
    cudaGetDeviceProperties(&p, dev);

    printf("==== GPU 硬件参数 ====\n");
    printf("名称                 : %s\n", p.name);
    printf("计算能力(架构)        : sm_%d%d\n", p.major, p.minor);
    printf("SM 数量(多处理器)     : %d\n", p.multiProcessorCount);
    printf("warp 大小            : %d 线程\n", p.warpSize);
    printf("每 block 最大线程数    : %d\n", p.maxThreadsPerBlock);
    printf("每 SM 最大线程数       : %d\n", p.maxThreadsPerMultiProcessor);
    printf("每 SM 最大常驻 block   : %d\n", p.maxBlocksPerMultiProcessor);
    printf("每 block 共享内存(KB) : %.0f\n", p.sharedMemPerBlock / 1024.0);
    printf("每 SM 32位寄存器数     : %d\n", p.regsPerMultiprocessor);
    printf("全局显存(GB)          : %.1f\n", p.totalGlobalMem / 1e9);

    int maxThreadsAllSM = p.multiProcessorCount * p.maxThreadsPerMultiProcessor;
    printf("\n理论可同时驻留线程    : %d 个 (= %d SM x %d)\n",
           maxThreadsAllSM, p.multiProcessorCount, p.maxThreadsPerMultiProcessor);
    printf("折合 warp 数          : %d 束\n", maxThreadsAllSM / p.warpSize);
    return 0;
}
