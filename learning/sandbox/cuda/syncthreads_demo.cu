#include <cstdio>
#include <cuda_runtime.h>

constexpr int BS = 256;   // 每个 block 256 线程 = 8 个 warp

// 块内反转：out[i] = in[blockDim-1-i]，经由共享内存中转
// 关键：线程 i 要读的 shared[BS-1-i] 是由“另一个 warp 的线程”写的

__global__ void reverse_no_sync(const int* in, int* out) {
    __shared__ int s[BS];
    int t = threadIdx.x;
    int g = blockIdx.x * blockDim.x + t;
    s[t] = in[g];                       // 每个线程写自己那格
    // ！！缺少 __syncthreads()：别的 warp 可能还没写完 s[]
    out[g] = s[blockDim.x - 1 - t];     // 却去读“对端”那格 → 数据竞争
}

__global__ void reverse_sync(const int* in, int* out) {
    __shared__ int s[BS];
    int t = threadIdx.x;
    int g = blockIdx.x * blockDim.x + t;
    s[t] = in[g];
    __syncthreads();                    // 屏障：等 block 内所有线程都写完 s[]
    out[g] = s[blockDim.x - 1 - t];     // 现在读“对端”一定是写好的
}

int check(const int* out, const int* in, int n) {
    int wrong = 0;
    for (int b = 0; b < n; b += BS)
        for (int i = 0; i < BS; ++i)
            if (out[b+i] != in[b + BS-1-i]) wrong++;
    return wrong;
}

int main() {
    const int nblocks = 1000, n = nblocks * BS;
    int *h = (int*)malloc(n*sizeof(int));
    for (int i = 0; i < n; ++i) h[i] = i;
    int *d_in, *d_out; cudaMalloc(&d_in, n*sizeof(int)); cudaMalloc(&d_out, n*sizeof(int));
    cudaMemcpy(d_in, h, n*sizeof(int), cudaMemcpyHostToDevice);
    int* h_out = (int*)malloc(n*sizeof(int));

    reverse_no_sync<<<nblocks, BS>>>(d_in, d_out);
    cudaMemcpy(h_out, d_out, n*sizeof(int), cudaMemcpyDeviceToHost);
    printf("无 __syncthreads(): 错误元素 %d / %d\n", check(h_out, h, n), n);

    reverse_sync<<<nblocks, BS>>>(d_in, d_out);
    cudaMemcpy(h_out, d_out, n*sizeof(int), cudaMemcpyDeviceToHost);
    printf("有 __syncthreads(): 错误元素 %d / %d\n", check(h_out, h, n), n);

    cudaFree(d_in); cudaFree(d_out); free(h); free(h_out);
    return 0;
}
