#include <cstdio>
#include <cuda_runtime.h>

// 演示三种内存的“作用域”：寄存器(每线程私有) / 共享内存(每block共享) / 全局内存(所有线程可见)
// 任务：把数组按“每个 block 管的那一段”就地翻转
__global__ void reverse_within_block(int* g_data) {  // g_data 在 global memory
    __shared__ int s[256];                            // shared：本 block 256 个线程共用

    int t   = threadIdx.x;                            // t 在 register：每个线程私有一份
    int idx = blockIdx.x * blockDim.x + t;            // idx 也在 register

    s[t] = g_data[idx];   // 1) 从 global 读入 shared
    __syncthreads();      // 2) 等本 block 所有线程都写完 shared（同步，4.3 详讲）

    // 3) 从 shared 里读“对称位置”，实现 block 内翻转
    g_data[idx] = s[blockDim.x - 1 - t];
}

int main() {
    const int block = 256, blocks = 2, n = block * blocks;  // 512 个元素
    int h[n];
    for (int i = 0; i < n; ++i) h[i] = i;   // 0,1,2,...,511

    int* d;
    cudaMalloc(&d, n * sizeof(int));
    cudaMemcpy(d, h, n * sizeof(int), cudaMemcpyHostToDevice);

    reverse_within_block<<<blocks, block>>>(d);

    cudaMemcpy(h, d, n * sizeof(int), cudaMemcpyDeviceToHost);
    // 每个 block 内部各自翻转：block0 段 [0,255] -> 255..0；block1 段 [256,511] -> 511..256
    printf("h[0]=%d  h[255]=%d  | h[256]=%d  h[511]=%d\n", h[0], h[255], h[256], h[511]);
    printf("(期望: 255 0 | 511 256  —— 翻转只发生在各自 block 内部)\n");

    cudaFree(d);
    return 0;
}
