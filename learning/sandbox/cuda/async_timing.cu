#include <cstdio>
#include <chrono>
#include <cuda_runtime.h>

// 一个故意“算得久”的核函数：每个线程做大量浮点运算
__global__ void heavy(float* out, int n, int iters) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float x = (float)i;
    for (int k = 0; k < iters; ++k) x = x * 1.0000001f + 1.0f;   // 拖时间
    out[i] = x;
}

using clk = std::chrono::high_resolution_clock;
double ms(clk::time_point a, clk::time_point b) {
    return std::chrono::duration<double, std::milli>(b - a).count();
}

int main() {
    const int n = 1 << 20, iters = 20000;
    float* d; cudaMalloc(&d, n * sizeof(float));
    int block = 256, grid = (n + block - 1) / block;

    // ---- 计时方式 A：启动后立刻停表（不同步）----
    auto a0 = clk::now();
    heavy<<<grid, block>>>(d, n, iters);
    auto a1 = clk::now();   // CPU 此刻只是“发射完”，GPU 还在算
    printf("A. 不同步计时: %.2f ms  <- 这是“发射命令”的耗时，不是真正算完\n", ms(a0, a1));

    // ---- 计时方式 B：启动后等 GPU 真正算完再停表 ----
    auto b0 = clk::now();
    heavy<<<grid, block>>>(d, n, iters);
    cudaDeviceSynchronize();            // 等 GPU 干完
    auto b1 = clk::now();
    printf("B. 同步后计时: %.2f ms  <- 这才是 GPU 真正的计算耗时\n", ms(b0, b1));

    // ---- 演示 overlap：发射 GPU 后，CPU 趁机干自己的活 ----
    auto c0 = clk::now();
    heavy<<<grid, block>>>(d, n, iters);   // 异步发射，CPU 不等
    double cpu_work = 0;                    // CPU 同时做点别的事（模拟写盘/预处理）
    for (int i = 0; i < 5'000'000; ++i) cpu_work += i * 1e-9;
    cudaDeviceSynchronize();                // 最后再汇合
    auto c1 = clk::now();
    printf("C. 计算与CPU工作重叠: %.2f ms (cpu_work=%.1f) <- GPU算的同时CPU没闲着\n",
           ms(c0, c1), cpu_work);

    cudaFree(d);
    return 0;
}
