#include <cublas_v2.h>
#include <cuda_runtime.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>

#define CUDA_CHECK(call)                                                        \
  do {                                                                          \
    const cudaError_t error = (call);                                            \
    if (error != cudaSuccess) {                                                  \
      std::fprintf(stderr, "%s failed: %s\n", #call, cudaGetErrorString(error)); \
      std::exit(EXIT_FAILURE);                                                   \
    }                                                                            \
  } while (0)

#define CUBLAS_CHECK(call)                                               \
  do {                                                                   \
    const cublasStatus_t status = (call);                                 \
    if (status != CUBLAS_STATUS_SUCCESS) {                                \
      std::fprintf(stderr, "%s failed: cuBLAS status %d\n", #call,      \
                   static_cast<int>(status));                             \
      std::exit(EXIT_FAILURE);                                            \
    }                                                                     \
  } while (0)

int main() {
  constexpr int m = 2;
  constexpr int k = 3;
  constexpr int n = 2;

  // cuBLAS uses column-major matrices by default.
  // A = [1 2 3; 4 5 6], B = [7 8; 9 10; 11 12].
  const float h_a[m * k] = {1, 4, 2, 5, 3, 6};
  const float h_b[k * n] = {7, 9, 11, 8, 10, 12};
  float h_c[m * n] = {};

  float* d_a = nullptr;
  float* d_b = nullptr;
  float* d_c = nullptr;
  CUDA_CHECK(cudaMalloc(&d_a, sizeof(h_a)));
  CUDA_CHECK(cudaMalloc(&d_b, sizeof(h_b)));
  CUDA_CHECK(cudaMalloc(&d_c, sizeof(h_c)));
  CUDA_CHECK(cudaMemcpy(d_a, h_a, sizeof(h_a), cudaMemcpyHostToDevice));
  CUDA_CHECK(cudaMemcpy(d_b, h_b, sizeof(h_b), cudaMemcpyHostToDevice));

  cublasHandle_t handle = nullptr;
  CUBLAS_CHECK(cublasCreate(&handle));

  const float alpha = 1.0f;
  const float beta = 0.0f;
  CUBLAS_CHECK(cublasSgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, m, n, k,
                          &alpha, d_a, m, d_b, k, &beta, d_c, m));

  CUDA_CHECK(cudaMemcpy(h_c, d_c, sizeof(h_c), cudaMemcpyDeviceToHost));

  const float expected[m * n] = {58, 139, 64, 154};
  int mismatches = 0;
  for (int i = 0; i < m * n; ++i) {
    if (std::fabs(h_c[i] - expected[i]) > 1e-5f) {
      ++mismatches;
    }
  }

  std::printf("C = A * B\n");
  for (int row = 0; row < m; ++row) {
    for (int col = 0; col < n; ++col) {
      std::printf("%7.1f", h_c[row + col * m]);
    }
    std::printf("\n");
  }
  std::printf("mismatches: %d\n", mismatches);

  CUBLAS_CHECK(cublasDestroy(handle));
  CUDA_CHECK(cudaFree(d_c));
  CUDA_CHECK(cudaFree(d_b));
  CUDA_CHECK(cudaFree(d_a));
  return mismatches == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
