#include <cstdio>
#include <cuda_runtime.h>

#define CK(x) do{ cudaError_t e=(x); if(e){printf("err %s\n",cudaGetErrorString(e));return 1;} }while(0)

constexpr int BS   = 128;
constexpr int SIZE = 4096;      // 16KB 静态 shared

// 每轮 idx += 32：地址每轮都变（防寄存器缓存），但 bank = idx%32 保持不变。
// 一个 warp 里线程 t 的 bank = (t*stride)%32 → stride 决定“几路 bank 冲突”。
__global__ void bankKernel(float* out, int stride, int iters) {
    __shared__ float s[SIZE];
    int t = threadIdx.x;
    for (int k = t; k < SIZE; k += BS) s[k] = k * 0.5f;
    __syncthreads();

    int idx = (t * stride) % SIZE;
    float acc = 0.f;
    for (int i = 0; i < iters; ++i) {
        acc += s[idx];
        idx += 32; if (idx >= SIZE) idx -= SIZE;   // 同 bank、换地址
    }
    out[blockIdx.x * BS + t] = acc;
}

int main() {
    int grid = 2000, iters = 200000;
    float* d_out; CK(cudaMalloc(&d_out, (size_t)grid * BS * sizeof(float)));
    cudaEvent_t a, b; cudaEventCreate(&a); cudaEventCreate(&b);
    auto gcd = [](int x, int y){ while(y){int t=x%y;x=y;y=t;} return x; };

    printf("shared bank 冲突微基准 (BS=%d, grid=%d, iters=%d)\n", BS, grid, iters);
    printf("stride  冲突路数   耗时(ms)   相对stride=1\n");
    float base = 0;
    for (int stride : {1, 2, 3, 4, 8, 16, 32}) {
        bankKernel<<<grid, BS>>>(d_out, stride, 500);       // 热身
        CK(cudaDeviceSynchronize());
        cudaEventRecord(a);
        bankKernel<<<grid, BS>>>(d_out, stride, iters);
        cudaEventRecord(b); cudaEventSynchronize(b);
        float ms; cudaEventElapsedTime(&ms, a, b);
        if (stride == 1) base = ms;
        printf("%4d    %5d 路    %7.2f    %.2fx\n", stride, gcd(stride, 32), ms, ms / base);
    }
    cudaFree(d_out);
    return 0;
}
