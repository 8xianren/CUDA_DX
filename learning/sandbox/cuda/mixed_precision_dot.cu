#include <cuda_runtime.h>
#include <cuda_fp16.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

#define CUDA_CHECK(call)                                                        \
  do {                                                                          \
    const cudaError_t error = (call);                                          \
    if (error != cudaSuccess) {                                                 \
      std::fprintf(stderr, "%s failed: %s\n", #call, cudaGetErrorString(error)); \
      return EXIT_FAILURE;                                                      \
    }                                                                           \
  } while (0)

template <typename T>
__device__ void reduce_block(T* shared, unsigned tid) {
  __syncthreads();
  for (unsigned stride = blockDim.x / 2; stride != 0; stride >>= 1) {
    if (tid < stride) {
      shared[tid] += shared[tid + stride];
    }
    __syncthreads();
  }
}

__global__ void dot_half_accumulate(const __half* a, const __half* b,
                                    double* partial, int count) {
  __shared__ double shared[256];
  const unsigned tid = threadIdx.x;
  __half local = __float2half(0.0f);
  for (int i = blockIdx.x * blockDim.x + tid;
       i < count; i += gridDim.x * blockDim.x) {
    local = __hadd(local, __hmul(a[i], b[i]));
  }
  shared[tid] = static_cast<double>(__half2float(local));
  reduce_block(shared, tid);
  if (tid == 0) {
    partial[blockIdx.x] = shared[0];
  }
}

__global__ void dot_float_accumulate(const __half* a, const __half* b,
                                     double* partial, int count) {
  __shared__ double shared[256];
  const unsigned tid = threadIdx.x;
  float local = 0.0f;
  for (int i = blockIdx.x * blockDim.x + tid;
       i < count; i += gridDim.x * blockDim.x) {
    local += __half2float(a[i]) * __half2float(b[i]);
  }
  shared[tid] = static_cast<double>(local);
  reduce_block(shared, tid);
  if (tid == 0) {
    partial[blockIdx.x] = shared[0];
  }
}

__global__ void dot_double_accumulate(const __half* a, const __half* b,
                                      double* partial, int count) {
  __shared__ double shared[256];
  const unsigned tid = threadIdx.x;
  double local = 0.0;
  for (int i = blockIdx.x * blockDim.x + tid;
       i < count; i += gridDim.x * blockDim.x) {
    local += static_cast<double>(__half2float(a[i])) *
             static_cast<double>(__half2float(b[i]));
  }
  shared[tid] = local;
  reduce_block(shared, tid);
  if (tid == 0) {
    partial[blockIdx.x] = shared[0];
  }
}

double run_dot(const __half* device_a, const __half* device_b,
               double* device_partial, int count, int blocks, int mode) {
  if (mode == 0) {
    dot_half_accumulate<<<blocks, 256>>>(device_a, device_b, device_partial,
                                          count);
  } else if (mode == 1) {
    dot_float_accumulate<<<blocks, 256>>>(device_a, device_b, device_partial,
                                           count);
  } else {
    dot_double_accumulate<<<blocks, 256>>>(device_a, device_b, device_partial,
                                            count);
  }
  CUDA_CHECK(cudaGetLastError());
  CUDA_CHECK(cudaDeviceSynchronize());
  std::vector<double> partial(blocks);
  CUDA_CHECK(cudaMemcpy(partial.data(), device_partial,
                        blocks * sizeof(double), cudaMemcpyDeviceToHost));
  double result = 0.0;
  for (double value : partial) {
    result += value;
  }
  return result;
}

int main() {
  constexpr int count = 1 << 20;
  constexpr int blocks = 64;
  constexpr int threads = 256;
  (void)threads;
  std::vector<__half> host_a(count);
  std::vector<__half> host_b(count);
  long double reference = 0.0L;
  for (int i = 0; i < count; ++i) {
    const float a = 0.1f + static_cast<float>(i % 7) * 0.001f;
    const float b = 0.2f + static_cast<float>(i % 5) * 0.002f;
    host_a[i] = __float2half(a);
    host_b[i] = __float2half(b);
    // 参考值使用“已经量化为 half 的输入”，只比较累加精度的影响。
    reference += static_cast<long double>(__half2float(host_a[i])) *
                 static_cast<long double>(__half2float(host_b[i]));
  }

  __half* device_a = nullptr;
  __half* device_b = nullptr;
  double* device_partial = nullptr;
  CUDA_CHECK(cudaMalloc(&device_a, count * sizeof(__half)));
  CUDA_CHECK(cudaMalloc(&device_b, count * sizeof(__half)));
  CUDA_CHECK(cudaMalloc(&device_partial, blocks * sizeof(double)));
  CUDA_CHECK(cudaMemcpy(device_a, host_a.data(), count * sizeof(__half),
                        cudaMemcpyHostToDevice));
  CUDA_CHECK(cudaMemcpy(device_b, host_b.data(), count * sizeof(__half),
                        cudaMemcpyHostToDevice));

  const double half_result =
      run_dot(device_a, device_b, device_partial, count, blocks, 0);
  const double float_result =
      run_dot(device_a, device_b, device_partial, count, blocks, 1);
  const double double_result =
      run_dot(device_a, device_b, device_partial, count, blocks, 2);

  auto print_result = [reference](const char* name, double value) {
    const long double absolute_error =
        std::fabs(static_cast<long double>(value) - reference);
    const long double relative_error = absolute_error / std::fabs(reference);
    std::printf("%-20s %.12g, abs error %.6Lg, rel error %.6Lg\n", name,
                value, absolute_error, relative_error);
  };
  std::printf("count: %d, reference (half inputs, long-double sum): %.12Lg\n",
              count, reference);
  print_result("FP16 accumulate", half_result);
  print_result("FP32 accumulate", float_result);
  print_result("FP64 accumulate", double_result);
  std::printf("FP16 storage bytes: %zu, FP32 accumulator bytes: %zu\n",
              sizeof(__half), sizeof(float));

  CUDA_CHECK(cudaFree(device_a));
  CUDA_CHECK(cudaFree(device_b));
  CUDA_CHECK(cudaFree(device_partial));
  return EXIT_SUCCESS;
}
