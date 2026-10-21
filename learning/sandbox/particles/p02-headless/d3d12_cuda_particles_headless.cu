#define NOMINMAX
#include <cuda_runtime.h>

#include <d3d12.h>
#include <dxgi1_6.h>
#include <wrl/client.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

using Microsoft::WRL::ComPtr;

#define CUDA_CHECK(call)                                                        \
  do {                                                                          \
    const cudaError_t error = (call);                                            \
    if (error != cudaSuccess) {                                                  \
      std::fprintf(stderr, "%s failed: %s\n", #call,                          \
                   cudaGetErrorString(error));                                   \
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

// CUDA 和 HLSL 都把它解释为三个连续的 float4。
// position_mass.xyz = 位置，position_mass.w = 质量
// velocity_life.xyz = 速度，velocity_life.w = 剩余生命
struct ParticleGpu {
  float4 position_mass;
  float4 velocity_life;
  float4 color;
};

static_assert(sizeof(ParticleGpu) == 48,
              "ParticleGpu must match a 48-byte HLSL StructuredBuffer stride");

__global__ void integrate_particles(ParticleGpu* particles, int count,
                                    float dt, float3 gravity) {
  const int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index >= count) {
    return;
  }

  ParticleGpu particle = particles[index];

  // Semi-implicit Euler: first update velocity, then use the new velocity
  // to update position. Mass and color are intentionally left unchanged.
  particle.velocity_life.x += gravity.x * dt;
  particle.velocity_life.y += gravity.y * dt;
  particle.velocity_life.z += gravity.z * dt;

  particle.position_mass.x += particle.velocity_life.x * dt;
  particle.position_mass.y += particle.velocity_life.y * dt;
  particle.position_mass.z += particle.velocity_life.z * dt;
  particle.velocity_life.w -= dt;

  particles[index] = particle;
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
  const D3D12_RESOURCE_DESC description = make_buffer_desc(size, resource_flags);

  ComPtr<ID3D12Resource> buffer;
  HR_CHECK(device->CreateCommittedResource(
      &heap_properties, heap_flags, &description, initial_state, nullptr,
      IID_PPV_ARGS(&buffer)));
  return buffer;
}

ParticleGpu make_initial_particle(int index) {
  const float i = static_cast<float>(index);
  ParticleGpu particle{};
  particle.position_mass = make_float4(i * 0.01f, i * 0.02f, -i * 0.01f, 1.0f);
  particle.velocity_life = make_float4(1.0f, 2.0f, 3.0f, 10.0f);
  particle.color = make_float4(
      static_cast<float>(index % 7) / 6.0f,
      static_cast<float>(index % 11) / 10.0f, 0.75f, 1.0f);
  return particle;
}

ParticleGpu integrate_on_cpu(ParticleGpu particle, float dt, float3 gravity) {
  particle.velocity_life.x += gravity.x * dt;
  particle.velocity_life.y += gravity.y * dt;
  particle.velocity_life.z += gravity.z * dt;

  particle.position_mass.x += particle.velocity_life.x * dt;
  particle.position_mass.y += particle.velocity_life.y * dt;
  particle.position_mass.z += particle.velocity_life.z * dt;
  particle.velocity_life.w -= dt;
  return particle;
}

bool nearly_equal(float actual, float expected) {
  constexpr float absolute_epsilon = 1.0e-5f;
  constexpr float relative_epsilon = 1.0e-5f;
  const float difference = std::fabs(actual - expected);
  return difference <=
         absolute_epsilon + relative_epsilon * std::fabs(expected);
}

bool float4_equal(const float4& actual, const float4& expected) {
  return nearly_equal(actual.x, expected.x) &&
         nearly_equal(actual.y, expected.y) &&
         nearly_equal(actual.z, expected.z) &&
         nearly_equal(actual.w, expected.w);
}

bool particles_equal(const ParticleGpu& actual, const ParticleGpu& expected) {
  return float4_equal(actual.position_mass, expected.position_mass) &&
         float4_equal(actual.velocity_life, expected.velocity_life) &&
         float4_equal(actual.color, expected.color);
}

void print_particle(int index, const ParticleGpu& particle) {
  std::printf(
      "particle[%d]: pos=(%.6f, %.6f, %.6f), mass=%.1f, "
      "vel=(%.6f, %.6f, %.6f), life=%.6f, "
      "color=(%.3f, %.3f, %.3f, %.3f)\n",
      index, particle.position_mass.x, particle.position_mass.y,
      particle.position_mass.z, particle.position_mass.w,
      particle.velocity_life.x, particle.velocity_life.y,
      particle.velocity_life.z, particle.velocity_life.w, particle.color.x,
      particle.color.y, particle.color.z, particle.color.w);
}

int main() {
  constexpr int particle_count = 4096;
  constexpr UINT64 resource_bytes =
      static_cast<UINT64>(particle_count) * sizeof(ParticleGpu);
  constexpr float dt = 1.0f / 60.0f;
  const float3 gravity = make_float3(0.0f, -9.8f, 0.0f);

  // The shared D3D12 fence is a monotonically increasing timeline.
  constexpr UINT64 d3d12_uploaded = 1;
  constexpr UINT64 cuda_integrated = 2;
  constexpr UINT64 d3d12_readback_complete = 3;

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

  // DEFAULT heap: the allocation that CUDA and D3D12 genuinely share.
  // UPLOAD/READBACK heaps are only CPU staging resources for this test.
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

  std::vector<ParticleGpu> initial_particles(particle_count);
  for (int index = 0; index < particle_count; ++index) {
    initial_particles[index] = make_initial_particle(index);
  }

  void* upload_data = nullptr;
  const D3D12_RANGE no_cpu_reads{0, 0};
  HR_CHECK(upload_buffer->Map(0, &no_cpu_reads, &upload_data));
  std::memcpy(upload_data, initial_particles.data(), resource_bytes);
  const D3D12_RANGE upload_written{0, static_cast<SIZE_T>(resource_bytes)};
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

  // Export the committed D3D12 resource and import that same allocation into
  // CUDA. AllocationInfo.SizeInBytes may be larger than the useful data range.
  const D3D12_RESOURCE_DESC shared_description = shared_buffer->GetDesc();
  const D3D12_RESOURCE_ALLOCATION_INFO allocation =
      device->GetResourceAllocationInfo(0, 1, &shared_description);

  HANDLE memory_handle = nullptr;
  HR_CHECK(device->CreateSharedHandle(shared_buffer.Get(), nullptr, GENERIC_ALL,
                                      nullptr, &memory_handle));
  cudaExternalMemoryHandleDesc memory_description{};
  memory_description.type = cudaExternalMemoryHandleTypeD3D12Resource;
  memory_description.handle.win32.handle = memory_handle;
  memory_description.size = allocation.SizeInBytes;
  memory_description.flags = cudaExternalMemoryDedicated;

  cudaExternalMemory_t external_memory = nullptr;
  CUDA_CHECK(
      cudaImportExternalMemory(&external_memory, &memory_description));
  CloseHandle(memory_handle);

  cudaExternalMemoryBufferDesc buffer_description{};
  buffer_description.offset = 0;
  buffer_description.size = resource_bytes;
  ParticleGpu* cuda_particles = nullptr;
  CUDA_CHECK(cudaExternalMemoryGetMappedBuffer(
      reinterpret_cast<void**>(&cuda_particles), external_memory,
      &buffer_description));

  // One D3D12 timeline fence is exported as one CUDA external semaphore.
  ComPtr<ID3D12Fence> shared_fence;
  HR_CHECK(device->CreateFence(0, D3D12_FENCE_FLAG_SHARED,
                               IID_PPV_ARGS(&shared_fence)));
  HANDLE fence_handle = nullptr;
  HR_CHECK(device->CreateSharedHandle(shared_fence.Get(), nullptr, GENERIC_ALL,
                                      nullptr, &fence_handle));

  cudaExternalSemaphoreHandleDesc semaphore_description{};
  semaphore_description.type = cudaExternalSemaphoreHandleTypeD3D12Fence;
  semaphore_description.handle.win32.handle = fence_handle;
  cudaExternalSemaphore_t external_semaphore = nullptr;
  CUDA_CHECK(cudaImportExternalSemaphore(&external_semaphore,
                                         &semaphore_description));
  CloseHandle(fence_handle);

  cudaStream_t stream = nullptr;
  CUDA_CHECK(cudaStreamCreateWithFlags(&stream, cudaStreamNonBlocking));

  // Phase 1: D3D12 uploads the initial state and announces value 1.
  ID3D12CommandList* upload_lists[] = {upload_commands.Get()};
  queue->ExecuteCommandLists(1, upload_lists);
  HR_CHECK(queue->Signal(shared_fence.Get(), d3d12_uploaded));

  // Phase 2: CUDA's stream waits on value 1 without blocking the CPU, performs
  // one semi-implicit Euler step, then announces value 2.
  cudaExternalSemaphoreWaitParams wait_parameters{};
  wait_parameters.params.fence.value = d3d12_uploaded;
  CUDA_CHECK(cudaWaitExternalSemaphoresAsync(
      &external_semaphore, &wait_parameters, 1, stream));

  constexpr int threads = 256;
  const int blocks = (particle_count + threads - 1) / threads;
  integrate_particles<<<blocks, threads, 0, stream>>>(
      cuda_particles, particle_count, dt, gravity);
  CUDA_CHECK(cudaGetLastError());

  cudaExternalSemaphoreSignalParams signal_parameters{};
  signal_parameters.params.fence.value = cuda_integrated;
  CUDA_CHECK(cudaSignalExternalSemaphoresAsync(
      &external_semaphore, &signal_parameters, 1, stream));

  // Phase 3: the D3D12 queue waits on value 2. This orders the following
  // barrier/copy on the GPU queue; ID3D12CommandQueue::Wait does not park CPU.
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
                                      shared_buffer.Get(), 0, resource_bytes);

  D3D12_RESOURCE_BARRIER back_to_common = to_copy_source;
  back_to_common.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_SOURCE;
  back_to_common.Transition.StateAfter = D3D12_RESOURCE_STATE_COMMON;
  readback_commands->ResourceBarrier(1, &back_to_common);
  HR_CHECK(readback_commands->Close());

  HR_CHECK(queue->Wait(shared_fence.Get(), cuda_integrated));
  ID3D12CommandList* readback_lists[] = {readback_commands.Get()};
  queue->ExecuteCommandLists(1, readback_lists);
  HR_CHECK(queue->Signal(shared_fence.Get(), d3d12_readback_complete));

  // This is the only CPU wait. A real renderer would normally wait for frame
  // reuse/presentation, not insert a wait between CUDA simulation and drawing.
  HANDLE final_event = CreateEvent(nullptr, FALSE, FALSE, nullptr);
  if (final_event == nullptr) {
    std::fprintf(stderr, "CreateEvent failed: %lu\n", GetLastError());
    return EXIT_FAILURE;
  }
  int final_cpu_blocking_waits = 0;
  if (shared_fence->GetCompletedValue() < d3d12_readback_complete) {
    HR_CHECK(shared_fence->SetEventOnCompletion(d3d12_readback_complete,
                                                final_event));
    const DWORD wait_result = WaitForSingleObject(final_event, INFINITE);
    if (wait_result != WAIT_OBJECT_0) {
      std::fprintf(stderr, "WaitForSingleObject failed: %lu\n",
                   GetLastError());
      CloseHandle(final_event);
      return EXIT_FAILURE;
    }
    ++final_cpu_blocking_waits;
  }
  CloseHandle(final_event);

  ParticleGpu* cpu_particles = nullptr;
  const D3D12_RANGE read_range{0, static_cast<SIZE_T>(resource_bytes)};
  HR_CHECK(readback_buffer->Map(
      0, &read_range, reinterpret_cast<void**>(&cpu_particles)));

  int mismatches = 0;
  for (int index = 0; index < particle_count; ++index) {
    const ParticleGpu expected =
        integrate_on_cpu(initial_particles[index], dt, gravity);
    if (!particles_equal(cpu_particles[index], expected)) {
      if (mismatches < 3) {
        std::printf("mismatch at particle %d\n", index);
        print_particle(index, cpu_particles[index]);
        std::printf("expected:\n");
        print_particle(index, expected);
      }
      ++mismatches;
    }
  }

  std::printf("particle stride: %zu bytes, count: %d, shared bytes: %llu\n",
              sizeof(ParticleGpu), particle_count,
              static_cast<unsigned long long>(resource_bytes));
  std::printf(
      "timeline: D3D12 upload/signal %llu -> CUDA wait/integrate/signal "
      "%llu -> D3D12 wait/readback/signal %llu\n",
      static_cast<unsigned long long>(d3d12_uploaded),
      static_cast<unsigned long long>(cuda_integrated),
      static_cast<unsigned long long>(d3d12_readback_complete));
  std::printf("final fence value: %llu\n",
              static_cast<unsigned long long>(
                  shared_fence->GetCompletedValue()));
  const int sample_indices[] = {0, 1, particle_count - 1};
  for (int index : sample_indices) {
    print_particle(index, cpu_particles[index]);
  }
  std::printf("intermediate CPU waits: 0\n");
  std::printf("final CPU blocking waits: %d\n", final_cpu_blocking_waits);
  std::printf("mismatches: %d\n", mismatches);

  const D3D12_RANGE no_cpu_writes{0, 0};
  readback_buffer->Unmap(0, &no_cpu_writes);

  CUDA_CHECK(cudaDestroyExternalSemaphore(external_semaphore));
  CUDA_CHECK(cudaStreamDestroy(stream));
  CUDA_CHECK(cudaFree(cuda_particles));
  CUDA_CHECK(cudaDestroyExternalMemory(external_memory));
  return mismatches == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
