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
    const cudaError_t error = (call);                                          \
    if (error != cudaSuccess) {                                                 \
      std::fprintf(stderr, "%s failed: %s\n", #call, cudaGetErrorString(error)); \
      std::exit(EXIT_FAILURE);                                                  \
    }                                                                           \
  } while (0)

#define HR_CHECK(call)                                                          \
  do {                                                                          \
    const HRESULT hr_check_result = (call);                                     \
    if (FAILED(hr_check_result)) {                                              \
      std::fprintf(stderr, "%s failed: HRESULT 0x%08lx\n", #call,             \
                   static_cast<unsigned long>(hr_check_result));              \
      std::exit(EXIT_FAILURE);                                                  \
    }                                                                           \
  } while (0)

__global__ void write_texture(cudaSurfaceObject_t surface, int width,
                              int height) {
  const int x = blockIdx.x * blockDim.x + threadIdx.x;
  const int y = blockIdx.y * blockDim.y + threadIdx.y;
  if (x < width && y < height) {
    const float4 value = {static_cast<float>(x), static_cast<float>(y),
                          static_cast<float>(x + y), 1.0f};
    // surf2Dwrite 的 x 坐标是字节偏移，不是像素索引。
    surf2Dwrite(value, surface, x * static_cast<int>(sizeof(float4)), y);
  }
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

D3D12_RESOURCE_DESC make_texture_desc(UINT width, UINT height) {
  D3D12_RESOURCE_DESC description{};
  description.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
  description.Width = width;
  description.Height = height;
  description.DepthOrArraySize = 1;
  description.MipLevels = 1;
  description.Format = DXGI_FORMAT_R32G32B32A32_FLOAT;
  description.SampleDesc.Count = 1;
  description.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
  description.Flags = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
  return description;
}

ComPtr<ID3D12Resource> make_readback_buffer(ID3D12Device* device,
                                            UINT64 bytes) {
  D3D12_HEAP_PROPERTIES heap{};
  heap.Type = D3D12_HEAP_TYPE_READBACK;
  D3D12_RESOURCE_DESC description{};
  description.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
  description.Width = bytes;
  description.Height = 1;
  description.DepthOrArraySize = 1;
  description.MipLevels = 1;
  description.Format = DXGI_FORMAT_UNKNOWN;
  description.SampleDesc.Count = 1;
  description.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
  ComPtr<ID3D12Resource> buffer;
  HR_CHECK(device->CreateCommittedResource(
      &heap, D3D12_HEAP_FLAG_NONE, &description,
      D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&buffer)));
  return buffer;
}

int main() {
  constexpr UINT width = 17;
  constexpr UINT height = 9;
  constexpr UINT64 d3d12_ready = 1;
  constexpr UINT64 readback_ready = 2;

  CUDA_CHECK(cudaSetDevice(0));
  cudaDeviceProp properties{};
  CUDA_CHECK(cudaGetDeviceProperties(&properties, 0));

  ComPtr<IDXGIFactory6> factory;
  HR_CHECK(CreateDXGIFactory2(0, IID_PPV_ARGS(&factory)));
  ComPtr<IDXGIAdapter1> adapter = find_cuda_adapter(factory.Get(), properties);

  ComPtr<ID3D12Device> device;
  HR_CHECK(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0,
                             IID_PPV_ARGS(&device)));

  D3D12_COMMAND_QUEUE_DESC queue_desc{};
  queue_desc.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
  ComPtr<ID3D12CommandQueue> queue;
  HR_CHECK(device->CreateCommandQueue(&queue_desc, IID_PPV_ARGS(&queue)));

  const D3D12_RESOURCE_DESC texture_desc = make_texture_desc(width, height);
  D3D12_HEAP_PROPERTIES default_heap{};
  default_heap.Type = D3D12_HEAP_TYPE_DEFAULT;
  ComPtr<ID3D12Resource> texture;
  HR_CHECK(device->CreateCommittedResource(
      &default_heap, D3D12_HEAP_FLAG_SHARED, &texture_desc,
      D3D12_RESOURCE_STATE_COMMON, nullptr, IID_PPV_ARGS(&texture)));

  const D3D12_RESOURCE_ALLOCATION_INFO allocation =
      device->GetResourceAllocationInfo(0, 1, &texture_desc);
  HANDLE memory_handle = nullptr;
  HR_CHECK(device->CreateSharedHandle(texture.Get(), nullptr, GENERIC_ALL,
                                      nullptr, &memory_handle));

  cudaExternalMemoryHandleDesc memory_desc{};
  memory_desc.type = cudaExternalMemoryHandleTypeD3D12Resource;
  memory_desc.handle.win32.handle = memory_handle;
  memory_desc.size = allocation.SizeInBytes;
  memory_desc.flags = cudaExternalMemoryDedicated;
  cudaExternalMemory_t external_memory = nullptr;
  CUDA_CHECK(cudaImportExternalMemory(&external_memory, &memory_desc));
  CloseHandle(memory_handle);

  cudaExternalMemoryMipmappedArrayDesc array_desc{};
  array_desc.offset = 0;
  array_desc.formatDesc = cudaCreateChannelDesc<float4>();
  array_desc.extent = make_cudaExtent(width, height, 0);
  array_desc.flags = cudaArraySurfaceLoadStore;
  array_desc.numLevels = 1;
  cudaMipmappedArray_t mipmapped_array = nullptr;
  CUDA_CHECK(cudaExternalMemoryGetMappedMipmappedArray(
      &mipmapped_array, external_memory, &array_desc));

  cudaArray_t level_zero = nullptr;
  CUDA_CHECK(cudaGetMipmappedArrayLevel(&level_zero, mipmapped_array, 0));
  cudaResourceDesc surface_desc{};
  surface_desc.resType = cudaResourceTypeArray;
  surface_desc.res.array.array = level_zero;
  cudaSurfaceObject_t surface = 0;
  CUDA_CHECK(cudaCreateSurfaceObject(&surface, &surface_desc));

  ComPtr<ID3D12Fence> fence;
  HR_CHECK(device->CreateFence(0, D3D12_FENCE_FLAG_SHARED,
                               IID_PPV_ARGS(&fence)));
  HANDLE fence_handle = nullptr;
  HR_CHECK(device->CreateSharedHandle(fence.Get(), nullptr, GENERIC_ALL,
                                      nullptr, &fence_handle));
  cudaExternalSemaphoreHandleDesc semaphore_desc{};
  semaphore_desc.type = cudaExternalSemaphoreHandleTypeD3D12Fence;
  semaphore_desc.handle.win32.handle = fence_handle;
  cudaExternalSemaphore_t external_semaphore = nullptr;
  CUDA_CHECK(cudaImportExternalSemaphore(&external_semaphore, &semaphore_desc));
  CloseHandle(fence_handle);

  cudaStream_t stream = nullptr;
  CUDA_CHECK(cudaStreamCreateWithFlags(&stream, cudaStreamNonBlocking));
  const dim3 threads(8, 8);
  const dim3 blocks((width + threads.x - 1) / threads.x,
                    (height + threads.y - 1) / threads.y);
  write_texture<<<blocks, threads, 0, stream>>>(surface, width, height);
  CUDA_CHECK(cudaGetLastError());
  cudaExternalSemaphoreSignalParams signal_cuda{};
  signal_cuda.params.fence.value = d3d12_ready;
  CUDA_CHECK(cudaSignalExternalSemaphoresAsync(
      &external_semaphore, &signal_cuda, 1, stream));

  D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};
  UINT num_rows = 0;
  UINT64 row_size = 0;
  UINT64 total_bytes = 0;
  device->GetCopyableFootprints(&texture_desc, 0, 1, 0, &footprint,
                                &num_rows, &row_size, &total_bytes);
  ComPtr<ID3D12Resource> readback =
      make_readback_buffer(device.Get(), total_bytes);

  ComPtr<ID3D12CommandAllocator> allocator;
  HR_CHECK(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,
                                           IID_PPV_ARGS(&allocator)));
  ComPtr<ID3D12GraphicsCommandList> commands;
  HR_CHECK(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT,
                                      allocator.Get(), nullptr,
                                      IID_PPV_ARGS(&commands)));
  D3D12_RESOURCE_BARRIER to_copy_source{};
  to_copy_source.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
  to_copy_source.Transition.pResource = texture.Get();
  to_copy_source.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
  to_copy_source.Transition.StateBefore = D3D12_RESOURCE_STATE_COMMON;
  to_copy_source.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
  commands->ResourceBarrier(1, &to_copy_source);
  D3D12_TEXTURE_COPY_LOCATION source{};
  source.pResource = texture.Get();
  source.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
  source.SubresourceIndex = 0;
  D3D12_TEXTURE_COPY_LOCATION destination{};
  destination.pResource = readback.Get();
  destination.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
  destination.PlacedFootprint = footprint;
  commands->CopyTextureRegion(&destination, 0, 0, 0, &source, nullptr);
  D3D12_RESOURCE_BARRIER back_to_common = to_copy_source;
  back_to_common.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_SOURCE;
  back_to_common.Transition.StateAfter = D3D12_RESOURCE_STATE_COMMON;
  commands->ResourceBarrier(1, &back_to_common);
  HR_CHECK(commands->Close());

  HR_CHECK(queue->Wait(fence.Get(), d3d12_ready));
  ID3D12CommandList* lists[] = {commands.Get()};
  queue->ExecuteCommandLists(1, lists);
  HR_CHECK(queue->Signal(fence.Get(), readback_ready));

  HANDLE event = CreateEvent(nullptr, FALSE, FALSE, nullptr);
  if (event == nullptr) {
    std::fprintf(stderr, "CreateEvent failed: %lu\n", GetLastError());
    return EXIT_FAILURE;
  }
  if (fence->GetCompletedValue() < readback_ready) {
    HR_CHECK(fence->SetEventOnCompletion(readback_ready, event));
    WaitForSingleObject(event, INFINITE);
  }
  CloseHandle(event);

  void* mapped = nullptr;
  const D3D12_RANGE read_range{0, static_cast<SIZE_T>(total_bytes)};
  HR_CHECK(readback->Map(0, &read_range, &mapped));
  int mismatches = 0;
  auto* bytes = static_cast<unsigned char*>(mapped);
  for (UINT y = 0; y < height; ++y) {
    const auto* row = reinterpret_cast<const float4*>(
        bytes + y * footprint.Footprint.RowPitch);
    for (UINT x = 0; x < width; ++x) {
      const float4 expected = {static_cast<float>(x), static_cast<float>(y),
                               static_cast<float>(x + y), 1.0f};
      const float4 actual = row[x];
      if (actual.x != expected.x || actual.y != expected.y ||
          actual.z != expected.z || actual.w != expected.w) {
        ++mismatches;
      }
    }
  }

  const auto* row0 = reinterpret_cast<const float4*>(bytes);
  const auto* row_last = reinterpret_cast<const float4*>(
      bytes + (height - 1) * footprint.Footprint.RowPitch);
  std::printf("texture: %ux%u RGBA32F\n", width, height);
  std::printf("logical row bytes: %llu, D3D12 RowPitch: %u\n",
              static_cast<unsigned long long>(row_size),
              footprint.Footprint.RowPitch);
  std::printf("copy rows: %u, total readback bytes: %llu\n", num_rows,
              static_cast<unsigned long long>(total_bytes));
  std::printf("pixel(0,0) = (%.1f, %.1f, %.1f, %.1f)\n", row0[0].x,
              row0[0].y, row0[0].z, row0[0].w);
  std::printf("pixel(%u,%u) = (%.1f, %.1f, %.1f, %.1f)\n", width - 1,
              height - 1, row_last[width - 1].x, row_last[width - 1].y,
              row_last[width - 1].z, row_last[width - 1].w);
  std::printf("intermediate CPU waits: 0\n");
  std::printf("mismatches: %d\n", mismatches);

  const D3D12_RANGE no_cpu_writes{0, 0};
  readback->Unmap(0, &no_cpu_writes);
  CUDA_CHECK(cudaDestroySurfaceObject(surface));
  CUDA_CHECK(cudaFreeMipmappedArray(mipmapped_array));
  CUDA_CHECK(cudaDestroyExternalSemaphore(external_semaphore));
  CUDA_CHECK(cudaStreamDestroy(stream));
  CUDA_CHECK(cudaDestroyExternalMemory(external_memory));
  return mismatches == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
