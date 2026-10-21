#include <cstdio>
#include <cuda_runtime.h>
#include <cuda/std/atomic>

// 所有线程都砸向同一个全局地址：atomicAdd（最坏竞争）
__global__ void hot_atomicAdd(int* g, int n) {
    int i = blockIdx.x*blockDim.x + threadIdx.x;
    if (i < n) atomicAdd(g, 1);
}

// 同样砸向一个地址，但用 cuda::std::atomic_ref（对比 API 差异）
__global__ void hot_atomic_ref(int* g, int n) {
    int i = blockIdx.x*blockDim.x + threadIdx.x;
    if (i < n) { cuda::std::atomic_ref<int> r(*g); r.fetch_add(1); }
}

// 同地址，但显式用 relaxed 内存序（去掉默认 seq_cst 的栅栏）
__global__ void hot_ref_relaxed(int* g, int n) {
    int i = blockIdx.x*blockDim.x + threadIdx.x;
    if (i < n) { cuda::std::atomic_ref<int> r(*g); r.fetch_add(1, cuda::std::memory_order_relaxed); }
}

// 分散到 4096 个地址：竞争大幅降低
__global__ void spread_atomic(int* arr, int n, int slots) {
    int i = blockIdx.x*blockDim.x + threadIdx.x;
    if (i < n) atomicAdd(&arr[i % slots], 1);
}

// 优化范式：block 内先用共享内存(block作用域原子)累加，每个 block 只对全局原子加 1 次
__global__ void block_shared(int* g, int n) {
    __shared__ int local;
    if (threadIdx.x == 0) local = 0;
    __syncthreads();
    int i = blockIdx.x*blockDim.x + threadIdx.x;
    if (i < n) atomicAdd(&local, 1);        // 共享内存上的原子 = block 作用域，快
    __syncthreads();
    if (threadIdx.x == 0) atomicAdd(g, local); // 每个 block 只碰全局一次
}

float timeit(void(*fn)(), int reps=1) {
    cudaEvent_t a,b; cudaEventCreate(&a); cudaEventCreate(&b);
    fn(); cudaDeviceSynchronize();            // 预热
    cudaEventRecord(a);
    for (int r=0;r<reps;++r) fn();
    cudaEventRecord(b); cudaEventSynchronize(b);
    float ms=0; cudaEventElapsedTime(&ms,a,b);
    cudaEventDestroy(a); cudaEventDestroy(b);
    return ms/reps;
}

static int N, block, grid, slots;
static int *g, *arr;

void run_hot()    { cudaMemset(g,0,sizeof(int));               hot_atomicAdd<<<grid,block>>>(g,N); }
void run_ref()    { cudaMemset(g,0,sizeof(int));               hot_atomic_ref<<<grid,block>>>(g,N); }
void run_relaxed(){ cudaMemset(g,0,sizeof(int));               hot_ref_relaxed<<<grid,block>>>(g,N); }
void run_spread() { cudaMemset(arr,0,slots*sizeof(int));       spread_atomic<<<grid,block>>>(arr,N,slots); }
void run_block()  { cudaMemset(g,0,sizeof(int));               block_shared<<<grid,block>>>(g,N); }

int main() {
    N = 1<<22; block=256; grid=(N+block-1)/block; slots=4096;
    cudaMalloc(&g,sizeof(int));
    cudaMalloc(&arr,slots*sizeof(int));

    float t_hot     = timeit(run_hot, 5);
    float t_ref     = timeit(run_ref, 5);
    float t_relaxed = timeit(run_relaxed, 5);
    float t_spread  = timeit(run_spread, 5);
    float t_block   = timeit(run_block, 5);

    printf("总计 %d 次 +1：\n", N);
    printf("A 单地址 atomicAdd               : %7.3f ms  (基准)\n", t_hot);
    printf("B 单地址 atomic_ref (默认seq_cst): %7.3f ms  (%.2fx of A)\n", t_ref, t_hot/t_ref);
    printf("R 单地址 atomic_ref (relaxed)    : %7.3f ms  (%.2fx of A)\n", t_relaxed, t_hot/t_relaxed);
    printf("C 分散到%d个地址 atomicAdd       : %7.3f ms  (%.1fx of A)\n", slots, t_spread, t_hot/t_spread);
    printf("D 共享内存归并(block作用域)      : %7.3f ms  (%.1fx of A)\n", t_block, t_hot/t_block);

    cudaFree(g); cudaFree(arr);
    return 0;
}
