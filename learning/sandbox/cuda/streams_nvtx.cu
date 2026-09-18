#include <cstdio>
#include <cuda_runtime.h>
#include <nvtx3/nvToolsExt.h>   // NVTX：给时间轴打标签（随 CUDA Toolkit 自带）

// 简易 RAII 区间：构造打开始标记，析构打结束标记
struct NvtxRange {
    NvtxRange(const char* name) { nvtxRangePushA(name); }
    ~NvtxRange() { nvtxRangePop(); }
};

__global__ void heavy(float* out, int n, int iters) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float x = (float)i;
    for (int k = 0; k < iters; ++k) x = x * 1.0000001f + 1.0f;
    out[i] = x;
}

#define CK(x) do{ cudaError_t e=(x); if(e){printf("err %s: %s\n",#x,cudaGetErrorString(e));}}while(0)

int main() {
    const int n = 1 << 20, iters = 4000, chunks = 8;
    const int csz = n / chunks;
    const size_t cbytes = (size_t)csz * sizeof(float);
    float *d; CK(cudaMalloc(&d, n * sizeof(float)));
    float *h; CK(cudaMallocHost(&h, n * sizeof(float)));   // pinned
    int block = 256;

    cudaStream_t cs, ps; cudaStreamCreate(&cs); cudaStreamCreate(&ps);
    cudaEvent_t done[chunks];
    for (int c=0;c<chunks;++c) cudaEventCreate(&done[c]);

    {
        NvtxRange r("pipeline");                 // 整个流水线一条区间
        for (int c = 0; c < chunks; ++c) {
            float* dseg = d + c * csz;
            {
                NvtxRange rc("compute");         // 计算阶段
                heavy<<<(csz+block-1)/block, block, 0, cs>>>(dseg, csz, iters);
                cudaEventRecord(done[c], cs);
            }
            {
                NvtxRange rp("copy");            // 拷贝阶段
                cudaStreamWaitEvent(ps, done[c], 0);
                CK(cudaMemcpyAsync(h + c*csz, dseg, cbytes, cudaMemcpyDeviceToHost, ps));
            }
        }
    }
    cudaDeviceSynchronize();
    printf("done. h[0]=%.2f h[n-1]=%.2f\n", h[0], h[n-1]);

    cudaFree(d); cudaFreeHost(h);
    cudaStreamDestroy(cs); cudaStreamDestroy(ps);
    return 0;
}
