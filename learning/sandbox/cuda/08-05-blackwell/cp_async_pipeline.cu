#include <cuda/pipeline>
#include <cuda_runtime.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

#define CUDA_CHECK(call)                                                        \
  do {                                                                          \
    cudaError_t error = (call);                                                  \
    if (error != cudaSuccess) {                                                  \
      std::fprintf(stderr, "%s failed: %s\n", #call, cudaGetErrorString(error)); \
      std::exit(EXIT_FAILURE);                                                   \
    }                                                                            \
  } while (0)

constexpr int kThreads = 256;
constexpr int kStages = 2;
constexpr int kBatchesPerBlock = 64;
constexpr int kBlocks = 120;

__device__ float compute(float value) {
#pragma unroll
  for (int i = 0; i < 32; ++i) {
    value = value * 1.0001f + 0.0001f;
  }
  return value;
}

__global__ void synchronous_kernel(const float* input, float* output) {
  const int tid = threadIdx.x;
  for (int batch = 0; batch < kBatchesPerBlock; ++batch) {
    const int index = (blockIdx.x * kBatchesPerBlock + batch) * blockDim.x + tid;
    output[index] = compute(input[index]);
  }
}

__global__ void pipelined_kernel(const float* input, float* output) {
  __shared__ alignas(128) float shared[kStages][kThreads];

  const int tid = threadIdx.x;
  int stage = 0;
  auto pipeline = cuda::make_pipeline();

  // Prime both stages before consuming the first batch.
  for (int s = 0; s < kStages; ++s) {
    const int index = (blockIdx.x * kBatchesPerBlock + s) * blockDim.x + tid;
    pipeline.producer_acquire();
    cuda::memcpy_async(&shared[s][tid], &input[index],
                       cuda::aligned_size_t<4>(sizeof(float)), pipeline);
    pipeline.producer_commit();
  }

  for (int compute_batch = 0, fetch_batch = kStages;
       compute_batch < kBatchesPerBlock; ++compute_batch, ++fetch_batch) {
    // With two stages, leave at most one newer batch pending and wait for the
    // oldest batch before reading its shared-memory slot.
    cuda::pipeline_consumer_wait_prior<kStages - 1>(pipeline);

    const int output_index =
        (blockIdx.x * kBatchesPerBlock + compute_batch) * blockDim.x + tid;
    output[output_index] = compute(shared[stage][tid]);
    pipeline.consumer_release();

    pipeline.producer_acquire();
    if (fetch_batch < kBatchesPerBlock) {
      const int input_index =
          (blockIdx.x * kBatchesPerBlock + fetch_batch) * blockDim.x + tid;
      cuda::memcpy_async(&shared[stage][tid], &input[input_index],
                         cuda::aligned_size_t<4>(sizeof(float)), pipeline);
    }
    pipeline.producer_commit();
    stage = (stage + 1) % kStages;
  }
}

template <typename Kernel>
float time_kernel(Kernel kernel, const float* input, float* output) {
  cudaEvent_t start{};
  cudaEvent_t stop{};
  CUDA_CHECK(cudaEventCreate(&start));
  CUDA_CHECK(cudaEventCreate(&stop));

  kernel<<<kBlocks, kThreads>>>(input, output);
  CUDA_CHECK(cudaGetLastError());
  CUDA_CHECK(cudaDeviceSynchronize());

  constexpr int kIterations = 100;
  CUDA_CHECK(cudaEventRecord(start));
  for (int i = 0; i < kIterations; ++i) {
    kernel<<<kBlocks, kThreads>>>(input, output);
  }
  CUDA_CHECK(cudaEventRecord(stop));
  CUDA_CHECK(cudaEventSynchronize(stop));

  float milliseconds = 0.0f;
  CUDA_CHECK(cudaEventElapsedTime(&milliseconds, start, stop));
  CUDA_CHECK(cudaEventDestroy(stop));
  CUDA_CHECK(cudaEventDestroy(start));
  return milliseconds / kIterations;
}

int main() {
  constexpr int kElementCount =
      kBlocks * kBatchesPerBlock * kThreads;
  std::vector<float> input(kElementCount);
  std::vector<float> synchronous_output(kElementCount);
  std::vector<float> pipelined_output(kElementCount);
  for (int i = 0; i < kElementCount; ++i) {
    input[i] = static_cast<float>(i % 1024) / 1024.0f;
  }

  float* d_input = nullptr;
  float* d_output = nullptr;
  CUDA_CHECK(cudaMalloc(&d_input, input.size() * sizeof(float)));
  CUDA_CHECK(cudaMalloc(&d_output, input.size() * sizeof(float)));
  CUDA_CHECK(cudaMemcpy(d_input, input.data(), input.size() * sizeof(float),
                        cudaMemcpyHostToDevice));

  const float synchronous_ms =
      time_kernel(synchronous_kernel, d_input, d_output);
  CUDA_CHECK(cudaMemcpy(synchronous_output.data(), d_output,
                        synchronous_output.size() * sizeof(float),
                        cudaMemcpyDeviceToHost));

  const float pipelined_ms = time_kernel(pipelined_kernel, d_input, d_output);
  CUDA_CHECK(cudaMemcpy(pipelined_output.data(), d_output,
                        pipelined_output.size() * sizeof(float),
                        cudaMemcpyDeviceToHost));

  float max_difference = 0.0f;
  for (int i = 0; i < kElementCount; ++i) {
    max_difference = std::fmax(
        max_difference,
        std::fabs(synchronous_output[i] - pipelined_output[i]));
  }

  std::printf("elements: %d\n", kElementCount);
  std::printf("synchronous direct load: %.3f ms\n", synchronous_ms);
  std::printf("two-stage cp.async pipeline: %.3f ms\n", pipelined_ms);
  std::printf("pipeline / direct ratio: %.3fx\n",
              pipelined_ms / synchronous_ms);
  std::printf("max output difference: %.9f\n", max_difference);

  CUDA_CHECK(cudaFree(d_output));
  CUDA_CHECK(cudaFree(d_input));
  return max_difference == 0.0f ? EXIT_SUCCESS : EXIT_FAILURE;
}
