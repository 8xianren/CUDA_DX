#include <cuda_runtime.h>

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

// 故意让两个线程写同一个 shared 地址。racecheck 应报告 write-after-write。
__global__ void racy_shared_write(int* output) {
  __shared__ int slot;
  if (threadIdx.x < 2) {
    slot = static_cast<int>(threadIdx.x);
  }
  __syncthreads();
  if (threadIdx.x == 0) {
    output[0] = slot;
  }
}

// 修复版本：每个线程写自己的槽位，再由线程 0 读取确定的值。
__global__ void fixed_shared_write(int* output) {
  __shared__ int slots[2];
  if (threadIdx.x < 2) {
    slots[threadIdx.x] = static_cast<int>(threadIdx.x);
  }
  __syncthreads();
  if (threadIdx.x == 0) {
    output[0] = slots[0] + slots[1];
  }
}

int main(int argc, char** argv) {
  const bool fixed = argc > 1 && std::strcmp(argv[1], "fixed") == 0;
  int* device_output = nullptr;
  int host_output = -1;
  CUDA_CHECK(cudaMalloc(&device_output, sizeof(int)));
  CUDA_CHECK(cudaMemset(device_output, 0, sizeof(int)));

  if (fixed) {
    fixed_shared_write<<<1, 32>>>(device_output);
  } else {
    racy_shared_write<<<1, 32>>>(device_output);
  }
  CUDA_CHECK(cudaGetLastError());
  CUDA_CHECK(cudaDeviceSynchronize());
  CUDA_CHECK(cudaMemcpy(&host_output, device_output, sizeof(int),
                        cudaMemcpyDeviceToHost));
  std::printf("mode: %s, output: %d\n", fixed ? "fixed" : "racy",
              host_output);
  CUDA_CHECK(cudaFree(device_output));
  return EXIT_SUCCESS;
}
