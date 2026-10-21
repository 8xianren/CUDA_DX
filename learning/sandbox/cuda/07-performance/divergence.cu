#include <cstdio>
#include <cuda_runtime.h>

#define CK(x) do{ cudaError_t e=(x); if(e){printf("err %s\n",cudaGetErrorString(e));return 1;} }while(0)

// 两条“重”路径,故意用不同函数,编译器无法合并
__device__ float pathA(float x){ float y=0; for(int k=0;k<128;++k) y+=sinf(x+k); return y; }
__device__ float pathB(float x){ float y=0; for(int k=0;k<128;++k) y+=cosf(x+k); return y; }

// mode=0: 按 lane 奇偶分支 → 同一个 warp 里相邻线程走不同路 → warp 内发散
// mode=1: 按 warp 号分支 → 整个 warp(32线程)走同一条路 → 不发散
// 两者做 A/B 的总比例相同(各一半),唯一区别是发散发生在 warp 内还是 warp 间。
__global__ void k(float* out, int n, int mode) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float x = i * 1e-4f;
    bool cond = (mode == 0) ? ((threadIdx.x & 1) == 0)         // lane 奇偶:warp 内裂开
                            : (((threadIdx.x >> 5) & 1) == 0);  // warp 号:整 warp 一致
    float y = cond ? pathA(x) : pathB(x);
    out[i] = y;
}

int main() {
    const int n = 1 << 22;
    float* d; CK(cudaMalloc(&d, n * sizeof(float)));
    int block = 256, grid = (n + block - 1) / block;
    cudaEvent_t a, b; cudaEventCreate(&a); cudaEventCreate(&b);
    auto timeit = [&](int mode){
        k<<<grid, block>>>(d, n, mode); cudaDeviceSynchronize();
        cudaEventRecord(a);
        for (int r = 0; r < 30; ++r) k<<<grid, block>>>(d, n, mode);
        cudaEventRecord(b); cudaEventSynchronize(b);
        float ms; cudaEventElapsedTime(&ms, a, b); return ms / 30;
    };
    float t_div = timeit(0);
    float t_uni = timeit(1);
    printf("warp 内发散 (lane 奇偶分支) : %.3f ms  (基准)\n", t_div);
    printf("warp 间一致 (整warp同路径)  : %.3f ms  (%.2fx 快)\n", t_uni, t_div / t_uni);
    printf("\n总工作量完全相同,唯一差别:发散在 warp 内(串行执行两条路)vs warp 间(各跑各的)\n");
    cudaFree(d);
    return 0;
}
