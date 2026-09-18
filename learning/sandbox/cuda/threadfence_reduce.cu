#include <cstdio>
#include <cuda_runtime.h>

#define CK(x) do{ cudaError_t e=(x); if(e){printf("err %s\n",cudaGetErrorString(e));return 1;} }while(0)

constexpr int BS = 256;

__device__ unsigned int retirementCount = 0;   // 全局:已完成的 block 计数

// 单趟归约:每个 block 算局部和 -> 写 partials[] -> 最后一个 block 汇总
__global__ void reduceSinglePass(const float* in, int n, float* partials, float* result) {
    __shared__ float s[BS];
    int tid = threadIdx.x;
    int i = blockIdx.x * blockDim.x + tid;

    // 1) block 内归约(shared memory 树规约)
    float v = (i < n) ? in[i] : 0.f;
    s[tid] = v; __syncthreads();
    for (int stride = BS / 2; stride > 0; stride >>= 1) {
        if (tid < stride) s[tid] += s[tid + stride];
        __syncthreads();
    }

    // 2) 0 号线程把本 block 的局部和写进全局 partials
    __shared__ bool amLast;
    if (tid == 0) {
        partials[blockIdx.x] = s[0];

        // 关键:确保上面这次“写 partials”对其他 block 真正可见,
        // 之后才允许别人通过 retirementCount 判断“我完成了”。
        __threadfence();          // device 级栅栏:排序 + 刷新可见性

        unsigned int prev = atomicInc(&retirementCount, gridDim.x);
        amLast = (prev == gridDim.x - 1);   // 我是最后一个到达的 block 吗?
    }
    __syncthreads();

    // 3) 最后一个 block 负责把所有 partials 加起来
    if (amLast) {
        float sum = 0.f;
        for (int b = tid; b < gridDim.x; b += blockDim.x) sum += partials[b];
        s[tid] = sum; __syncthreads();
        for (int stride = BS / 2; stride > 0; stride >>= 1) {
            if (tid < stride) s[tid] += s[tid + stride];
            __syncthreads();
        }
        if (tid == 0) { *result = s[0]; retirementCount = 0; }  // 复位,便于下次
    }
}

int main() {
    const int N = 1 << 22;                     // 4194304 个 1.0f
    int grid = (N + BS - 1) / BS;
    float *d_in, *d_partials, *d_result;
    CK(cudaMalloc(&d_in, N * sizeof(float)));
    CK(cudaMalloc(&d_partials, grid * sizeof(float)));
    CK(cudaMalloc(&d_result, sizeof(float)));

    float* h = new float[N];
    for (int i = 0; i < N; ++i) h[i] = 1.0f;
    CK(cudaMemcpy(d_in, h, N * sizeof(float), cudaMemcpyHostToDevice));

    CK(cudaMemset(d_partials, 0, grid * sizeof(float)));
    reduceSinglePass<<<grid, BS>>>(d_in, N, d_partials, d_result);
    cudaError_t le = cudaGetLastError();
    if (le) printf("[启动错误] %s\n", cudaGetErrorString(le));
    CK(cudaDeviceSynchronize());

    float r; CK(cudaMemcpy(&r, d_result, sizeof(float), cudaMemcpyDeviceToHost));
    printf("单趟归约结果 = %.0f  期望 = %d  %s\n", r, N, (r == (float)N ? "OK" : "FAIL"));
    printf("(用了 %d 个 block;__threadfence 保证最后一个 block 读到的 partials 都已写好)\n", grid);

    delete[] h; cudaFree(d_in); cudaFree(d_partials); cudaFree(d_result);
    return 0;
}
