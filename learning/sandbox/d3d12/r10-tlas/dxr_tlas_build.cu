// R.10：最小 TLAS 构建验收。
//
// 这不是 RayGen/TraceRay 演示；本程序只验证真实 DXR 资源关系：
//   一个 BLAS Result
//       -> 两个 D3D12_RAYTRACING_INSTANCE_DESC
//       -> GPU 可读 Instance Desc Buffer
//       -> TLAS Result
//
// 两个实例引用同一个 BLAS，但 Transform / InstanceID 不同。
// 因此它验证的是“局部几何复用 + 场景实例层”的 API 和生命周期，
// 不把“TLAS 构建成功”误报成已经执行 DispatchRays。
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d12.h>
#include <d3d12sdklayers.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <algorithm>

#pragma comment(lib, "d3d12.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "dxguid.lib")
using Microsoft::WRL::ComPtr;

struct Vertex { float x, y, z; };
struct Context {
  ComPtr<IDXGIFactory6> factory;
  ComPtr<ID3D12Device5> device;
  ComPtr<ID3D12InfoQueue> info_queue;
  ComPtr<ID3D12CommandQueue> queue;
  ComPtr<ID3D12CommandAllocator> allocator;
  ComPtr<ID3D12GraphicsCommandList4> list;
  ComPtr<ID3D12Fence> fence;
  HANDLE fence_event = nullptr;
  UINT64 fence_value = 0;
};

void fail(const char* what, HRESULT hr) {
  std::fprintf(stderr, "%s failed: 0x%08lx\n", what, static_cast<unsigned long>(hr));
  std::exit(EXIT_FAILURE);
}
void check(HRESULT hr, const char* what) { if (FAILED(hr)) fail(what, hr); }
UINT64 align_up(UINT64 x, UINT64 a) { return (x + a - 1) / a * a; }
D3D12_HEAP_PROPERTIES heap(D3D12_HEAP_TYPE type) {
  D3D12_HEAP_PROPERTIES p{}; p.Type = type;
  p.CPUPageProperty = D3D12_CPU_PAGE_PROPERTY_UNKNOWN;
  p.MemoryPoolPreference = D3D12_MEMORY_POOL_UNKNOWN;
  p.CreationNodeMask = 1; p.VisibleNodeMask = 1; return p;
}
D3D12_RESOURCE_DESC buffer_desc(UINT64 bytes, D3D12_RESOURCE_FLAGS flags = D3D12_RESOURCE_FLAG_NONE) {
  D3D12_RESOURCE_DESC d{}; d.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
  d.Width = bytes; d.Height = 1; d.DepthOrArraySize = 1; d.MipLevels = 1;
  d.Format = DXGI_FORMAT_UNKNOWN; d.SampleDesc.Count = 1;
  d.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR; d.Flags = flags; return d;
}
ComPtr<IDXGIAdapter1> choose_adapter(IDXGIFactory6* f) {
  for (UINT i = 0;; ++i) {
    ComPtr<IDXGIAdapter1> a;
    HRESULT hr = f->EnumAdapterByGpuPreference(i, DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,
                                                IID_PPV_ARGS(&a));
    if (hr == DXGI_ERROR_NOT_FOUND) break;
    if (FAILED(hr)) continue;
    DXGI_ADAPTER_DESC1 d{}; a->GetDesc1(&d);
    if (d.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) continue;
    if (SUCCEEDED(D3D12CreateDevice(a.Get(), D3D_FEATURE_LEVEL_12_0,
                                    __uuidof(ID3D12Device), nullptr))) return a;
  }
  return {};
}
ComPtr<ID3D12Resource> upload_buffer(ID3D12Device* dev, const void* data, UINT64 bytes,
                                     D3D12_GPU_VIRTUAL_ADDRESS* gpu) {
  // Upload Heap 保持 GENERIC_READ：TLAS 构建只读 instance 描述，
  // 不需要把它当作 UAV，也不需要给它写 ResourceBarrier。
  ComPtr<ID3D12Resource> r; auto d = buffer_desc(bytes); auto hp = heap(D3D12_HEAP_TYPE_UPLOAD);
  check(dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &d,
    D3D12_RESOURCE_STATE_GENERIC_READ, nullptr, IID_PPV_ARGS(&r)),
    "Create upload buffer");
  void* mapped = nullptr; D3D12_RANGE read{0, 0};
  check(r->Map(0, &read, &mapped), "Map upload buffer");
  std::memcpy(mapped, data, static_cast<size_t>(bytes));
  r->Unmap(0, nullptr); *gpu = r->GetGPUVirtualAddress(); return r;
}
void make_context(Context& c) {
  ComPtr<ID3D12Debug> debug;
  if (SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)))) {
    debug->EnableDebugLayer(); std::puts("D3D12 Debug Layer: enabled");
  } else std::puts("D3D12 Debug Layer: unavailable");
  check(CreateDXGIFactory2(0, IID_PPV_ARGS(&c.factory)), "CreateDXGIFactory2");
  auto a = choose_adapter(c.factory.Get());
  if (!a) { std::fputs("No D3D12 hardware adapter\n", stderr); std::exit(EXIT_FAILURE); }
  DXGI_ADAPTER_DESC1 ad{}; a->GetDesc1(&ad);
  std::wprintf(L"adapter: %ls\n", ad.Description);
  check(D3D12CreateDevice(a.Get(), D3D_FEATURE_LEVEL_12_0, IID_PPV_ARGS(&c.device)),
        "D3D12CreateDevice(ID3D12Device5)");
  c.device.As(&c.info_queue);
  D3D12_FEATURE_DATA_D3D12_OPTIONS5 o5{};
  check(c.device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS5, &o5, sizeof(o5)),
        "Check OPTIONS5");
  std::printf("raytracing tier: %d\n", static_cast<int>(o5.RaytracingTier));
  if (o5.RaytracingTier == D3D12_RAYTRACING_TIER_NOT_SUPPORTED) {
    std::fputs("DXR unsupported\n", stderr); std::exit(EXIT_FAILURE);
  }
  D3D12_COMMAND_QUEUE_DESC q{}; q.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
  check(c.device->CreateCommandQueue(&q, IID_PPV_ARGS(&c.queue)), "CreateCommandQueue");
  check(c.device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,
                                         IID_PPV_ARGS(&c.allocator)), "CreateCommandAllocator");
  check(c.device->CreateCommandList1(0, D3D12_COMMAND_LIST_TYPE_DIRECT,
                                     D3D12_COMMAND_LIST_FLAG_NONE, IID_PPV_ARGS(&c.list)),
        "CreateCommandList4");
  check(c.device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&c.fence)),
        "CreateFence");
  c.fence_event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (!c.fence_event) { std::fputs("CreateEvent failed\n", stderr); std::exit(EXIT_FAILURE); }
}
void wait_gpu(Context& c) {
  ++c.fence_value;
  check(c.queue->Signal(c.fence.Get(), c.fence_value), "Signal fence");
  if (c.fence->GetCompletedValue() < c.fence_value) {
    check(c.fence->SetEventOnCompletion(c.fence_value, c.fence_event),
          "SetEventOnCompletion");
    WaitForSingleObject(c.fence_event, INFINITE);
  }
}
void validate_info_queue(Context& c) {
  if (!c.info_queue) { std::puts("InfoQueue validation: unavailable"); return; }
  UINT64 errors = 0, warnings = 0;
  const UINT64 count = c.info_queue->GetNumStoredMessagesAllowedByRetrievalFilter();
  for (UINT64 i = 0; i < count; ++i) {
    SIZE_T bytes = 0; c.info_queue->GetMessage(i, nullptr, &bytes);
    auto* m = static_cast<D3D12_MESSAGE*>(std::malloc(bytes));
    if (!m) { std::fputs("InfoQueue allocation failed\n", stderr); std::exit(EXIT_FAILURE); }
    if (SUCCEEDED(c.info_queue->GetMessage(i, m, &bytes))) {
      if (m->Severity == D3D12_MESSAGE_SEVERITY_ERROR ||
          m->Severity == D3D12_MESSAGE_SEVERITY_CORRUPTION) ++errors;
      else if (m->Severity == D3D12_MESSAGE_SEVERITY_WARNING) ++warnings;
      if (m->Severity <= D3D12_MESSAGE_SEVERITY_WARNING)
        std::fprintf(stderr, "InfoQueue id=%d severity=%d: %s\n", static_cast<int>(m->ID),
                     static_cast<int>(m->Severity), m->pDescription);
    }
    std::free(m);
  }
  std::printf("InfoQueue: errors=%llu warnings=%llu stored=%llu\n",
    static_cast<unsigned long long>(errors), static_cast<unsigned long long>(warnings),
    static_cast<unsigned long long>(count));
  if (errors || warnings) { std::fputs("InfoQueue validation failed\n", stderr); std::exit(EXIT_FAILURE); }
}

int main() {
  std::puts("R.10 TLAS build / two instances share one BLAS / no DispatchRays");
  Context c{}; make_context(c);

  // ---------- 1. 先构建 R.9 同样的局部三角形 BLAS ----------
  const Vertex vertices[3] = {{0, 1, 0}, {-1, -1, 0}, {1, -1, 0}};
  const uint32_t indices[3] = {0, 1, 2};
  D3D12_GPU_VIRTUAL_ADDRESS vb_gpu = 0, ib_gpu = 0;
  auto vb = upload_buffer(c.device.Get(), vertices, sizeof(vertices), &vb_gpu);
  auto ib = upload_buffer(c.device.Get(), indices, sizeof(indices), &ib_gpu);

  D3D12_RAYTRACING_GEOMETRY_TRIANGLES_DESC tri{};
  tri.VertexBuffer.StartAddress = vb_gpu; tri.VertexBuffer.StrideInBytes = sizeof(Vertex);
  tri.VertexCount = 3; tri.VertexFormat = DXGI_FORMAT_R32G32B32_FLOAT;
  tri.IndexBuffer = ib_gpu; tri.IndexCount = 3; tri.IndexFormat = DXGI_FORMAT_R32_UINT;
  D3D12_RAYTRACING_GEOMETRY_DESC geom{};
  geom.Type = D3D12_RAYTRACING_GEOMETRY_TYPE_TRIANGLES;
  geom.Flags = D3D12_RAYTRACING_GEOMETRY_FLAG_OPAQUE; geom.Triangles = tri;

  D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS blas_in{};
  blas_in.Type = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL;
  blas_in.DescsLayout = D3D12_ELEMENTS_LAYOUT_ARRAY; blas_in.NumDescs = 1;
  blas_in.pGeometryDescs = &geom;
  blas_in.Flags = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE;
  D3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO blas_info{};
  c.device->GetRaytracingAccelerationStructurePrebuildInfo(&blas_in, &blas_info);
  if (!blas_info.ResultDataMaxSizeInBytes || !blas_info.ScratchDataSizeInBytes) {
    std::fputs("invalid BLAS prebuild info\n", stderr); return EXIT_FAILURE;
  }
  UINT64 blas_result_bytes = align_up(blas_info.ResultDataMaxSizeInBytes,
                                      D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BYTE_ALIGNMENT);
  UINT64 blas_scratch_bytes = align_up(blas_info.ScratchDataSizeInBytes,
                                       D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BYTE_ALIGNMENT);
  ComPtr<ID3D12Resource> blas_result, blas_scratch;
  auto hp = heap(D3D12_HEAP_TYPE_DEFAULT);
  auto brd = buffer_desc(blas_result_bytes, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
  auto bsd = buffer_desc(blas_scratch_bytes, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
  check(c.device->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &brd,
    D3D12_RESOURCE_STATE_RAYTRACING_ACCELERATION_STRUCTURE, nullptr, IID_PPV_ARGS(&blas_result)),
    "Create BLAS result");
  check(c.device->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &bsd,
    D3D12_RESOURCE_STATE_COMMON, nullptr, IID_PPV_ARGS(&blas_scratch)),
    "Create BLAS scratch");

  check(c.list->Reset(c.allocator.Get(), nullptr), "Reset command list for BLAS");
  D3D12_RESOURCE_BARRIER b0{}; b0.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
  b0.Transition.pResource = blas_scratch.Get();
  b0.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
  b0.Transition.StateBefore = D3D12_RESOURCE_STATE_COMMON;
  b0.Transition.StateAfter = D3D12_RESOURCE_STATE_UNORDERED_ACCESS;
  c.list->ResourceBarrier(1, &b0);
  D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC blas_build{};
  blas_build.Inputs = blas_in;
  blas_build.DestAccelerationStructureData = blas_result->GetGPUVirtualAddress();
  blas_build.ScratchAccelerationStructureData = blas_scratch->GetGPUVirtualAddress();
  c.list->BuildRaytracingAccelerationStructure(&blas_build, 0, nullptr);
  check(c.list->Close(), "Close BLAS command list");
  ID3D12CommandList* lists[] = {c.list.Get()}; c.queue->ExecuteCommandLists(1, lists);
  wait_gpu(c);

  // ---------- 2. 构造两个实例：同一 BLAS，不同变换和 InstanceID ----------
  D3D12_RAYTRACING_INSTANCE_DESC instances[2]{};
  // Transform 是 3x4 仿射矩阵：前三列是线性变换，最后一列是平移。
  instances[0].Transform[0][0] = 1; instances[0].Transform[1][1] = 1; instances[0].Transform[2][2] = 1;
  instances[0].InstanceID = 10; instances[0].InstanceMask = 0x01;
  instances[0].InstanceContributionToHitGroupIndex = 0;
  instances[0].AccelerationStructure = blas_result->GetGPUVirtualAddress();

  instances[1].Transform[0][0] = 1; instances[1].Transform[1][1] = 1; instances[1].Transform[2][2] = 1;
  instances[1].Transform[0][3] = 3.0f; // 第二个实例在 X 方向平移 3
  instances[1].InstanceID = 20; instances[1].InstanceMask = 0x01;
  instances[1].InstanceContributionToHitGroupIndex = 1;
  instances[1].AccelerationStructure = blas_result->GetGPUVirtualAddress();

  constexpr UINT64 instance_alignment = D3D12_RAYTRACING_INSTANCE_DESCS_BYTE_ALIGNMENT;
  const UINT64 instance_bytes = align_up(sizeof(instances), instance_alignment);
  D3D12_GPU_VIRTUAL_ADDRESS instance_gpu = 0;
  auto instance_buffer = upload_buffer(c.device.Get(), instances, instance_bytes, &instance_gpu);

  D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS tlas_in{};
  tlas_in.Type = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL;
  tlas_in.DescsLayout = D3D12_ELEMENTS_LAYOUT_ARRAY; tlas_in.NumDescs = 2;
  tlas_in.InstanceDescs = instance_gpu;
  tlas_in.Flags = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE;
  D3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO tlas_info{};
  c.device->GetRaytracingAccelerationStructurePrebuildInfo(&tlas_in, &tlas_info);
  std::printf("BLAS result=%llu scratch=%llu; TLAS result=%llu scratch=%llu; instances=%llu bytes\n",
    static_cast<unsigned long long>(blas_result_bytes), static_cast<unsigned long long>(blas_scratch_bytes),
    static_cast<unsigned long long>(tlas_info.ResultDataMaxSizeInBytes),
    static_cast<unsigned long long>(tlas_info.ScratchDataSizeInBytes),
    static_cast<unsigned long long>(instance_bytes));
  if (!tlas_info.ResultDataMaxSizeInBytes || !tlas_info.ScratchDataSizeInBytes) {
    std::fputs("invalid TLAS prebuild info\n", stderr); return EXIT_FAILURE;
  }
  UINT64 tlas_result_bytes = align_up(tlas_info.ResultDataMaxSizeInBytes,
                                      D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BYTE_ALIGNMENT);
  UINT64 tlas_scratch_bytes = align_up(tlas_info.ScratchDataSizeInBytes,
                                       D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BYTE_ALIGNMENT);
  ComPtr<ID3D12Resource> tlas_result, tlas_scratch;
  auto trd = buffer_desc(tlas_result_bytes, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
  auto tsd = buffer_desc(tlas_scratch_bytes, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
  check(c.device->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &trd,
    D3D12_RESOURCE_STATE_RAYTRACING_ACCELERATION_STRUCTURE, nullptr, IID_PPV_ARGS(&tlas_result)),
    "Create TLAS result");
  check(c.device->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &tsd,
    D3D12_RESOURCE_STATE_COMMON, nullptr, IID_PPV_ARGS(&tlas_scratch)),
    "Create TLAS scratch");

  check(c.list->Reset(c.allocator.Get(), nullptr), "Reset command list for TLAS");
  D3D12_RESOURCE_BARRIER t0{}; t0.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
  t0.Transition.pResource = tlas_scratch.Get();
  t0.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
  t0.Transition.StateBefore = D3D12_RESOURCE_STATE_COMMON;
  t0.Transition.StateAfter = D3D12_RESOURCE_STATE_UNORDERED_ACCESS;
  c.list->ResourceBarrier(1, &t0);
  D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC tlas_build{};
  tlas_build.Inputs = tlas_in;
  tlas_build.DestAccelerationStructureData = tlas_result->GetGPUVirtualAddress();
  tlas_build.ScratchAccelerationStructureData = tlas_scratch->GetGPUVirtualAddress();
  c.list->BuildRaytracingAccelerationStructure(&tlas_build, 0, nullptr);
  check(c.list->Close(), "Close TLAS command list");
  lists[0] = c.list.Get(); c.queue->ExecuteCommandLists(1, lists); wait_gpu(c);
  if (c.fence->GetCompletedValue() < c.fence_value) {
    std::fputs("TLAS GPU completion failed\n", stderr); return EXIT_FAILURE;
  }
  validate_info_queue(c);
  std::printf("instances: ID=%u x=0, ID=%u x=3, shared_blas=0x%llx\n",
    instances[0].InstanceID, instances[1].InstanceID,
    static_cast<unsigned long long>(blas_result->GetGPUVirtualAddress()));
  std::printf("TLAS result_gpu=0x%llx\n",
    static_cast<unsigned long long>(tlas_result->GetGPUVirtualAddress()));
  std::puts("TLAS build: PASS");
  CloseHandle(c.fence_event); return EXIT_SUCCESS;
}
