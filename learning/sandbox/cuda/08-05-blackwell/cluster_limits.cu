#include <cuda_runtime.h>

#include <cstdio>
#include <cstdlib>

#define CUDA_CHECK(call)                                                        \
  do {                                                                          \
    cudaError_t error = (call);                                                  \
    if (error != cudaSuccess) {                                                  \
      std::fprintf(stderr, "%s failed: %s\n", #call, cudaGetErrorString(error)); \
      std::exit(EXIT_FAILURE);                                                   \
    }                                                                            \
  } while (0)

__global__ void dynamic_cluster_kernel(int) {}

__global__ void __cluster_dims__(10, 1, 1) static_cluster_10_kernel(int) {}

cudaLaunchConfig_t make_config(int block_size, size_t dynamic_smem) {
  cudaLaunchConfig_t config{};
  config.gridDim = dim3(256, 1, 1);
  config.blockDim = dim3(block_size, 1, 1);
  config.dynamicSmemBytes = dynamic_smem;
  return config;
}

void print_potential(const char* label, int block_size, size_t dynamic_smem) {
  cudaLaunchConfig_t config = make_config(block_size, dynamic_smem);
  int max_cluster_size = 0;
  const cudaError_t error = cudaOccupancyMaxPotentialClusterSize(
      &max_cluster_size, dynamic_cluster_kernel, &config);
  if (error == cudaSuccess) {
    std::printf("%-18s block=%4d, smem=%6zu B -> max blocks/cluster=%d\n",
                label, block_size, dynamic_smem, max_cluster_size);
  } else {
    std::printf("%-18s block=%4d, smem=%6zu B -> %s\n", label,
                block_size, dynamic_smem, cudaGetErrorString(error));
  }
}

void print_active_clusters(int cluster_size, int block_size,
                           size_t dynamic_smem) {
  cudaLaunchAttribute attribute{};
  attribute.id = cudaLaunchAttributeClusterDimension;
  attribute.val.clusterDim.x = cluster_size;
  attribute.val.clusterDim.y = 1;
  attribute.val.clusterDim.z = 1;

  cudaLaunchConfig_t config = make_config(block_size, dynamic_smem);
  config.gridDim = dim3(cluster_size * 20, 1, 1);
  config.attrs = &attribute;
  config.numAttrs = 1;

  int active_clusters = 0;
  const cudaError_t error = cudaOccupancyMaxActiveClusters(
      &active_clusters, dynamic_cluster_kernel, &config);
  if (error == cudaSuccess) {
    std::printf("  cluster=%2d, block=%4d, smem=%6zu B -> active clusters=%d\n",
                cluster_size, block_size, dynamic_smem, active_clusters);
  } else {
    std::printf("  cluster=%2d, block=%4d, smem=%6zu B -> %s\n",
                cluster_size, block_size, dynamic_smem,
                cudaGetErrorString(error));
  }
}

void try_launch(int cluster_size) {
  cudaLaunchAttribute attribute{};
  attribute.id = cudaLaunchAttributeClusterDimension;
  attribute.val.clusterDim.x = cluster_size;
  attribute.val.clusterDim.y = 1;
  attribute.val.clusterDim.z = 1;

  cudaLaunchConfig_t config = make_config(32, 0);
  config.gridDim = dim3(cluster_size * 2, 1, 1);
  config.attrs = &attribute;
  config.numAttrs = 1;

  cudaError_t error = cudaLaunchKernelEx(&config, dynamic_cluster_kernel, 0);
  if (error == cudaSuccess) {
    error = cudaDeviceSynchronize();
  }
  std::printf("  launch cluster=%2d -> %s\n", cluster_size,
              cudaGetErrorString(error));
  cudaGetLastError();
}

void try_static_launch(const char* label) {
  static_cluster_10_kernel<<<10, 32>>>(0);
  cudaError_t error = cudaGetLastError();
  if (error == cudaSuccess) {
    error = cudaDeviceSynchronize();
  }
  std::printf("  %-31s -> %s\n", label, cudaGetErrorString(error));
  cudaGetLastError();
}

int main() {
  int device = 0;
  cudaDeviceProp properties{};
  CUDA_CHECK(cudaGetDevice(&device));
  CUDA_CHECK(cudaGetDeviceProperties(&properties, device));
  std::printf("device: %s, CC %d.%d, SMs=%d\n", properties.name,
              properties.major, properties.minor,
              properties.multiProcessorCount);

  std::puts("\nStatic __cluster_dims__(10, 1, 1):");
  try_static_launch("without non-portable opt-in");
  CUDA_CHECK(cudaFuncSetAttribute(
      static_cluster_10_kernel,
      cudaFuncAttributeNonPortableClusterSizeAllowed, 1));
  try_static_launch("with non-portable opt-in");

  std::puts("\nPortable queries:");
  print_potential("light", 32, 0);
  print_potential("more threads", 256, 0);
  print_potential("heavy threads", 1024, 0);
  print_potential("shared memory", 256, 32 * 1024);

  CUDA_CHECK(cudaFuncSetAttribute(
      dynamic_cluster_kernel,
      cudaFuncAttributeNonPortableClusterSizeAllowed, 1));

  std::puts("\nNon-portable queries enabled:");
  print_potential("light", 32, 0);
  print_potential("more threads", 256, 0);
  print_potential("heavy threads", 1024, 0);
  print_potential("shared memory", 256, 32 * 1024);

  std::puts("\nDevice-wide active clusters for selected configurations:");
  for (int cluster_size : {1, 2, 4, 8, 9, 10, 11, 16, 32}) {
    print_active_clusters(cluster_size, 32, 0);
  }
  std::puts("\nResource pressure at cluster size 4:");
  print_active_clusters(4, 32, 0);
  print_active_clusters(4, 256, 0);
  print_active_clusters(4, 1024, 0);
  print_active_clusters(4, 256, 32 * 1024);

  std::puts("\nActual non-portable launches:");
  try_launch(8);
  try_launch(10);
  try_launch(11);

  return EXIT_SUCCESS;
}
