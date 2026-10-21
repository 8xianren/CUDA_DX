#include <cstdio>
#include <cuda_runtime.h>

constexpr int NBINS = 256;
constexpr int BS    = 256;

// 方案 A：直接对“全局”直方图做原子加。百万线程抢 256 个全局地址。
__global__ void hist_global(const unsigned char* data, int n, int* hist) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    int stride = blockDim.x * gridDim.x;
    for (; i < n; i += stride)
        atomicAdd(&hist[data[i]], 1);          // 全局原子（慢）
}

// 方案 B：每个 block 在“共享内存”里建私有直方图，最后一次性归并到全局。
__global__ void hist_shared(const unsigned char* data, int n, int* hist) {
    __shared__ int s_hist[NBINS];              // 片上、与 L1 同驻，极快

    // 1) 清零私有直方图（256 个 bin 由 256 个线程分工清）
    for (int b = threadIdx.x; b < NBINS; b += blockDim.x) s_hist[b] = 0;
    __syncthreads();                           // 等清零完成再累加

    // 2) 累加到共享内存私有直方图（block 内竞争，范围小得多）
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    int stride = blockDim.x * gridDim.x;
    for (; i < n; i += stride)
        atomicAdd(&s_hist[data[i]], 1);        // 共享内存原子（block 作用域，快）
    __syncthreads();                           // 等所有线程累加完再归并

    // 3) 把私有直方图归并进全局（每个 block 只碰全局 256 次）
    for (int b = threadIdx.x; b < NBINS; b += blockDim.x)
        atomicAdd(&hist[b], s_hist[b]);
}

float timeit(void(*run)(), int reps=10) {
    cudaEvent_t a,b; cudaEventCreate(&a); cudaEventCreate(&b);
    run(); cudaDeviceSynchronize();
    cudaEventRecord(a);
    for (int r=0;r<reps;++r) run();
    cudaEventRecord(b); cudaEventSynchronize(b);
    float ms=0; cudaEventElapsedTime(&ms,a,b);
    return ms/reps;
}

static int N, grid; static unsigned char* d_data; static int* d_hist;
void run_global(){ cudaMemset(d_hist,0,NBINS*sizeof(int)); hist_global<<<grid,BS>>>(d_data,N,d_hist); }
void run_shared(){ cudaMemset(d_hist,0,NBINS*sizeof(int)); hist_shared<<<grid,BS>>>(d_data,N,d_hist); }

int main() {
    N = 1<<24;                                 // 1600 万个字节
    grid = 256;                                // 固定 grid，用 grid-stride 覆盖
    unsigned char* h = (unsigned char*)malloc(N);
    for (int i=0;i<N;++i) h[i] = (unsigned char)(i * 131 % NBINS); // 分布较均匀
    cudaMalloc(&d_data, N); cudaMemcpy(d_data,h,N,cudaMemcpyHostToDevice);
    cudaMalloc(&d_hist, NBINS*sizeof(int));

    float tg = timeit(run_global);
    float ts = timeit(run_shared);

    // 校验两者结果一致
    int hist_g[NBINS], hist_s[NBINS];
    run_global(); cudaMemcpy(hist_g,d_hist,NBINS*sizeof(int),cudaMemcpyDeviceToHost);
    run_shared(); cudaMemcpy(hist_s,d_hist,NBINS*sizeof(int),cudaMemcpyDeviceToHost);
    int mism=0, total=0; for(int b=0;b<NBINS;++b){ if(hist_g[b]!=hist_s[b])mism++; total+=hist_s[b]; }

    printf("%d 个元素, %d 个 bin:\n", N, NBINS);
    printf("A 全局原子直方图     : %6.3f ms\n", tg);
    printf("B 共享内存私有直方图 : %6.3f ms  (%.2fx 更快)\n", ts, tg/ts);
    printf("两方案结果不一致的 bin: %d，总计数 %d（应=%d）\n", mism, total, N);

    cudaFree(d_data); cudaFree(d_hist); free(h);
    return 0;
}
