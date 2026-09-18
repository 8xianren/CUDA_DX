#include <cstdio>
#include <cuda_runtime.h>
#include <cub/block/block_reduce.cuh>

constexpr int BS = 256;

// ---- 方案 A：手写共享内存“树规约”求每个 block 的和，再原子加到全局 ----
__global__ void reduce_handwritten(const int* in, int n, int* out) {
    __shared__ int s[BS];
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    s[threadIdx.x] = (i < n) ? in[i] : 0;
    __syncthreads();
    // 树规约：每轮活跃线程减半，s[t] += s[t+步长]
    for (int stride = blockDim.x / 2; stride > 0; stride >>= 1) {
        if (threadIdx.x < stride) s[threadIdx.x] += s[threadIdx.x + stride];
        __syncthreads();
    }
    if (threadIdx.x == 0) atomicAdd(out, s[0]);   // block 的和归并到全局
}

// ---- 方案 B：用 cub::BlockReduce（一行完成 block 内规约，高度优化）----
__global__ void reduce_cub(const int* in, int n, int* out) {
    using BR = cub::BlockReduce<int, BS>;
    __shared__ typename BR::TempStorage storage;   // 协作算法需要的共享内存暂存
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    int val = (i < n) ? in[i] : 0;
    int block_sum = BR(storage).Sum(val);          // 整个 block 协作求和
    if (threadIdx.x == 0) atomicAdd(out, block_sum); // 只有 0 号线程拿到有效结果
}

int main() {
    const int n = 1 << 24;
    int* h = (int*)malloc(n*sizeof(int));
    long long expected = 0;
    for (int i = 0; i < n; ++i) { h[i] = i % 7; expected += h[i]; }
    int *d_in, *d_out; cudaMalloc(&d_in, n*sizeof(int)); cudaMalloc(&d_out, sizeof(int));
    cudaMemcpy(d_in, h, n*sizeof(int), cudaMemcpyHostToDevice);
    int grid = (n + BS - 1) / BS;

    int r_hand=0, r_cub=0;
    cudaMemset(d_out, 0, sizeof(int));
    reduce_handwritten<<<grid, BS>>>(d_in, n, d_out);
    cudaMemcpy(&r_hand, d_out, sizeof(int), cudaMemcpyDeviceToHost);

    cudaMemset(d_out, 0, sizeof(int));
    reduce_cub<<<grid, BS>>>(d_in, n, d_out);
    cudaMemcpy(&r_cub, d_out, sizeof(int), cudaMemcpyDeviceToHost);

    printf("CPU 期望和      : %lld\n", expected);
    printf("A 手写树规约    : %d %s\n", r_hand, (r_hand==(int)expected)?"OK":"WRONG");
    printf("B cub::BlockReduce: %d %s\n", r_cub, (r_cub==(int)expected)?"OK":"WRONG");

    cudaFree(d_in); cudaFree(d_out); free(h);
    return 0;
}
