#define NOMINMAX
#include <cuda_runtime.h>

#include <d3d12.h>
#include <dxgi1_6.h>
#include <wrl/client.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

using Microsoft::WRL::ComPtr;

#define CUDA_CHECK(call)                                                        \
  do {                                                                          \
    const cudaError_t error = (call);                                            \
    if (error != cudaSuccess) {                                                  \
      std::fprintf(stderr, "%s failed: %s\n", #call, cudaGetErrorString(error)); \
      std::exit(EXIT_FAILURE);                                                   \
    }                                                                            \
  } while (0)

#define HR_CHECK(call)                                                          \
  do {                                                                          \
    const HRESULT hr_check_result = (call);                                      \
    if (FAILED(hr_check_result)) {                                               \
      std::fprintf(stderr, "%s failed: HRESULT 0x%08lx\n", #call,             \
                   static_cast<unsigned long>(hr_check_result));                 \
      std::exit(EXIT_FAILURE);                                                   \
    }                                                                            \
  } while (0)

struct Particle {
  float x;
  float y;
  float z;
  float w;
};

__global__ void write_particles(Particle* particles, int count) {
  const int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index < count) {
    particles[index] = {static_cast<float>(index),
                        static_cast<float>(index * 2),
                        -static_cast<float>(index), 1.0f};
  }
}

D3D12_RESOURCE_DESC make_buffer_desc(UINT64 size,
                                     D3D12_RESOURCE_FLAGS flags) {
  D3D12_RESOURCE_DESC description{};
  description.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
  description.Width = size;
  description.Height = 1;
  description.DepthOrArraySize = 1;
  description.MipLevels = 1;
  description.Format = DXGI_FORMAT_UNKNOWN;
  description.SampleDesc.Count = 1;
  description.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
  description.Flags = flags;
  return description;
}

ComPtr<IDXGIAdapter1> find_cuda_adapter(IDXGIFactory6* factory,
                                        const cudaDeviceProp& properties) {
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
    if (std::memcmp(properties.luid, &description.AdapterLuid,
                    sizeof(properties.luid)) == 0) {
      std::printf("matched adapter: %ls\n", description.Description);
      return adapter;
    }
  }

  std::fprintf(stderr, "No DXGI adapter matches the CUDA device LUID.\n");
  std::exit(EXIT_FAILURE);
}

int main() {
  constexpr int particle_count = 256;
  constexpr UINT64 resource_bytes = particle_count * sizeof(Particle);

  CUDA_CHECK(cudaSetDevice(0));
  cudaDeviceProp cuda_properties{};
  CUDA_CHECK(cudaGetDeviceProperties(&cuda_properties, 0));

  ComPtr<IDXGIFactory6> factory;
  HR_CHECK(CreateDXGIFactory2(0, IID_PPV_ARGS(&factory)));
  ComPtr<IDXGIAdapter1> adapter =
      find_cuda_adapter(factory.Get(), cuda_properties);

  ComPtr<ID3D12Device> device;
  HR_CHECK(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0,
                             IID_PPV_ARGS(&device)));

  D3D12_COMMAND_QUEUE_DESC queue_description{};
  queue_description.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
  ComPtr<ID3D12CommandQueue> queue;
  HR_CHECK(device->CreateCommandQueue(&queue_description,
                                       IID_PPV_ARGS(&queue)));

  D3D12_HEAP_PROPERTIES default_heap{};
  default_heap.Type = D3D12_HEAP_TYPE_DEFAULT;
  const D3D12_RESOURCE_DESC shared_description = make_buffer_desc(
      resource_bytes, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);

  ComPtr<ID3D12Resource> shared_buffer;
  HR_CHECK(device->CreateCommittedResource(
      &default_heap, D3D12_HEAP_FLAG_SHARED, &shared_description,
      D3D12_RESOURCE_STATE_COMMON, nullptr,
      IID_PPV_ARGS(&shared_buffer)));

  const D3D12_RESOURCE_ALLOCATION_INFO allocation =
      device->GetResourceAllocationInfo(0, 1, &shared_description);

  HANDLE shared_handle = nullptr;
  HR_CHECK(device->CreateSharedHandle(shared_buffer.Get(), nullptr,
                                      GENERIC_ALL, nullptr,
                                      &shared_handle));

  cudaExternalMemoryHandleDesc memory_handle_description{};
  memory_handle_description.type =
      cudaExternalMemoryHandleTypeD3D12Resource;
  memory_handle_description.handle.win32.handle = shared_handle;
  memory_handle_description.size = allocation.SizeInBytes;
  memory_handle_description.flags = cudaExternalMemoryDedicated;

  cudaExternalMemory_t external_memory = nullptr;
  CUDA_CHECK(cudaImportExternalMemory(&external_memory,
                                      &memory_handle_description));
  CloseHandle(shared_handle);

  cudaExternalMemoryBufferDesc buffer_description{};
  buffer_description.offset = 0;
  buffer_description.size = resource_bytes;

  Particle* cuda_particles = nullptr;
  CUDA_CHECK(cudaExternalMemoryGetMappedBuffer(
      reinterpret_cast<void**>(&cuda_particles), external_memory,
      &buffer_description));

  constexpr int threads = 128;
  const int blocks = (particle_count + threads - 1) / threads;
  write_particles<<<blocks, threads>>>(cuda_particles, particle_count);
  CUDA_CHECK(cudaGetLastError());
  CUDA_CHECK(cudaDeviceSynchronize());

  D3D12_HEAP_PROPERTIES readback_heap{};
  readback_heap.Type = D3D12_HEAP_TYPE_READBACK;
  const D3D12_RESOURCE_DESC readback_description =
      make_buffer_desc(resource_bytes, D3D12_RESOURCE_FLAG_NONE);

  ComPtr<ID3D12Resource> readback_buffer;
  HR_CHECK(device->CreateCommittedResource(
      &readback_heap, D3D12_HEAP_FLAG_NONE, &readback_description,
      D3D12_RESOURCE_STATE_COPY_DEST, nullptr,
      IID_PPV_ARGS(&readback_buffer)));

  ComPtr<ID3D12CommandAllocator> allocator;
  HR_CHECK(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,
                                           IID_PPV_ARGS(&allocator)));
  ComPtr<ID3D12GraphicsCommandList> command_list;
  HR_CHECK(device->CreateCommandList(
      0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator.Get(), nullptr,
      IID_PPV_ARGS(&command_list)));

  D3D12_RESOURCE_BARRIER to_copy_source{};
  to_copy_source.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
  to_copy_source.Transition.pResource = shared_buffer.Get();
  to_copy_source.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
  to_copy_source.Transition.StateBefore = D3D12_RESOURCE_STATE_COMMON;
  to_copy_source.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
  command_list->ResourceBarrier(1, &to_copy_source);
  command_list->CopyBufferRegion(readback_buffer.Get(), 0,
                                 shared_buffer.Get(), 0, resource_bytes);

  D3D12_RESOURCE_BARRIER back_to_common = to_copy_source;
  back_to_common.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_SOURCE;
  back_to_common.Transition.StateAfter = D3D12_RESOURCE_STATE_COMMON;
  command_list->ResourceBarrier(1, &back_to_common);
  HR_CHECK(command_list->Close());

  ID3D12CommandList* command_lists[] = {command_list.Get()};
  queue->ExecuteCommandLists(1, command_lists);

  ComPtr<ID3D12Fence> fence;
  HR_CHECK(device->CreateFence(0, D3D12_FENCE_FLAG_NONE,
                               IID_PPV_ARGS(&fence)));
  HR_CHECK(queue->Signal(fence.Get(), 1));

  HANDLE fence_event = CreateEvent(nullptr, FALSE, FALSE, nullptr);
  if (fence_event == nullptr) {
    std::fprintf(stderr, "CreateEvent failed: %lu\n", GetLastError());
    return EXIT_FAILURE;
  }
  if (fence->GetCompletedValue() < 1) {
    HR_CHECK(fence->SetEventOnCompletion(1, fence_event));
    WaitForSingleObject(fence_event, INFINITE);
  }
  CloseHandle(fence_event);

  const D3D12_RANGE read_range{0, static_cast<SIZE_T>(resource_bytes)};
  Particle* cpu_particles = nullptr;
  HR_CHECK(readback_buffer->Map(
      0, &read_range, reinterpret_cast<void**>(&cpu_particles)));

  int mismatches = 0;
  for (int i = 0; i < particle_count; ++i) {
    const Particle expected{static_cast<float>(i),
                            static_cast<float>(i * 2),
                            -static_cast<float>(i), 1.0f};
    const Particle actual = cpu_particles[i];
    if (actual.x != expected.x || actual.y != expected.y ||
        actual.z != expected.z || actual.w != expected.w) {
      ++mismatches;
    }
  }

  std::printf("D3D12 resource bytes: %llu\n",
              static_cast<unsigned long long>(resource_bytes));
  std::printf("D3D12 allocation bytes imported by CUDA: %llu\n",
              static_cast<unsigned long long>(allocation.SizeInBytes));
  for (int i : {0, 1, particle_count - 1}) {
    const Particle value = cpu_particles[i];
    std::printf("particle[%d] = (%.1f, %.1f, %.1f, %.1f)\n", i,
                value.x, value.y, value.z, value.w);
  }
  std::printf("mismatches: %d\n", mismatches);

  const D3D12_RANGE no_cpu_writes{0, 0};
  readback_buffer->Unmap(0, &no_cpu_writes);

  CUDA_CHECK(cudaFree(cuda_particles));
  CUDA_CHECK(cudaDestroyExternalMemory(external_memory));
  return mismatches == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
