#define NOMINMAX
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

__global__ void update_particles(Particle* particles, int count) {
  const int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index < count) {
    Particle value = particles[index];
    value.x += 1000.0f;
    value.y *= 10.0f;
    value.z = -value.z;
    value.w = 2.0f;
    particles[index] = value;
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

ComPtr<ID3D12Resource> create_buffer(ID3D12Device* device,
                                     D3D12_HEAP_TYPE heap_type,
                                     D3D12_HEAP_FLAGS heap_flags,
                                     UINT64 size,
                                     D3D12_RESOURCE_FLAGS resource_flags,
                                     D3D12_RESOURCE_STATES initial_state) {
  D3D12_HEAP_PROPERTIES heap_properties{};
  heap_properties.Type = heap_type;
  const D3D12_RESOURCE_DESC description =
      make_buffer_desc(size, resource_flags);

  ComPtr<ID3D12Resource> buffer;
  HR_CHECK(device->CreateCommittedResource(
      &heap_properties, heap_flags, &description, initial_state, nullptr,
      IID_PPV_ARGS(&buffer)));
  return buffer;
}

int main() {
  constexpr int particle_count = 256;
  constexpr UINT64 resource_bytes = particle_count * sizeof(Particle);
  constexpr UINT64 d3d12_ready = 1;
  constexpr UINT64 cuda_ready = 2;
  constexpr UINT64 readback_ready = 3;

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

  ComPtr<ID3D12Resource> shared_buffer = create_buffer(
      device.Get(), D3D12_HEAP_TYPE_DEFAULT, D3D12_HEAP_FLAG_SHARED,
      resource_bytes, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS,
      D3D12_RESOURCE_STATE_COPY_DEST);
  ComPtr<ID3D12Resource> upload_buffer = create_buffer(
      device.Get(), D3D12_HEAP_TYPE_UPLOAD, D3D12_HEAP_FLAG_NONE,
      resource_bytes, D3D12_RESOURCE_FLAG_NONE,
      D3D12_RESOURCE_STATE_GENERIC_READ);
  ComPtr<ID3D12Resource> readback_buffer = create_buffer(
      device.Get(), D3D12_HEAP_TYPE_READBACK, D3D12_HEAP_FLAG_NONE,
      resource_bytes, D3D12_RESOURCE_FLAG_NONE,
      D3D12_RESOURCE_STATE_COPY_DEST);

  std::vector<Particle> initial_particles(particle_count);
  for (int i = 0; i < particle_count; ++i) {
    initial_particles[i] = {static_cast<float>(i),
                            static_cast<float>(i * 2),
                            -static_cast<float>(i), 1.0f};
  }

  void* upload_data = nullptr;
  const D3D12_RANGE no_cpu_reads{0, 0};
  HR_CHECK(upload_buffer->Map(0, &no_cpu_reads, &upload_data));
  std::memcpy(upload_data, initial_particles.data(), resource_bytes);
  const D3D12_RANGE upload_written{0,
                                   static_cast<SIZE_T>(resource_bytes)};
  upload_buffer->Unmap(0, &upload_written);

  ComPtr<ID3D12CommandAllocator> upload_allocator;
  HR_CHECK(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,
                                           IID_PPV_ARGS(&upload_allocator)));
  ComPtr<ID3D12GraphicsCommandList> upload_commands;
  HR_CHECK(device->CreateCommandList(
      0, D3D12_COMMAND_LIST_TYPE_DIRECT, upload_allocator.Get(), nullptr,
      IID_PPV_ARGS(&upload_commands)));
  upload_commands->CopyBufferRegion(shared_buffer.Get(), 0,
                                    upload_buffer.Get(), 0, resource_bytes);

  D3D12_RESOURCE_BARRIER upload_to_common{};
  upload_to_common.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
  upload_to_common.Transition.pResource = shared_buffer.Get();
  upload_to_common.Transition.Subresource =
      D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
  upload_to_common.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_DEST;
  upload_to_common.Transition.StateAfter = D3D12_RESOURCE_STATE_COMMON;
  upload_commands->ResourceBarrier(1, &upload_to_common);
  HR_CHECK(upload_commands->Close());

  const D3D12_RESOURCE_DESC shared_description =
      shared_buffer->GetDesc();
  const D3D12_RESOURCE_ALLOCATION_INFO allocation =
      device->GetResourceAllocationInfo(0, 1, &shared_description);

  HANDLE memory_handle = nullptr;
  HR_CHECK(device->CreateSharedHandle(shared_buffer.Get(), nullptr,
                                      GENERIC_ALL, nullptr,
                                      &memory_handle));
  cudaExternalMemoryHandleDesc memory_description{};
  memory_description.type = cudaExternalMemoryHandleTypeD3D12Resource;
  memory_description.handle.win32.handle = memory_handle;
  memory_description.size = allocation.SizeInBytes;
  memory_description.flags = cudaExternalMemoryDedicated;

  cudaExternalMemory_t external_memory = nullptr;
  CUDA_CHECK(cudaImportExternalMemory(&external_memory,
                                      &memory_description));
  CloseHandle(memory_handle);

  cudaExternalMemoryBufferDesc buffer_description{};
  buffer_description.offset = 0;
  buffer_description.size = resource_bytes;
  Particle* cuda_particles = nullptr;
  CUDA_CHECK(cudaExternalMemoryGetMappedBuffer(
      reinterpret_cast<void**>(&cuda_particles), external_memory,
      &buffer_description));

  ComPtr<ID3D12Fence> shared_fence;
  HR_CHECK(device->CreateFence(0, D3D12_FENCE_FLAG_SHARED,
                               IID_PPV_ARGS(&shared_fence)));
  HANDLE fence_handle = nullptr;
  HR_CHECK(device->CreateSharedHandle(shared_fence.Get(), nullptr,
                                      GENERIC_ALL, nullptr,
                                      &fence_handle));

  cudaExternalSemaphoreHandleDesc semaphore_description{};
  semaphore_description.type =
      cudaExternalSemaphoreHandleTypeD3D12Fence;
  semaphore_description.handle.win32.handle = fence_handle;
  cudaExternalSemaphore_t external_semaphore = nullptr;
  CUDA_CHECK(cudaImportExternalSemaphore(&external_semaphore,
                                         &semaphore_description));
  CloseHandle(fence_handle);

  cudaStream_t stream = nullptr;
  CUDA_CHECK(cudaStreamCreateWithFlags(&stream, cudaStreamNonBlocking));

  ID3D12CommandList* upload_lists[] = {upload_commands.Get()};
  queue->ExecuteCommandLists(1, upload_lists);
  HR_CHECK(queue->Signal(shared_fence.Get(), d3d12_ready));

  cudaExternalSemaphoreWaitParams wait_parameters{};
  wait_parameters.params.fence.value = d3d12_ready;
  CUDA_CHECK(cudaWaitExternalSemaphoresAsync(
      &external_semaphore, &wait_parameters, 1, stream));

  constexpr int threads = 128;
  const int blocks = (particle_count + threads - 1) / threads;
  update_particles<<<blocks, threads, 0, stream>>>(cuda_particles,
                                                   particle_count);
  CUDA_CHECK(cudaGetLastError());

  cudaExternalSemaphoreSignalParams signal_parameters{};
  signal_parameters.params.fence.value = cuda_ready;
  CUDA_CHECK(cudaSignalExternalSemaphoresAsync(
      &external_semaphore, &signal_parameters, 1, stream));

  ComPtr<ID3D12CommandAllocator> readback_allocator;
  HR_CHECK(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,
                                           IID_PPV_ARGS(&readback_allocator)));
  ComPtr<ID3D12GraphicsCommandList> readback_commands;
  HR_CHECK(device->CreateCommandList(
      0, D3D12_COMMAND_LIST_TYPE_DIRECT, readback_allocator.Get(), nullptr,
      IID_PPV_ARGS(&readback_commands)));

  D3D12_RESOURCE_BARRIER to_copy_source{};
  to_copy_source.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
  to_copy_source.Transition.pResource = shared_buffer.Get();
  to_copy_source.Transition.Subresource =
      D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
  to_copy_source.Transition.StateBefore = D3D12_RESOURCE_STATE_COMMON;
  to_copy_source.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
  readback_commands->ResourceBarrier(1, &to_copy_source);
  readback_commands->CopyBufferRegion(readback_buffer.Get(), 0,
                                      shared_buffer.Get(), 0,
                                      resource_bytes);

  D3D12_RESOURCE_BARRIER back_to_common = to_copy_source;
  back_to_common.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_SOURCE;
  back_to_common.Transition.StateAfter = D3D12_RESOURCE_STATE_COMMON;
  readback_commands->ResourceBarrier(1, &back_to_common);
  HR_CHECK(readback_commands->Close());

  HR_CHECK(queue->Wait(shared_fence.Get(), cuda_ready));
  ID3D12CommandList* readback_lists[] = {readback_commands.Get()};
  queue->ExecuteCommandLists(1, readback_lists);
  HR_CHECK(queue->Signal(shared_fence.Get(), readback_ready));

  HANDLE final_event = CreateEvent(nullptr, FALSE, FALSE, nullptr);
  if (final_event == nullptr) {
    std::fprintf(stderr, "CreateEvent failed: %lu\n", GetLastError());
    return EXIT_FAILURE;
  }
  if (shared_fence->GetCompletedValue() < readback_ready) {
    HR_CHECK(shared_fence->SetEventOnCompletion(readback_ready, final_event));
    WaitForSingleObject(final_event, INFINITE);
  }
  CloseHandle(final_event);

  Particle* cpu_particles = nullptr;
  const D3D12_RANGE read_range{0, static_cast<SIZE_T>(resource_bytes)};
  HR_CHECK(readback_buffer->Map(
      0, &read_range, reinterpret_cast<void**>(&cpu_particles)));

  int mismatches = 0;
  for (int i = 0; i < particle_count; ++i) {
    const Particle expected{1000.0f + static_cast<float>(i),
                            static_cast<float>(i * 20),
                            static_cast<float>(i), 2.0f};
    const Particle actual = cpu_particles[i];
    if (actual.x != expected.x || actual.y != expected.y ||
        actual.z != expected.z || actual.w != expected.w) {
      ++mismatches;
    }
  }

  std::printf("timeline: D3D12 signal=%llu -> CUDA signal=%llu -> "
              "D3D12 signal=%llu\n",
              static_cast<unsigned long long>(d3d12_ready),
              static_cast<unsigned long long>(cuda_ready),
              static_cast<unsigned long long>(readback_ready));
  std::printf("final fence value: %llu\n",
              static_cast<unsigned long long>(
                  shared_fence->GetCompletedValue()));
  for (int i : {0, 1, particle_count - 1}) {
    const Particle value = cpu_particles[i];
    std::printf("particle[%d] = (%.1f, %.1f, %.1f, %.1f)\n", i,
                value.x, value.y, value.z, value.w);
  }
  std::printf("intermediate CPU waits: 0\n");
  std::printf("mismatches: %d\n", mismatches);

  const D3D12_RANGE no_cpu_writes{0, 0};
  readback_buffer->Unmap(0, &no_cpu_writes);

  CUDA_CHECK(cudaDestroyExternalSemaphore(external_semaphore));
  CUDA_CHECK(cudaStreamDestroy(stream));
  CUDA_CHECK(cudaFree(cuda_particles));
  CUDA_CHECK(cudaDestroyExternalMemory(external_memory));
  return mismatches == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
