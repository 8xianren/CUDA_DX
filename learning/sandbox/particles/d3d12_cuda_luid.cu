#include <cuda_runtime.h>

#include <d3d12.h>
#include <dxgi1_6.h>
#include <wrl/client.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

using Microsoft::WRL::ComPtr;

#define CUDA_CHECK(call)                                                        \
  do {                                                                          \
    const cudaError_t error = (call);                                            \
    if (error != cudaSuccess) {                                                  \
      std::fprintf(stderr, "%s failed: %s\n", #call, cudaGetErrorString(error)); \
      std::exit(EXIT_FAILURE);                                                   \
    }                                                                            \
  } while (0)

#define HR_CHECK(call)                                                     \
  do {                                                                     \
    const HRESULT hr_check_result = (call);                                \
    if (FAILED(hr_check_result)) {                                          \
      std::fprintf(stderr, "%s failed: HRESULT 0x%08lx\n", #call,        \
                   static_cast<unsigned long>(hr_check_result));           \
      std::exit(EXIT_FAILURE);                                             \
    }                                                                      \
  } while (0)

struct DxgiAdapterInfo {
  ComPtr<IDXGIAdapter1> adapter;
  DXGI_ADAPTER_DESC1 description{};
  bool supports_d3d12 = false;
};

void print_luid(const LUID& luid) {
  std::printf("%08lx:%08lx", static_cast<unsigned long>(luid.HighPart),
              static_cast<unsigned long>(luid.LowPart));
}

int main() {
  static_assert(sizeof(LUID) == 8, "Windows LUID must contain 8 bytes");

  ComPtr<IDXGIFactory6> factory;
  HR_CHECK(CreateDXGIFactory2(0, IID_PPV_ARGS(&factory)));

  std::vector<DxgiAdapterInfo> adapters;
  for (UINT index = 0;; ++index) {
    ComPtr<IDXGIAdapter1> adapter;
    const HRESULT result = factory->EnumAdapterByGpuPreference(
        index, DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,
        IID_PPV_ARGS(&adapter));
    if (result == DXGI_ERROR_NOT_FOUND) {
      break;
    }
    HR_CHECK(result);

    DXGI_ADAPTER_DESC1 description{};
    HR_CHECK(adapter->GetDesc1(&description));
    if ((description.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0) {
      continue;
    }

    ComPtr<ID3D12Device> d3d12_device;
    const bool supports_d3d12 = SUCCEEDED(D3D12CreateDevice(
        adapter.Get(), D3D_FEATURE_LEVEL_11_0,
        IID_PPV_ARGS(&d3d12_device)));
    adapters.push_back({adapter, description, supports_d3d12});
  }

  std::puts("DXGI hardware adapters:");
  for (size_t i = 0; i < adapters.size(); ++i) {
    std::printf("  [%zu] %ls, LUID=", i,
                adapters[i].description.Description);
    print_luid(adapters[i].description.AdapterLuid);
    std::printf(", D3D12=%s\n",
                adapters[i].supports_d3d12 ? "yes" : "no");
  }

  int cuda_device_count = 0;
  CUDA_CHECK(cudaGetDeviceCount(&cuda_device_count));
  std::puts("CUDA devices:");

  int total_matches = 0;
  for (int device = 0; device < cuda_device_count; ++device) {
    cudaDeviceProp properties{};
    CUDA_CHECK(cudaGetDeviceProperties(&properties, device));

    LUID cuda_luid{};
    std::memcpy(&cuda_luid, properties.luid, sizeof(cuda_luid));
    std::printf("  [%d] %s, LUID=", device, properties.name);
    print_luid(cuda_luid);
    std::printf(", nodeMask=0x%x\n", properties.luidDeviceNodeMask);

    for (size_t adapter_index = 0; adapter_index < adapters.size();
         ++adapter_index) {
      if (std::memcmp(properties.luid,
                      &adapters[adapter_index].description.AdapterLuid,
                      sizeof(properties.luid)) == 0) {
        std::printf("       MATCH -> DXGI adapter [%zu] %ls\n",
                    adapter_index,
                    adapters[adapter_index].description.Description);
        ++total_matches;
      }
    }
  }

  std::printf("total CUDA/DXGI LUID matches: %d\n", total_matches);
  return total_matches > 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
