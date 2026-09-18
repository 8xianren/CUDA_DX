#include <cuda.h>
#include <cuda/barrier>
#include <cuda/ptx>
#include <cuda_runtime.h>

#include <cstdio>
#include <cstdlib>
#include <utility>
#include <vector>

#ifdef _MSC_VER
#pragma comment(lib, "cuda.lib")
#endif

namespace ptx = cuda::ptx;
using block_barrier = cuda::barrier<cuda::thread_scope_block>;

#define CUDA_CHECK(call)                                                        \
  do {                                                                          \
    cudaError_t error = (call);                                                  \
    if (error != cudaSuccess) {                                                  \
      std::fprintf(stderr, "%s failed: %s\n", #call, cudaGetErrorString(error)); \
      std::exit(EXIT_FAILURE);                                                   \
    }                                                                            \
  } while (0)

#define CU_CHECK(call)                                                   \
  do {                                                                   \
    CUresult error = (call);                                              \
    if (error != CUDA_SUCCESS) {                                          \
      const char* message = nullptr;                                      \
      cuGetErrorString(error, &message);                                   \
      std::fprintf(stderr, "%s failed: %s\n", #call, message);           \
      std::exit(EXIT_FAILURE);                                            \
    }                                                                     \
  } while (0)

constexpr int kWidth = 16;
constexpr int kHeight = 16;
constexpr int kElements = kWidth * kHeight;

__global__ void tma_add_1000(const __grid_constant__ CUtensorMap tensor_map) {
  __shared__ alignas(128) int tile[kHeight][kWidth];

#pragma nv_diag_suppress static_var_with_dynamic_init
  __shared__ block_barrier ready;
  if (threadIdx.x == 0) {
    init(&ready, blockDim.x);
  }
  __syncthreads();

  block_barrier::arrival_token token;
  if (threadIdx.x == 0) {
    const int32_t coordinates[2] = {0, 0};
    ptx::cp_async_bulk_tensor(
        ptx::space_shared, ptx::space_global, &tile, &tensor_map, coordinates,
        cuda::device::barrier_native_handle(ready));
    token = cuda::device::barrier_arrive_tx(ready, 1, sizeof(tile));
  } else {
    token = ready.arrive();
  }
  ready.wait(std::move(token));

  const int linear_index = threadIdx.x;
  tile[linear_index / kWidth][linear_index % kWidth] += 1000;

  // Generic shared-memory writes must become visible to the TMA async proxy.
  ptx::fence_proxy_async(ptx::space_shared);
  __syncthreads();

  if (threadIdx.x == 0) {
    const int32_t coordinates[2] = {0, 0};
    ptx::cp_async_bulk_tensor(ptx::space_global, ptx::space_shared, &tensor_map,
                              coordinates, &tile);
    ptx::cp_async_bulk_commit_group();
    ptx::cp_async_bulk_wait_group_read(ptx::n32_t<0>());
    ready.~block_barrier();
  }
}

int main() {
  std::vector<int> data(kElements);
  for (int i = 0; i < kElements; ++i) {
    data[i] = i;
  }

  int* d_data = nullptr;
  CUDA_CHECK(cudaMalloc(&d_data, data.size() * sizeof(int)));
  CUDA_CHECK(cudaMemcpy(d_data, data.data(), data.size() * sizeof(int),
                        cudaMemcpyHostToDevice));

  CUtensorMap tensor_map{};
  constexpr unsigned int rank = 2;
  const cuuint64_t global_dimensions[rank] = {kWidth, kHeight};
  const cuuint64_t global_strides[rank - 1] = {
      kWidth * sizeof(int)};
  const cuuint32_t box_dimensions[rank] = {kWidth, kHeight};
  const cuuint32_t element_strides[rank] = {1, 1};

  CU_CHECK(cuTensorMapEncodeTiled(
      &tensor_map, CU_TENSOR_MAP_DATA_TYPE_INT32, rank, d_data,
      global_dimensions, global_strides, box_dimensions, element_strides,
      CU_TENSOR_MAP_INTERLEAVE_NONE, CU_TENSOR_MAP_SWIZZLE_NONE,
      CU_TENSOR_MAP_L2_PROMOTION_NONE, CU_TENSOR_MAP_FLOAT_OOB_FILL_NONE));

  tma_add_1000<<<1, kElements>>>(tensor_map);
  CUDA_CHECK(cudaGetLastError());
  CUDA_CHECK(cudaDeviceSynchronize());
  CUDA_CHECK(cudaMemcpy(data.data(), d_data, data.size() * sizeof(int),
                        cudaMemcpyDeviceToHost));

  int mismatches = 0;
  for (int i = 0; i < kElements; ++i) {
    if (data[i] != i + 1000) {
      ++mismatches;
    }
  }

  std::printf("tensor: %d x %d int32\n", kWidth, kHeight);
  std::printf("tile transfer: %zu bytes each direction\n",
              kElements * sizeof(int));
  std::printf("first row: ");
  for (int x = 0; x < kWidth; ++x) {
    std::printf("%d%s", data[x], x + 1 == kWidth ? "\n" : " ");
  }
  std::printf("mismatches: %d\n", mismatches);

  CUDA_CHECK(cudaFree(d_data));
  return mismatches == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
