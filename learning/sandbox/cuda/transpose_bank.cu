#include <cstdio>
#include <cuda_runtime.h>

#define CK(x) do{ cudaError_t e=(x); if(e){printf("err %s\n",cudaGetErrorString(e));return 1;} }while(0)

constexpr int TILE = 32;

// 版本 A:shared 无 padding —— global 两头都合并,但 shared 转置读有 bank conflict
__global__ void transposeConflict(float* out, const float* in, int w, int h) {
    __shared__ float tile[TILE][TILE];        // 32 列,列步长正好 = 32 bank -> 冲突
    int x = blockIdx.x * TILE + threadIdx.x;
    int y = blockIdx.y * TILE + threadIdx.y;
    if (x < w && y < h) tile[threadIdx.y][threadIdx.x] = in[y * w + x];  // 合并写入 shared
    __syncthreads();
    int tx = blockIdx.y * TILE + threadIdx.x;
    int ty = blockIdx.x * TILE + threadIdx.y;
    if (tx < h && ty < w)
        out[ty * h + tx] = tile[threadIdx.x][threadIdx.y];  // 转置读:同列 -> 撞同一 bank
}

// 版本 B:shared padding 到 33 列 —— 唯一区别!列步长变 33,与 32 bank 错开,消除冲突
__global__ void transposePadded(float* out, const float* in, int w, int h) {
    __shared__ float tile[TILE][TILE + 1];    // +1 是全部的秘密
    int x = blockIdx.x * TILE + threadIdx.x;
    int y = blockIdx.y * TILE + threadIdx.y;
    if (x < w && y < h) tile[threadIdx.y][threadIdx.x] = in[y * w + x];
    __syncthreads();
    int tx = blockIdx.y * TILE + threadIdx.x;
    int ty = blockIdx.x * TILE + threadIdx.y;
    if (tx < h && ty < w)
        out[ty * h + tx] = tile[threadIdx.x][threadIdx.y];
}

int main() {
    const int W = 8192, H = 8192;
    size_t bytes = (size_t)W * H * sizeof(float);
    float *d_in, *d_out;
    CK(cudaMalloc(&d_in, bytes)); CK(cudaMalloc(&d_out, bytes));
    CK(cudaMemset(d_in, 1, bytes));

    dim3 block(TILE, TILE), grid((W + TILE - 1) / TILE, (H + TILE - 1) / TILE);
    cudaEvent_t a, b; cudaEventCreate(&a); cudaEventCreate(&b);
    double GB = 2.0 * bytes / 1e9;   // 读+写

    auto bench = [&](const char* tag, auto launch) {
        launch(); CK(cudaDeviceSynchronize());
        cudaEventRecord(a);
        for (int r = 0; r < 20; ++r) launch();
        cudaEventRecord(b); cudaEventSynchronize(b);
        float ms; cudaEventElapsedTime(&ms, a, b); ms /= 20;
        printf("%-32s %7.3f ms   带宽 %6.1f GB/s\n", tag, ms, GB / (ms / 1e3));
    };

    bench("A shared 无padding (bank冲突)", [&]{ transposeConflict<<<grid, block>>>(d_out, d_in, W, H); });
    bench("B shared padding+1 (无冲突)  ", [&]{ transposePadded  <<<grid, block>>>(d_out, d_in, W, H); });

    cudaFree(d_in); cudaFree(d_out);
    return 0;
}
