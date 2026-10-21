#include <cstdio>
#include <cuda_runtime.h>
#include <cub/cub.cuh>
#include <thrust/device_vector.h>
#include <thrust/reduce.h>

int main() {
    const int n = 1 << 24;                  // 1600 万个元素
    thrust::device_vector<float> d(n, 1.0f); // 全 1，求和应得 n
    float* d_ptr = thrust::raw_pointer_cast(d.data());

    // ============ 方式 1：Thrust（一行，全自动）============
    float sum_thrust = thrust::reduce(d.begin(), d.end(), 0.0f);
    printf("Thrust:  sum = %.0f\n", sum_thrust);

    // ============ 方式 2：CUB（标志性的两步式 API）============
    float* d_out; cudaMalloc(&d_out, sizeof(float));

    // --- 第 1 步：问 CUB “你需要多大的临时显存？” ---
    void*  d_temp = nullptr;
    size_t temp_bytes = 0;
    cub::DeviceReduce::Sum(d_temp, temp_bytes, d_ptr, d_out, n); // d_temp=nullptr → 只算大小
    printf("CUB 需要的临时显存: %zu bytes\n", temp_bytes);

    // --- 第 2 步：自己分配这块临时显存，再真正调用 ---
    cudaMalloc(&d_temp, temp_bytes);
    cub::DeviceReduce::Sum(d_temp, temp_bytes, d_ptr, d_out, n); // 这次真干活（异步）
    cudaDeviceSynchronize();                                     // CUB 异步，自己等

    float sum_cub;
    cudaMemcpy(&sum_cub, d_out, sizeof(float), cudaMemcpyDeviceToHost);
    printf("CUB:     sum = %.0f\n", sum_cub);

    cudaFree(d_temp);
    cudaFree(d_out);
    return 0;
}
