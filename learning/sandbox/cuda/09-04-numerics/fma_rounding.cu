#include <cuda_runtime.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#define CUDA_CHECK(call)                                                        \
  do {                                                                          \
    const cudaError_t error = (call);                                          \
    if (error != cudaSuccess) {                                                 \
      std::fprintf(stderr, "%s failed: %s\n", #call, cudaGetErrorString(error)); \
      return EXIT_FAILURE;                                                      \
    }                                                                           \
  } while (0)

__device__ __noinline__ float separate_ops(float a, float b, float c) {
  // volatile 阻止编译器把乘法和加法重新融合。
  volatile float product = a * b;
  return product + c;
}

__device__ __noinline__ float expression_ops(float a, float b, float c) {
  // 默认 nvcc -arch=sm_120 通常会把 a*b+c 融合成 FFMA。
  return a * b + c;
}

__device__ __noinline__ float explicit_fma(float a, float b, float c) {
  return fmaf(a, b, c);
}

__global__ void evaluate(float a, float b, float c, float* result) {
  if (threadIdx.x == 0) {
    result[0] = separate_ops(a, b, c);
    result[1] = expression_ops(a, b, c);
    result[2] = explicit_fma(a, b, c);
  }
}

static std::uint32_t bits(float value) {
  std::uint32_t result = 0;
  std::memcpy(&result, &value, sizeof(result));
  return result;
}

int main() {
  // 这些是精确的 binary32 位模式，刻意构造出双舍入差异。
  const std::uint32_t a_bits = 0x4377e2e7u;
  const std::uint32_t b_bits = 0xc085669au;
  const std::uint32_t c_bits = 0x44f017f8u;
  float a = 0.0f, b = 0.0f, c = 0.0f;
  std::memcpy(&a, &a_bits, sizeof(a));
  std::memcpy(&b, &b_bits, sizeof(b));
  std::memcpy(&c, &c_bits, sizeof(c));

  float* device_result = nullptr;
  float host_result[3]{};
  CUDA_CHECK(cudaMalloc(&device_result, 3 * sizeof(float)));
  evaluate<<<1, 32>>>(a, b, c, device_result);
  CUDA_CHECK(cudaGetLastError());
  CUDA_CHECK(cudaDeviceSynchronize());
  CUDA_CHECK(cudaMemcpy(host_result, device_result, sizeof(host_result),
                        cudaMemcpyDeviceToHost));

  std::printf("a = %.9g (0x%08x)\n", a, bits(a));
  std::printf("b = %.9g (0x%08x)\n", b, bits(b));
  std::printf("c = %.9g (0x%08x)\n", c, bits(c));
  std::printf("separate (rounded multiply, then add): %.9g (0x%08x)\n",
              host_result[0], bits(host_result[0]));
  std::printf("a*b+c (compiler expression):             %.9g (0x%08x)\n",
              host_result[1], bits(host_result[1]));
  std::printf("fmaf(a,b,c) (one final rounding):         %.9g (0x%08x)\n",
              host_result[2], bits(host_result[2]));
  std::printf("expression == fmaf: %s\n",
              host_result[1] == host_result[2] ? "yes" : "no");
  std::printf("separate == fmaf:   %s\n",
              host_result[0] == host_result[2] ? "yes" : "no");

  CUDA_CHECK(cudaFree(device_result));
  return EXIT_SUCCESS;
}
