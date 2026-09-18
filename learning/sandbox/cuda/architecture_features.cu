#include <cuda.h>
#include <cuda_runtime.h>

#include <cstdio>
#include <cstdlib>

#ifdef _MSC_VER
#pragma comment(lib, "cuda.lib")
#endif

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

int main() {
  int device = 0;
  cudaDeviceProp properties{};
  CUDA_CHECK(cudaGetDevice(&device));
  CUDA_CHECK(cudaGetDeviceProperties(&properties, device));

  int cluster_launch = 0;
  CUDA_CHECK(cudaDeviceGetAttribute(&cluster_launch, cudaDevAttrClusterLaunch,
                                    device));

  CU_CHECK(cuInit(0));
  CUdevice driver_device{};
  CU_CHECK(cuDeviceGet(&driver_device, device));

  int tensor_map_access = 0;
  CU_CHECK(cuDeviceGetAttribute(&tensor_map_access,
                                CU_DEVICE_ATTRIBUTE_TENSOR_MAP_ACCESS_SUPPORTED,
                                driver_device));

  std::printf("Device: %s\n", properties.name);
  std::printf("Compute capability: %d.%d\n", properties.major,
              properties.minor);
  std::printf("SM count: %d\n", properties.multiProcessorCount);
  std::printf("Cluster launch: %s\n", cluster_launch ? "yes" : "no");
  std::printf("Tensor map / TMA access: %s\n",
              tensor_map_access ? "yes" : "no");
}
