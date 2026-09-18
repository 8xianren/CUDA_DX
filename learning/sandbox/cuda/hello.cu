#include <cstdio>

// __global__ 表示这是一个在 GPU 上执行、由 CPU 调用的核函数(kernel)
__global__ void hello_from_gpu() {
    // 每个线程都会执行这段代码，打印自己的编号
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    printf("Hello from GPU thread %d (block %d, thread %d)\n",
           tid, blockIdx.x, threadIdx.x);
}

int main() {
    printf("Hello from CPU (host)\n");

    // <<<2, 4>>> 启动 2 个 block，每个 block 4 个线程，共 8 个线程
    hello_from_gpu<<<2, 4>>>();

    // 核函数是异步的：等 GPU 全部执行完再退出
    cudaDeviceSynchronize();
    return 0;
}
