#include <cstdio>
#include <cuda_runtime.h>

// 标准错误检查宏：检查“同步”API 的返回码
#define CUDA_CHECK(call) do {                                      \
    cudaError_t e = (call);                                        \
    if (e != cudaSuccess) {                                        \
        printf("[CUDA ERROR] %s:%d  %s -> %s\n",                   \
               __FILE__, __LINE__, #call, cudaGetErrorString(e));  \
    }                                                              \
} while (0)

__global__ void noop() {}

int main() {
    // ---- 场景 A：故意用非法配置启动 kernel（每 block 2000 线程 > 1024 上限）----
    printf("=== A. 错误的 kernel 启动配置 (block=2000 > 1024) ===\n");
    noop<<<1, 2000>>>();

    // 启动错误不会通过返回值报告（<<<>>> 没有返回值），要用 cudaGetLastError 取
    cudaError_t launchErr = cudaGetLastError();
    printf("cudaGetLastError() -> %s\n", cudaGetErrorString(launchErr));

    // ---- 场景 B：用宏检查一个同步 API 的错误（故意申请超大显存）----
    printf("\n=== B. 同步 API 错误 (cudaMalloc 申请 999 TB) ===\n");
    void* p = nullptr;
    CUDA_CHECK(cudaMalloc(&p, (size_t)999 * 1024 * 1024 * 1024 * 1024));

    // ---- 场景 C：正确的启动，确认错误状态已清空 ----
    printf("\n=== C. 正确启动 + 同步检查 ===\n");
    noop<<<1, 256>>>();
    CUDA_CHECK(cudaGetLastError());        // 检查启动本身（异步派发）
    CUDA_CHECK(cudaDeviceSynchronize());   // 检查执行期间（运行时）错误
    printf("一切正常\n");
    return 0;
}
