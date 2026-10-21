#include <cstdio>
#include <cmath>
#include <cuda_runtime.h>

// ---------- ① intrinsic:精确 sinf vs 快速 __sinf ----------
__global__ void useSinf(const float* x, float* out, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x, s = blockDim.x * gridDim.x;
    for (; i < n; i += s) { float v = x[i], y = 0; for (int k = 0; k < 64; ++k) y += sinf(v + k); out[i] = y; }
}
__global__ void useFastSinf(const float* x, float* out, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x, s = blockDim.x * gridDim.x;
    for (; i < n; i += s) { float v = x[i], y = 0; for (int k = 0; k < 64; ++k) y += __sinf(v + k); out[i] = y; }
}

// ---------- ② ILP:单累加器(依赖链) vs 4 累加器(独立并行) ----------
__global__ void chain1(const float* x, float* out, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x, s = blockDim.x * gridDim.x;
    for (; i < n; i += s) {
        float v = x[i], y = 1.0f;
        for (int k = 0; k < 512; ++k) y = fmaf(y, 1.0009f, v);   // 每步依赖上一步
        out[i] = y;
    }
}
__global__ void chain4(const float* x, float* out, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x, s = blockDim.x * gridDim.x;
    for (; i < n; i += s) {
        float v = x[i], y0 = 1, y1 = 1.1f, y2 = 1.2f, y3 = 1.3f;
        for (int k = 0; k < 128; ++k) {           // 512/4，总 FMA 数相同
            y0 = fmaf(y0, 1.0009f, v); y1 = fmaf(y1, 1.0009f, v);
            y2 = fmaf(y2, 1.0009f, v); y3 = fmaf(y3, 1.0009f, v);   // 4 条独立链
        }
        out[i] = y0 + y1 + y2 + y3;
    }
}

int main() {
    const int n = 1 << 22;
    float *x, *o; cudaMalloc(&x, n*sizeof(float)); cudaMalloc(&o, n*sizeof(float));
    cudaMemset(x, 0, n*sizeof(float));
    int block = 256, grid = 512;
    cudaEvent_t a, b; cudaEventCreate(&a); cudaEventCreate(&b);
    auto t = [&](auto launch){ launch(); cudaDeviceSynchronize();
        cudaEventRecord(a); for(int r=0;r<30;++r) launch(); cudaEventRecord(b); cudaEventSynchronize(b);
        float ms; cudaEventElapsedTime(&ms,a,b); return ms/30; };

#ifdef __CUDA_ARCH__
#endif
    printf("编译模式: %s\n\n",
#ifdef __FAST_MATH__
        "-use_fast_math 开启"
#else
        "默认(精确)"
#endif
    );

    float ts = t([&]{ useSinf<<<grid,block>>>(x,o,n); });
    float tf = t([&]{ useFastSinf<<<grid,block>>>(x,o,n); });
    printf("① sinf (精确)   : %.3f ms  (基准)\n", ts);
    printf("  __sinf (快速)  : %.3f ms  (%.2fx 快)\n\n", tf, ts/tf);

    // 高并行:warp 多,延迟被 TLP 藏住
    float t1 = t([&]{ chain1<<<grid,block>>>(x,o,n); });
    float t4 = t([&]{ chain4<<<grid,block>>>(x,o,n); });
    printf("② ILP [高并行 grid=%d]:\n", grid);
    printf("   单累加器(依赖链) : %.3f ms  (基准)\n", t1);
    printf("   4累加器(ILP)     : %.3f ms  (%.2fx)\n\n", t4, t1/t4);

    // 线程饥饿:每 SM 就几个 warp,TLP 藏不住延迟,靠 ILP 才行
    int lowGrid = 48, lowBlock = 64;
    float l1 = t([&]{ chain1<<<lowGrid,lowBlock>>>(x,o,n); });
    float l4 = t([&]{ chain4<<<lowGrid,lowBlock>>>(x,o,n); });
    printf("② ILP [线程饥饿 grid=%d block=%d]:\n", lowGrid, lowBlock);
    printf("   单累加器(依赖链) : %.3f ms  (基准)\n", l1);
    printf("   4累加器(ILP)     : %.3f ms  (%.2fx 快)  <- ILP 在低并行时才显威\n", l4, l1/l4);

    cudaFree(x); cudaFree(o);
    return 0;
}
