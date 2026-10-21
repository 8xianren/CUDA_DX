#include <cstdio>
#include <cuda_runtime.h>

// 一个最小错误检查宏：CUDA API 出错就打印并退出（1.6 节会展开）
#define CHECK(call) do { \
    cudaError_t e = (call); \
    if (e != cudaSuccess) { \
        printf("CUDA error %s:%d: %s\n", __FILE__, __LINE__, cudaGetErrorString(e)); \
        return 1; \
    } \
} while (0)

__global__ void add_one(int* data, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) data[i] += 1;
}

int main() {
    const int n = 8;
    const size_t bytes = n * sizeof(int);

    // 统一内存：一个指针，CPU 和 GPU 都能直接用，系统自动迁移
    int* data;
    CHECK(cudaMallocManaged(&data, bytes));

    // 直接在 CPU 上初始化（不需要 cudaMemcpy）
    for (int i = 0; i < n; ++i) data[i] = i * 10;

    // GPU 上加一
    add_one<<<1, n>>>(data, n);
    CHECK(cudaDeviceSynchronize());   // 同步后 CPU 才能安全读结果

    // 直接在 CPU 上读结果（同样不需要 cudaMemcpy）
    printf("结果: ");
    for (int i = 0; i < n; ++i) printf("%d ", data[i]);   // 期望 1 11 21 ... 71
    printf("\n(期望: 1 11 21 31 41 51 61 71)\n");

    CHECK(cudaFree(data));
    return 0;
}
