#include <cstdio>
#include <cuda_runtime.h>

#define CK(x) do{ cudaError_t e=(x); if(e){printf("err %s\n",cudaGetErrorString(e));return 1;} }while(0)

constexpr int COEFS = 64;      // 一小组系数,所有线程都要读(广播场景)
__constant__ float c_coef[COEFS];

// 多项式求值:acc = sum_k coef[k] * x^k。关键:每一步 k,warp 内 32 线程读的是“同一个” coef[k]
__global__ void polyGlobal(float* out, const float* x, const float* coef, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float xi = x[i], acc = 0.f, p = 1.f;
    for (int k = 0; k < COEFS; ++k) { acc += coef[k] * p; p *= xi; }
    out[i] = acc;
}

__global__ void polyLdg(float* out, const float* x, const float* __restrict__ coef, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float xi = x[i], acc = 0.f, p = 1.f;
    for (int k = 0; k < COEFS; ++k) { acc += __ldg(&coef[k]) * p; p *= xi; }  // 强制走只读缓存
    out[i] = acc;
}

__global__ void polyConst(float* out, const float* x, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float xi = x[i], acc = 0.f, p = 1.f;
    for (int k = 0; k < COEFS; ++k) { acc += c_coef[k] * p; p *= xi; }  // 常量内存:广播 1 次命中
    out[i] = acc;
}

int main() {
    const int N = 1 << 24;
    float *d_x, *d_out, *d_coef;
    CK(cudaMalloc(&d_x, N * sizeof(float)));
    CK(cudaMalloc(&d_out, N * sizeof(float)));
    CK(cudaMalloc(&d_coef, COEFS * sizeof(float)));
    CK(cudaMemset(d_x, 0, N * sizeof(float)));

    float h_coef[COEFS];
    for (int k = 0; k < COEFS; ++k) h_coef[k] = 0.001f * k;
    CK(cudaMemcpy(d_coef, h_coef, sizeof(h_coef), cudaMemcpyHostToDevice));
    CK(cudaMemcpyToSymbol(c_coef, h_coef, sizeof(h_coef)));   // 拷进常量内存的专用 API

    int block = 256, grid = (N + block - 1) / block;
    cudaEvent_t a, b; cudaEventCreate(&a); cudaEventCreate(&b);
    auto bench = [&](const char* tag, auto launch) {
        launch(); CK(cudaDeviceSynchronize());
        cudaEventRecord(a);
        for (int r = 0; r < 30; ++r) launch();
        cudaEventRecord(b); cudaEventSynchronize(b);
        float ms; cudaEventElapsedTime(&ms, a, b); ms /= 30;
        printf("%-34s %7.3f ms\n", tag, ms);
    };

    bench("A 系数在 global memory",  [&]{ polyGlobal<<<grid, block>>>(d_out, d_x, d_coef, N); });
    bench("B 系数走只读缓存 __ldg", [&]{ polyLdg   <<<grid, block>>>(d_out, d_x, d_coef, N); });
    bench("C 系数在 constant memory",[&]{ polyConst <<<grid, block>>>(d_out, d_x, N); });

    cudaFree(d_x); cudaFree(d_out); cudaFree(d_coef);
    return 0;
}
