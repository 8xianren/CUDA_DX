#include <cstdio>
#include <cuda_runtime.h>

// 故意算得久的核函数，制造可观测的 GPU 计算时间
__global__ void heavy(float* out, int n, int iters) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float x = (float)i;
    for (int k = 0; k < iters; ++k) x = x * 1.0000001f + 1.0f;
    out[i] = x;
}

#define CK(x) do{ cudaError_t e=(x); if(e){printf("CUDA err %s @%d: %s\n",#x,__LINE__,cudaGetErrorString(e));}}while(0)

int main() {
    const int n = 1 << 20, iters = 4000;
    const int chunks = 8;                 // 把工作切成 8 块流水线
    const int csz = n / chunks;
    const size_t cbytes = (size_t)csz * sizeof(float);

    float *d; CK(cudaMalloc(&d, n * sizeof(float)));

    // 关键：异步拷贝要求 host 端是“锁页内存(pinned)”，否则 cudaMemcpyAsync 退化成同步！
    float *h_pinned; CK(cudaMallocHost(&h_pinned, n * sizeof(float)));

    int block = 256;
    cudaEvent_t t0, t1; cudaEventCreate(&t0); cudaEventCreate(&t1);

    // ---------- 方案 A：单流（计算和拷贝串行） ----------
    cudaStream_t s; cudaStreamCreate(&s);
    cudaEventRecord(t0, s);
    for (int c = 0; c < chunks; ++c) {
        float* dseg = d + c * csz;
        heavy<<<(csz+block-1)/block, block, 0, s>>>(dseg, csz, iters);   // 算这一块
        CK(cudaMemcpyAsync(h_pinned + c*csz, dseg, cbytes, cudaMemcpyDeviceToHost, s)); // 再拷这一块
    }
    cudaEventRecord(t1, s);
    cudaEventSynchronize(t1);
    float ms_single = 0; cudaEventElapsedTime(&ms_single, t0, t1);
    cudaStreamDestroy(s);

    // ---------- 方案 B：双流（计算流 + 拷贝流，重叠） ----------
    cudaStream_t cs, ps; cudaStreamCreate(&cs); cudaStreamCreate(&ps);
    cudaEvent_t done[chunks];
    for (int c=0;c<chunks;++c) cudaEventCreate(&done[c]);

    cudaEventRecord(t0);
    for (int c = 0; c < chunks; ++c) {
        float* dseg = d + c * csz;
        heavy<<<(csz+block-1)/block, block, 0, cs>>>(dseg, csz, iters); // 计算流
        cudaEventRecord(done[c], cs);              // 标记“这块算完了”
        cudaStreamWaitEvent(ps, done[c], 0);       // 拷贝流等这块算完再拷（跨流依赖）
        CK(cudaMemcpyAsync(h_pinned + c*csz, dseg, cbytes, cudaMemcpyDeviceToHost, ps)); // 拷贝流
    }
    cudaEventRecord(t1);
    cudaEventSynchronize(t1);
    float ms_multi = 0; cudaEventElapsedTime(&ms_multi, t0, t1);

    printf("单流(串行)   : %.2f ms\n", ms_single);
    printf("双流(重叠)   : %.2f ms\n", ms_multi);
    printf("加速比       : %.2fx\n", ms_single / ms_multi);

    cudaFree(d); cudaFreeHost(h_pinned);
    return 0;
}
