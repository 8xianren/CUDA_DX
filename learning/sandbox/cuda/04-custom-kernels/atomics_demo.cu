#include <cstdio>
#include <cuda_runtime.h>

// ---- 实验 1：一个计数器被 N 个线程各 +1 ----

// 错误版：普通的“读-改-写”，多个线程会互相覆盖 → 丢计数
__global__ void count_racy(int* counter, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) {
        int old = *counter;   // 读
        *counter = old + 1;   // 改+写（非原子，中间可能被别的线程插入）
    }
}

// 正确版：atomicAdd 把“读-改-写”合成一个不可分割的操作
__global__ void count_atomic(int* counter, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) atomicAdd(counter, 1);
}

// ---- 实验 2：直方图（每个元素按值落入某个 bin，bin 计数 +1）----
__global__ void histogram(const float* data, int n, int* hist, int nbins, float bin_width) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    int bin = (int)(data[i] / bin_width);
    if (bin < 0) bin = 0; if (bin >= nbins) bin = nbins - 1;
    atomicAdd(&hist[bin], 1);      // 大量线程可能同时命中同一 bin → 必须原子
}

int main() {
    const int n = 1'000'000;
    int block = 256, grid = (n + block - 1) / block;

    // 实验 1
    int *d_cnt; cudaMalloc(&d_cnt, sizeof(int));
    int zero = 0, racy = 0, atom = 0;

    cudaMemcpy(d_cnt, &zero, sizeof(int), cudaMemcpyHostToDevice);
    count_racy<<<grid, block>>>(d_cnt, n);
    cudaMemcpy(&racy, d_cnt, sizeof(int), cudaMemcpyDeviceToHost);

    cudaMemcpy(d_cnt, &zero, sizeof(int), cudaMemcpyHostToDevice);
    count_atomic<<<grid, block>>>(d_cnt, n);
    cudaMemcpy(&atom, d_cnt, sizeof(int), cudaMemcpyDeviceToHost);

    printf("=== 实验1：%d 个线程各 +1 ===\n", n);
    printf("期望值           : %d\n", n);
    printf("错误版(非原子)   : %d   <- 丢了 %d 次计数！\n", racy, n - racy);
    printf("原子版(atomicAdd): %d   <- 完全正确\n\n", atom);

    // 实验 2：直方图
    const int nbins = 10; const float bin_width = 10.0f;
    float* h_data = (float*)malloc(n * sizeof(float));
    for (int i = 0; i < n; ++i) h_data[i] = (float)(i % 100);   // 值域 [0,100)
    float* d_data; cudaMalloc(&d_data, n * sizeof(float));
    cudaMemcpy(d_data, h_data, n * sizeof(float), cudaMemcpyHostToDevice);
    int* d_hist; cudaMalloc(&d_hist, nbins * sizeof(int));
    cudaMemset(d_hist, 0, nbins * sizeof(int));

    histogram<<<grid, block>>>(d_data, n, d_hist, nbins, bin_width);
    int h_hist[nbins]; cudaMemcpy(h_hist, d_hist, nbins * sizeof(int), cudaMemcpyDeviceToHost);

    printf("=== 实验2：直方图(原子版) ===\n");
    int total = 0;
    for (int b = 0; b < nbins; ++b) { printf("bin[%2d,%2d): %d\n", b*10, b*10+10, h_hist[b]); total += h_hist[b]; }
    printf("总计 %d（应等于 %d）\n", total, n);

    cudaFree(d_cnt); cudaFree(d_data); cudaFree(d_hist); free(h_data);
    return 0;
}
