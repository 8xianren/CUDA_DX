#include <cstdio>
#include <cuda_runtime.h>

#define CK(x) do{ cudaError_t e=(x); if(e){printf("CUDA err %s:%d %s\n",__FILE__,__LINE__,cudaGetErrorString(e));return 1;} }while(0)

// 每个线程搬运 1 个元素:out[base + t*stride] = in[base + t*stride]
// 相邻线程(t, t+1)的地址相差 stride 个 float。stride=1 => 完美合并。
__global__ void copyStrided(float* out, const float* in, int m, int stride) {
    int t = blockIdx.x * blockDim.x + threadIdx.x;
    if (t < m) {
        long idx = (long)t * stride;
        out[idx] = in[idx];
    }
}

// 错位:整体平移 offset 个 float,破坏 128B 对齐(warp 起点不落在 sector 边界)
__global__ void copyOffset(float* out, const float* in, int m, int offset) {
    int t = blockIdx.x * blockDim.x + threadIdx.x;
    if (t < m) {
        int idx = t + offset;
        out[idx] = in[idx];
    }
}

int main() {
    const int M = 1 << 24;                 // 每次都搬运这么多“有用”元素(1600万)
    const long BIG = (long)M * 32 + 64;    // 足够 stride=32 使用
    float *d_in, *d_out;
    CK(cudaMalloc(&d_in,  BIG * sizeof(float)));
    CK(cudaMalloc(&d_out, BIG * sizeof(float)));
    CK(cudaMemset(d_in, 1, BIG * sizeof(float)));

    int block = 256, grid = (M + block - 1) / block;
    cudaEvent_t a, b; cudaEventCreate(&a); cudaEventCreate(&b);
    const double useful_GB = 2.0 * M * sizeof(float) / 1e9;  // 读+写 有用字节

    auto bench = [&](const char* tag, auto launch) {
        launch();                           // 热身
        CK(cudaDeviceSynchronize());
        cudaEventRecord(a);
        for (int r = 0; r < 20; ++r) launch();
        cudaEventRecord(b); cudaEventSynchronize(b);
        float ms; cudaEventElapsedTime(&ms, a, b); ms /= 20;
        printf("%-28s %7.3f ms   有效带宽 %6.1f GB/s\n", tag, ms, useful_GB / (ms / 1e3));
    };

    printf("=== 变 stride(相邻线程地址间隔)===\n");
    for (int s : {1, 2, 4, 8, 16, 32}) {
        char tag[64]; snprintf(tag, 64, "stride=%d", s);
        bench(tag, [&]{ copyStrided<<<grid, block>>>(d_out, d_in, M, s); });
    }

    printf("\n=== 变 offset(整体错位,破坏对齐)===\n");
    for (int o : {0, 1, 2, 8, 16}) {
        char tag[64]; snprintf(tag, 64, "offset=%d", o);
        bench(tag, [&]{ copyOffset<<<grid, block>>>(d_out, d_in, M, o); });
    }

    cudaFree(d_in); cudaFree(d_out);
    return 0;
}
