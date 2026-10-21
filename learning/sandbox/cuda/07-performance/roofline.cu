#include <cstdio>
#include <cuda_runtime.h>

#define CK(x) do{ cudaError_t e=(x); if(e){printf("err %s\n",cudaGetErrorString(e));return 1;} }while(0)

// 纯拷贝:测“实际可达带宽”(roofline 的水平屋顶)
__global__ void copyk(const float* in, float* out, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    int stride = blockDim.x * gridDim.x;
    for (; i < n; i += stride) out[i] = in[i];
}

// 可调算术强度:读1个float + 写1个float(共8字节),中间做 K 次 FMA(=2K flops)
// 算术强度 AI = 2K / 8 = K/4  (flop/byte)
__global__ void aik(float* a, int n, int K) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    int stride = blockDim.x * gridDim.x;
    for (; i < n; i += stride) {
        float x = a[i], y = 0.5f;
        for (int k = 0; k < K; ++k) y = fmaf(y, 1.0009f, x);   // 1 FMA = 2 flops
        a[i] = y;
    }
}

int main() {
    int dev; cudaGetDevice(&dev); cudaDeviceProp p; cudaGetDeviceProperties(&p, dev);
    int memClkKHz = 0; cudaDeviceGetAttribute(&memClkKHz, cudaDevAttrMemoryClockRate, dev);
    double peakBW = 2.0 * memClkKHz * 1e3 * (p.memoryBusWidth / 8) / 1e9; // DDR*2 粗略
    printf("=== %s: %d SM, bus %d-bit, 理论带宽(粗略DDRx2) ~%.0f GB/s ===\n",
           p.name, p.multiProcessorCount, p.memoryBusWidth, peakBW);

    const int n = 1 << 25;                 // 3355万元素
    float *a, *b; CK(cudaMalloc(&a, n * sizeof(float))); CK(cudaMalloc(&b, n * sizeof(float)));
    CK(cudaMemset(a, 0, n * sizeof(float)));
    int block = 256, grid = 1024;
    cudaEvent_t e0, e1; cudaEventCreate(&e0); cudaEventCreate(&e1);

    auto timeit = [&](auto launch)->float{
        launch(); CK(cudaDeviceSynchronize());
        cudaEventRecord(e0);
        for (int r = 0; r < 20; ++r) launch();
        cudaEventRecord(e1); cudaEventSynchronize(e1);
        float ms; cudaEventElapsedTime(&ms, e0, e1); return ms / 20;
    };

    // 实际带宽上限(拷贝:读+写=8字节/元素)
    float msc = timeit([&]{ copyk<<<grid, block>>>(a, b, n); });
    double copyBW = 8.0 * n / (msc / 1e3) / 1e9;
    printf("纯拷贝实测带宽 = %.0f GB/s  (这就是内存屋顶)\n\n", copyBW);

    // 先测算力峰值(高 K 的坪值)
    float msPeak = timeit([&]{ aik<<<grid, block>>>(a, n, 512); });
    double peakFlops = 2.0 * 512 * n / (msPeak / 1e3) / 1e9;
    printf("高算术强度坪值(算力屋顶) ~%.0f GFLOP/s\n\n", peakFlops);

    printf(" K    AI(flop/byte)   GFLOP/s    GB/s      判定\n");
    for (int K : {1, 2, 4, 8, 16, 32, 64, 128, 256, 512}) {
        float ms = timeit([&]{ aik<<<grid, block>>>(a, n, K); });
        double flops = 2.0 * K * n / (ms / 1e3) / 1e9;
        double gbs   = 8.0 * n / (ms / 1e3) / 1e9;
        double ai    = K / 4.0;
        const char* verdict = (gbs > 0.8 * copyBW) ? "memory-bound (bandwidth wall)"
                            : (flops > 0.8 * peakFlops) ? "compute-bound (flops wall)"
                            : "transition";
        printf("%4d   %8.1f      %8.0f  %7.0f   %s\n", K, ai, flops, gbs, verdict);
    }
    cudaFree(a); cudaFree(b);
    return 0;
}
