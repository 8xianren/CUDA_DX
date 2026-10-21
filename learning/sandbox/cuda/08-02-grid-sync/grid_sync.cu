#include <cstdio>
#include <cuda_runtime.h>
#include <cooperative_groups.h>
namespace cg = cooperative_groups;

// 一个 kernel 内完成全网格归约：
//   阶段1 每个 block 把自己那份加成 partials[blockIdx]
//   grid.sync()  <- 全网格屏障：等所有 block 的 partials 都写完
//   阶段2 由 0 号 block 把所有 partials 再加起来
__global__ void gridReduce(const float* in, int n, float* partials, float* result) {
    cg::grid_group grid = cg::this_grid();       // 代表“整个网格所有线程”这个组
    extern __shared__ float s[];
    int tid = threadIdx.x;
    int gid = blockIdx.x * blockDim.x + tid;
    int stride = gridDim.x * blockDim.x;

    // 阶段1：grid-stride 累加 -> block 内 shared 树归约 -> 写 partials
    float sum = 0.f;
    for (int i = gid; i < n; i += stride) sum += in[i];
    s[tid] = sum; __syncthreads();
    for (int off = blockDim.x / 2; off > 0; off >>= 1) {
        if (tid < off) s[tid] += s[tid + off];
        __syncthreads();
    }
    if (tid == 0) partials[blockIdx.x] = s[0];

    grid.sync();   // 关键：整个网格在此对齐，之后读 partials 一定是最新的

    // 阶段2：只让 0 号 block 汇总所有 block 的局部和
    if (blockIdx.x == 0) {
        float t = 0.f;
        for (int b = tid; b < gridDim.x; b += blockDim.x) t += partials[b];
        s[tid] = t; __syncthreads();
        for (int off = blockDim.x / 2; off > 0; off >>= 1) {
            if (tid < off) s[tid] += s[tid + off];
            __syncthreads();
        }
        if (tid == 0) *result = s[0];
    }
}

int main() {
    int dev; cudaGetDevice(&dev);
    cudaDeviceProp p; cudaGetDeviceProperties(&p, dev);
    printf("=== %s (sm_%d%d) ===\n", p.name, p.major, p.minor);
    if (!p.cooperativeLaunch) { printf("本设备不支持协作启动\n"); return 1; }

    const int N = 1 << 24;                        // 16777216 个 1.0f
    int block = 256;
    size_t shmem = block * sizeof(float);

    // 协作启动的铁律：所有 block 必须同时驻留（否则 grid.sync 会死锁）
    // 所以 grid 不能随便定，要按 occupancy 算“最多能同时驻留多少 block”
    int blocksPerSM = 0;
    cudaOccupancyMaxActiveBlocksPerMultiprocessor(&blocksPerSM, gridReduce, block, shmem);
    int grid = blocksPerSM * p.multiProcessorCount;
    printf("每SM可驻留 %d 个 block × %d 个 SM = grid %d 个 block（全部同时在跑）\n",
           blocksPerSM, p.multiProcessorCount, grid);

    float *d_in, *d_partials, *d_result;
    cudaMalloc(&d_in, N * sizeof(float));
    cudaMalloc(&d_partials, grid * sizeof(float));
    cudaMalloc(&d_result, sizeof(float));
    float* h = new float[N];
    for (int i = 0; i < N; ++i) h[i] = 1.0f;
    cudaMemcpy(d_in, h, N * sizeof(float), cudaMemcpyHostToDevice);

    // 必须用 cudaLaunchCooperativeKernel，不能用 <<<>>>
    void* args[] = { &d_in, (void*)&N, &d_partials, &d_result };
    cudaError_t e = cudaLaunchCooperativeKernel((void*)gridReduce, grid, block, args, shmem, 0);
    if (e) { printf("协作启动失败: %s\n", cudaGetErrorString(e)); return 1; }
    cudaDeviceSynchronize();

    float r; cudaMemcpy(&r, d_result, sizeof(float), cudaMemcpyDeviceToHost);
    printf("单kernel全网格归约 = %.0f  期望 = %d  %s\n", r, N, (r == (float)N ? "OK" : "FAIL"));

    delete[] h; cudaFree(d_in); cudaFree(d_partials); cudaFree(d_result);
    return 0;
}
