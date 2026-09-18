#include <cuda_runtime.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#define CUDA_CHECK(call)                                                        \
  do {                                                                          \
    const cudaError_t error = (call);                                          \
    if (error != cudaSuccess) {                                                 \
      std::fprintf(stderr, "%s failed: %s\n", #call, cudaGetErrorString(error)); \
      return EXIT_FAILURE;                                                      \
    }                                                                           \
  } while (0)

__global__ void block_sum(const float* input, float* partial, int count) {
  __shared__ float shared[256];
  const unsigned tid = threadIdx.x;
  float local = 0.0f;
  for (int i = blockIdx.x * blockDim.x + tid;
       i < count; i += gridDim.x * blockDim.x) {
    local += input[i];
  }
  shared[tid] = local;
  __syncthreads();
  for (unsigned stride = blockDim.x / 2; stride != 0; stride >>= 1) {
    if (tid < stride) {
      shared[tid] += shared[tid + stride];
    }
    __syncthreads();
  }
  if (tid == 0) {
    partial[blockIdx.x] = shared[0];
  }
}

__global__ void atomic_sum(const float* input, float* result, int count) {
  const int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < count) {
    atomicAdd(result, input[i]);
  }
}

static std::uint32_t bits(float value) {
  std::uint32_t result = 0;
  std::memcpy(&result, &value, sizeof(result));
  return result;
}

static float sum_float_forward(const std::vector<float>& values) {
  float result = 0.0f;
  for (float value : values) {
    result += value;
  }
  return result;
}

static float sum_float_reverse(const std::vector<float>& values) {
  float result = 0.0f;
  for (auto it = values.rbegin(); it != values.rend(); ++it) {
    result += *it;
  }
  return result;
}

int main() {
  constexpr int count = 1 << 20;
  constexpr int threads = 256;
  constexpr int blocks = (count + threads - 1) / threads;
  std::vector<float> host_values(count, 1.0f);
  host_values.front() = 1.0e8f;
  host_values.back() = -1.0e8f;

  long double reference = 0.0L;
  for (float value : host_values) {
    reference += static_cast<long double>(value);
  }

  float* device_values = nullptr;
  float* device_partial = nullptr;
  float* device_atomic = nullptr;
  CUDA_CHECK(cudaMalloc(&device_values, count * sizeof(float)));
  CUDA_CHECK(cudaMalloc(&device_partial, blocks * sizeof(float)));
  CUDA_CHECK(cudaMalloc(&device_atomic, sizeof(float)));
  CUDA_CHECK(cudaMemcpy(device_values, host_values.data(),
                        count * sizeof(float), cudaMemcpyHostToDevice));

  block_sum<<<blocks, threads>>>(device_values, device_partial, count);
  CUDA_CHECK(cudaGetLastError());
  CUDA_CHECK(cudaDeviceSynchronize());
  std::vector<float> partial(blocks);
  CUDA_CHECK(cudaMemcpy(partial.data(), device_partial,
                        blocks * sizeof(float), cudaMemcpyDeviceToHost));
  float tree_result = 0.0f;
  for (float value : partial) {
    tree_result += value;
  }

  std::vector<float> atomic_results;
  for (int run = 0; run < 8; ++run) {
    CUDA_CHECK(cudaMemset(device_atomic, 0, sizeof(float)));
    atomic_sum<<<blocks, threads>>>(device_values, device_atomic, count);
    CUDA_CHECK(cudaGetLastError());
    CUDA_CHECK(cudaDeviceSynchronize());
    float result = 0.0f;
    CUDA_CHECK(cudaMemcpy(&result, device_atomic, sizeof(float),
                          cudaMemcpyDeviceToHost));
    atomic_results.push_back(result);
  }

  int unique_atomic = 0;
  for (std::size_t i = 0; i < atomic_results.size(); ++i) {
    bool seen = false;
    for (std::size_t j = 0; j < i; ++j) {
      seen |= bits(atomic_results[i]) == bits(atomic_results[j]);
    }
    if (!seen) {
      ++unique_atomic;
    }
  }

  std::printf("count: %d, long-double reference: %.0Lf\n", count, reference);
  const float forward = sum_float_forward(host_values);
  const float reverse = sum_float_reverse(host_values);
  std::printf("CPU forward: %.9g (0x%08x)\n", forward, bits(forward));
  std::printf("CPU reverse: %.9g (0x%08x)\n", reverse, bits(reverse));
  std::printf("fixed block tree: %.9g (0x%08x)\n", tree_result,
              bits(tree_result));
  for (std::size_t i = 0; i < atomic_results.size(); ++i) {
    std::printf("atomic run %zu: %.9g (0x%08x)\n", i,
                atomic_results[i], bits(atomic_results[i]));
  }
  std::printf("atomic unique bit patterns in 8 runs: %d\n", unique_atomic);

  CUDA_CHECK(cudaFree(device_values));
  CUDA_CHECK(cudaFree(device_partial));
  CUDA_CHECK(cudaFree(device_atomic));
  return EXIT_SUCCESS;
}
