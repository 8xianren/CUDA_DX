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

__global__ void out_of_bounds(int* values, int count) {
  const int i = blockIdx.x * blockDim.x + threadIdx.x;
  // 故意没有 if (i < count)，最后 28 个线程会越过分配边界。
  values[i] = i;
}

__global__ void bounded_write(int* values, int count) {
  const int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < count) {
    values[i] = i;
  }
}

__global__ void read_uninitialized(const int* input, int* output) {
  if (threadIdx.x == 0) {
    // cudaMalloc 不等于 cudaMemset；这里故意读取未初始化内容。
    output[0] = input[0] + 1;
  }
}

__global__ void divergent_barrier(int* output) {
  // __syncthreads 是 block 集体操作，不能只让一个线程进入。
  if (threadIdx.x < 16) {
    __syncthreads();
    output[0] = 1;
  }
}

__global__ void uniform_barrier(int* output) {
  __syncthreads();
  if (threadIdx.x == 0) {
    output[0] = 1;
  }
}

__global__ void invalid_syncwarp(int* output) {
  if (threadIdx.x >= 16) {
    // 调用者 lane 不在 mask 中，违反 __syncwarp 的 mask 约束。
    __syncwarp(0x0000ffffu);
  }
  if (threadIdx.x == 0) {
    output[0] = 1;
  }
}

__global__ void valid_syncwarp(int* output) {
  __syncwarp(0xffffffffu);
  if (threadIdx.x == 0) {
    output[0] = 1;
  }
}

int main(int argc, char** argv) {
  const char* mode = argc > 1 ? argv[1] : "memcheck";
  const bool fixed = argc > 2 && std::strcmp(argv[2], "fixed") == 0;

  int* values = nullptr;
  int* output = nullptr;
  constexpr int count = 100;
  CUDA_CHECK(cudaMalloc(&values, count * sizeof(int)));
  CUDA_CHECK(cudaMalloc(&output, sizeof(int)));
  CUDA_CHECK(cudaMemset(output, 0, sizeof(int)));

  if (std::strcmp(mode, "memcheck") == 0) {
    if (fixed) {
      bounded_write<<<2, 64>>>(values, count);
    } else {
      out_of_bounds<<<2, 64>>>(values, count);
    }
  } else if (std::strcmp(mode, "initcheck") == 0) {
    if (fixed) {
      CUDA_CHECK(cudaMemset(values, 41, sizeof(int)));
    }
    read_uninitialized<<<1, 32>>>(values, output);
  } else if (std::strcmp(mode, "synccheck") == 0) {
    if (fixed) {
      uniform_barrier<<<1, 32>>>(output);
    } else {
      divergent_barrier<<<1, 32>>>(output);
    }
  } else if (std::strcmp(mode, "syncwarp") == 0) {
    if (fixed) {
      valid_syncwarp<<<1, 32>>>(output);
    } else {
      invalid_syncwarp<<<1, 32>>>(output);
    }
  } else {
    std::fprintf(stderr, "usage: %s [memcheck|initcheck|synccheck|syncwarp] [fixed]\n",
                 argv[0]);
    cudaFree(values);
    cudaFree(output);
    return EXIT_FAILURE;
  }

  CUDA_CHECK(cudaGetLastError());
  CUDA_CHECK(cudaDeviceSynchronize());
  int host_output = -1;
  CUDA_CHECK(cudaMemcpy(&host_output, output, sizeof(int),
                        cudaMemcpyDeviceToHost));
  std::printf("mode: %s%s, output: %d\n", mode, fixed ? " fixed" : " racy",
              host_output);
  CUDA_CHECK(cudaFree(values));
  CUDA_CHECK(cudaFree(output));
  return EXIT_SUCCESS;
}
