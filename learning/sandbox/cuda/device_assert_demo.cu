#include <cuda_runtime.h>

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>

__global__ void validate_indices(const int* values, int count, bool debug_assert) {
  const int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < count) {
    (void)values[i];
  } else if (debug_assert) {
    // device assert 失败时会终止 kernel，并让后续同步返回 cudaErrorAssert。
    assert(i < count);
  }
}

int main(int argc, char** argv) {
  const bool fixed = argc > 1 && std::strcmp(argv[1], "fixed") == 0;
  constexpr int count = 100;
  int* values = nullptr;
  if (cudaMalloc(&values, count * sizeof(int)) != cudaSuccess) {
    std::fprintf(stderr, "cudaMalloc failed\n");
    return EXIT_FAILURE;
  }

  const int threads = 64;
  const int blocks = (count + threads - 1) / threads;
  validate_indices<<<blocks, threads>>>(values, count, !fixed);

  // launch 语法本身可能成功；设备端 assert 通常在同步点暴露。
  const cudaError_t launch_error = cudaGetLastError();
  const cudaError_t sync_error = cudaDeviceSynchronize();
  std::printf("mode: %s\n", fixed ? "fixed" : "assert-failure");
  std::printf("cudaGetLastError: %s\n", cudaGetErrorString(launch_error));
  std::printf("cudaDeviceSynchronize: %s\n", cudaGetErrorString(sync_error));

  // assert 后 context 进入错误状态；这里只做演示，真实程序通常记录错误并退出/重置。
  cudaFree(values);
  return fixed && sync_error == cudaSuccess ? EXIT_SUCCESS :
         (!fixed && sync_error == cudaErrorAssert ? EXIT_SUCCESS : EXIT_FAILURE);
}
