#include <cublasLt.h>
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

#define CUBLAS_CHECK(call)                                                  \
  do {                                                                      \
    const cublasStatus_t status = (call);                                    \
    if (status != CUBLAS_STATUS_SUCCESS) {                                   \
      std::fprintf(stderr, "%s failed: cuBLAS status %d\n", #call,         \
                   static_cast<int>(status));                                \
      std::exit(EXIT_FAILURE);                                               \
    }                                                                        \
  } while (0)

int main() {
  constexpr int m = 2;
  constexpr int k = 3;
  constexpr int n = 2;

  // Row-major matrices:
  // A = [1 -2 3; -4 5 -6], B = [7 -8; 9 10; -11 12].
  const float h_a[m * k] = {1, -2, 3, -4, 5, -6};
  const float h_b[k * n] = {7, -8, 9, 10, -11, 12};
  const float h_c[m * n] = {};
  float h_d[m * n] = {};

  float* d_a = nullptr;
  float* d_b = nullptr;
  float* d_c = nullptr;
  float* d_d = nullptr;
  CUDA_CHECK(cudaMalloc(&d_a, sizeof(h_a)));
  CUDA_CHECK(cudaMalloc(&d_b, sizeof(h_b)));
  CUDA_CHECK(cudaMalloc(&d_c, sizeof(h_c)));
  CUDA_CHECK(cudaMalloc(&d_d, sizeof(h_d)));
  CUDA_CHECK(cudaMemcpy(d_a, h_a, sizeof(h_a), cudaMemcpyHostToDevice));
  CUDA_CHECK(cudaMemcpy(d_b, h_b, sizeof(h_b), cudaMemcpyHostToDevice));
  CUDA_CHECK(cudaMemcpy(d_c, h_c, sizeof(h_c), cudaMemcpyHostToDevice));

  cublasLtHandle_t handle = nullptr;
  cublasLtMatmulDesc_t operation = nullptr;
  cublasLtMatrixLayout_t layout_a = nullptr;
  cublasLtMatrixLayout_t layout_b = nullptr;
  cublasLtMatrixLayout_t layout_c = nullptr;
  cublasLtMatrixLayout_t layout_d = nullptr;
  cublasLtMatmulPreference_t preference = nullptr;

  CUBLAS_CHECK(cublasLtCreate(&handle));
  CUBLAS_CHECK(cublasLtMatmulDescCreate(
      &operation, CUBLAS_COMPUTE_32F, CUDA_R_32F));

  const cublasLtEpilogue_t epilogue = CUBLASLT_EPILOGUE_RELU;
  CUBLAS_CHECK(cublasLtMatmulDescSetAttribute(
      operation, CUBLASLT_MATMUL_DESC_EPILOGUE, &epilogue,
      sizeof(epilogue)));

  CUBLAS_CHECK(cublasLtMatrixLayoutCreate(
      &layout_a, CUDA_R_32F, m, k, k));
  CUBLAS_CHECK(cublasLtMatrixLayoutCreate(
      &layout_b, CUDA_R_32F, k, n, n));
  CUBLAS_CHECK(cublasLtMatrixLayoutCreate(
      &layout_c, CUDA_R_32F, m, n, n));
  CUBLAS_CHECK(cublasLtMatrixLayoutCreate(
      &layout_d, CUDA_R_32F, m, n, n));

  const cublasLtOrder_t order = CUBLASLT_ORDER_ROW;
  for (cublasLtMatrixLayout_t layout :
       {layout_a, layout_b, layout_c, layout_d}) {
    CUBLAS_CHECK(cublasLtMatrixLayoutSetAttribute(
        layout, CUBLASLT_MATRIX_LAYOUT_ORDER, &order, sizeof(order)));
  }

  constexpr size_t workspace_bytes = 4 * 1024 * 1024;
  void* workspace = nullptr;
  CUDA_CHECK(cudaMalloc(&workspace, workspace_bytes));
  CUBLAS_CHECK(cublasLtMatmulPreferenceCreate(&preference));
  CUBLAS_CHECK(cublasLtMatmulPreferenceSetAttribute(
      preference, CUBLASLT_MATMUL_PREF_MAX_WORKSPACE_BYTES,
      &workspace_bytes, sizeof(workspace_bytes)));

  cublasLtMatmulHeuristicResult_t heuristic{};
  int returned_algorithms = 0;
  CUBLAS_CHECK(cublasLtMatmulAlgoGetHeuristic(
      handle, operation, layout_a, layout_b, layout_c, layout_d,
      preference, 1, &heuristic, &returned_algorithms));
  if (returned_algorithms == 0) {
    std::fprintf(stderr, "No cuBLASLt algorithm supports this operation.\n");
    return EXIT_FAILURE;
  }

  const float alpha = 1.0f;
  const float beta = 0.0f;
  CUBLAS_CHECK(cublasLtMatmul(
      handle, operation, &alpha, d_a, layout_a, d_b, layout_b, &beta,
      d_c, layout_c, d_d, layout_d, &heuristic.algo, workspace,
      workspace_bytes, nullptr));
  CUDA_CHECK(cudaMemcpy(h_d, d_d, sizeof(h_d), cudaMemcpyDeviceToHost));

  // A * B = [-44 8; 83 10], then ReLU produces [0 8; 83 10].
  const float expected[m * n] = {0, 8, 83, 10};
  int mismatches = 0;
  for (int i = 0; i < m * n; ++i) {
    if (std::fabs(h_d[i] - expected[i]) > 1e-5f) {
      ++mismatches;
    }
  }

  std::printf("D = ReLU(A * B), row-major\n");
  for (int row = 0; row < m; ++row) {
    for (int col = 0; col < n; ++col) {
      std::printf("%7.1f", h_d[row * n + col]);
    }
    std::printf("\n");
  }
  std::printf("heuristic algorithms returned: %d\n", returned_algorithms);
  std::printf("selected workspace: %zu bytes\n", heuristic.workspaceSize);
  std::printf("mismatches: %d\n", mismatches);

  CUBLAS_CHECK(cublasLtMatmulPreferenceDestroy(preference));
  CUBLAS_CHECK(cublasLtMatrixLayoutDestroy(layout_d));
  CUBLAS_CHECK(cublasLtMatrixLayoutDestroy(layout_c));
  CUBLAS_CHECK(cublasLtMatrixLayoutDestroy(layout_b));
  CUBLAS_CHECK(cublasLtMatrixLayoutDestroy(layout_a));
  CUBLAS_CHECK(cublasLtMatmulDescDestroy(operation));
  CUBLAS_CHECK(cublasLtDestroy(handle));
  CUDA_CHECK(cudaFree(workspace));
  CUDA_CHECK(cudaFree(d_d));
  CUDA_CHECK(cudaFree(d_c));
  CUDA_CHECK(cudaFree(d_b));
  CUDA_CHECK(cudaFree(d_a));
  return mismatches == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
