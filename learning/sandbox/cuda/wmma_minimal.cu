#include <cuda_fp16.h>
#include <cuda_runtime.h>
#include <mma.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace wmma = nvcuda::wmma;

#define CUDA_CHECK(call)                                                        \
  do {                                                                          \
    cudaError_t error = (call);                                                  \
    if (error != cudaSuccess) {                                                  \
      std::fprintf(stderr, "%s failed: %s\n", #call, cudaGetErrorString(error)); \
      std::exit(EXIT_FAILURE);                                                   \
    }                                                                            \
  } while (0)

constexpr int M = 16;
constexpr int N = 16;
constexpr int K = 16;

// Exactly one warp cooperates on one D = A * B + C matrix tile.
__global__ void wmma_gemm_16x16x16(const half* a, const half* b, float* d) {
  wmma::fragment<wmma::matrix_a, M, N, K, half, wmma::row_major> a_frag;
  wmma::fragment<wmma::matrix_b, M, N, K, half, wmma::col_major> b_frag;
  wmma::fragment<wmma::accumulator, M, N, K, float> acc_frag;

  wmma::fill_fragment(acc_frag, 0.0f);
  wmma::load_matrix_sync(a_frag, a, K);
  wmma::load_matrix_sync(b_frag, b, K);
  wmma::mma_sync(acc_frag, a_frag, b_frag, acc_frag);
  wmma::store_matrix_sync(d, acc_frag, N, wmma::mem_row_major);
}

int main() {
  std::vector<half> a(M * K, __float2half(1.0f));
  std::vector<half> b(K * N, __float2half(1.0f));
  std::vector<float> d(M * N, 0.0f);

  half* d_a = nullptr;
  half* d_b = nullptr;
  float* d_d = nullptr;
  CUDA_CHECK(cudaMalloc(&d_a, a.size() * sizeof(half)));
  CUDA_CHECK(cudaMalloc(&d_b, b.size() * sizeof(half)));
  CUDA_CHECK(cudaMalloc(&d_d, d.size() * sizeof(float)));
  CUDA_CHECK(cudaMemcpy(d_a, a.data(), a.size() * sizeof(half),
                        cudaMemcpyHostToDevice));
  CUDA_CHECK(cudaMemcpy(d_b, b.data(), b.size() * sizeof(half),
                        cudaMemcpyHostToDevice));

  wmma_gemm_16x16x16<<<1, 32>>>(d_a, d_b, d_d);
  CUDA_CHECK(cudaGetLastError());
  CUDA_CHECK(cudaMemcpy(d.data(), d_d, d.size() * sizeof(float),
                        cudaMemcpyDeviceToHost));

  float max_error = 0.0f;
  for (float value : d) {
    max_error = std::fmax(max_error, std::fabs(value - 16.0f));
  }

  std::printf("D[0,0] = %.1f, expected = 16.0\n", d[0]);
  std::printf("max absolute error = %.1f\n", max_error);
  std::printf("one warp computed %d output values with one 16x16x16 MMA tile\n",
              M * N);

  CUDA_CHECK(cudaFree(d_d));
  CUDA_CHECK(cudaFree(d_b));
  CUDA_CHECK(cudaFree(d_a));
  return max_error == 0.0f ? EXIT_SUCCESS : EXIT_FAILURE;
}
