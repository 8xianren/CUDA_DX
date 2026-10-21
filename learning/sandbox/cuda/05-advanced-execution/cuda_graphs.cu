#include <cstdio>
#include <cuda_runtime.h>

// 一个“很小、很快”的 kernel —— 计算量小到 CPU 的“启动开销”成为瓶颈
__global__ void tiny(float* a, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) a[i] = a[i] * 1.0001f + 1.0f;
}

constexpr int KERNELS_PER_ITER = 50;   // 每轮连发 50 个小 kernel
constexpr int ITERS = 1000;            // 重复 1000 轮

int main() {
    const int n = 1024;                // 故意很小，突出启动开销
    float* d; cudaMalloc(&d, n*sizeof(float));
    int block = 256, grid = (n+block-1)/block;
    cudaStream_t s; cudaStreamCreate(&s);

    cudaEvent_t a,b; cudaEventCreate(&a); cudaEventCreate(&b);

    // ---------- 方案 A：每轮都逐个 launch（传统方式）----------
    cudaEventRecord(a, s);
    for (int it = 0; it < ITERS; ++it)
        for (int k = 0; k < KERNELS_PER_ITER; ++k)
            tiny<<<grid, block, 0, s>>>(d, n);   // 每次都付一份 CPU 启动开销
    cudaEventRecord(b, s); cudaEventSynchronize(b);
    float ms_direct=0; cudaEventElapsedTime(&ms_direct, a, b);

    // ---------- 方案 B：捕获一次成图，之后重放（CUDA Graph）----------
    cudaGraph_t graph; cudaGraphExec_t exec;

    // 捕获：把“一轮 50 个 kernel”的调用序列录制成一张图（不真正执行）
    cudaStreamBeginCapture(s, cudaStreamCaptureModeGlobal);
    for (int k = 0; k < KERNELS_PER_ITER; ++k)
        tiny<<<grid, block, 0, s>>>(d, n);
    cudaStreamEndCapture(s, &graph);
    cudaGraphInstantiate(&exec, graph, nullptr, nullptr, 0); // 把图“编译”成可执行实例

    cudaEventRecord(a, s);
    for (int it = 0; it < ITERS; ++it)
        cudaGraphLaunch(exec, s);   // 整轮 50 个 kernel 一次性重放，几乎无 CPU 开销
    cudaEventRecord(b, s); cudaEventSynchronize(b);
    float ms_graph=0; cudaEventElapsedTime(&ms_graph, a, b);

    printf("每轮 %d 个小 kernel × %d 轮 = %d 次 launch\n",
           KERNELS_PER_ITER, ITERS, KERNELS_PER_ITER*ITERS);
    printf("A 传统逐个 launch : %7.2f ms\n", ms_direct);
    printf("B CUDA Graph 重放 : %7.2f ms  (%.2fx 更快)\n", ms_graph, ms_direct/ms_graph);

    cudaGraphExecDestroy(exec); cudaGraphDestroy(graph);
    cudaFree(d); cudaStreamDestroy(s);
    return 0;
}
