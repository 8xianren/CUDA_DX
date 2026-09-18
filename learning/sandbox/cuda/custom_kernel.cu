#include <cstdio>
#include <cmath>
#include <cuda_runtime.h>

// 每个元素做点像样的计算，制造可测量的耗时
__device__ float work(int i) {
    float x = (float)i;
    for (int k = 0; k < 200; ++k) x = sqrtf(x * 1.0001f + 1.0f) + 0.5f;
    return x;
}

// 版本 A：单线程 —— 一个线程串行处理全部 n 个元素（错误示范）
__global__ void k_single(float* out, int n) {
    for (int id = 0; id < n; ++id) out[id] = work(id);
}

// 版本 B：单 block、256 线程 —— block 内用 threadIdx.x 分工，跨步循环
__global__ void k_block(float* out, int n) {
    int idx = threadIdx.x;
    int stride = blockDim.x;                     // = 256
    for (int id = idx; id < n; id += stride) out[id] = work(id);
}

// 版本 C：完整 grid —— 全局线程号 + grid-stride loop（标准写法）
__global__ void k_grid(float* out, int n) {
    int idx = blockDim.x * blockIdx.x + threadIdx.x;   // 全局唯一线程号
    int stride = blockDim.x * gridDim.x;               // 整个 grid 的线程总数
    for (int id = idx; id < n; id += stride) out[id] = work(id);
}

int ceil_div(int a, int b) { return (a + b - 1) / b; }

float time_ms(void(*launch)(float*,int), float* d, int n) {
    cudaEvent_t a, b; cudaEventCreate(&a); cudaEventCreate(&b);
    cudaEventRecord(a);
    launch(d, n);
    cudaEventRecord(b); cudaEventSynchronize(b);
    float ms=0; cudaEventElapsedTime(&ms, a, b);
    cudaEventDestroy(a); cudaEventDestroy(b);
    return ms;
}

void launch_single(float* d, int n){ k_single<<<1,1>>>(d, n); }
void launch_block (float* d, int n){ k_block<<<1,256>>>(d, n); }
void launch_grid  (float* d, int n){ int bs=256; k_grid<<<ceil_div(n,bs),bs>>>(d, n); }

int main() {
    const int n = 1 << 20;                 // 100 万个元素
    float* d; cudaMalloc(&d, n*sizeof(float));

    k_grid<<<ceil_div(n,256),256>>>(d,n); cudaDeviceSynchronize(); // 预热，排除 context 初始化

    float t_single = time_ms(launch_single, d, n);
    float t_block  = time_ms(launch_block,  d, n);
    float t_grid   = time_ms(launch_grid,   d, n);

    printf("A 单线程   <<<1,1>>>          : %8.2f ms  (基准)\n", t_single);
    printf("B 单block  <<<1,256>>>        : %8.2f ms  (%.1fx)\n", t_block, t_single/t_block);
    printf("C 全grid   <<<%d,256>>> : %8.2f ms  (%.1fx)\n",
           ceil_div(n,256), t_grid, t_single/t_grid);

    cudaFree(d);
    return 0;
}
