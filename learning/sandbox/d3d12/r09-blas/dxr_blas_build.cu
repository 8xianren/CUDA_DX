// R.9：最小三角形 BLAS 构建验收。
// 本程序不创建 TLAS、不创建 State Object、不调用 DispatchRays。
// 它只验证：三角形 Buffer -> Geometry Desc -> Prebuild Info -> Scratch/Result
// -> BuildRaytracingAccelerationStructure -> Fence 完成。
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

constexpr UINT64 kASAlignment = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BYTE_ALIGNMENT;
constexpr UINT64 kScratchAlignment = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BYTE_ALIGNMENT;

struct Vertex { float x,y,z; };
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
  D3D12_HEAP_PROPERTIES p{}; p.Type=type; p.CPUPageProperty=D3D12_CPU_PAGE_PROPERTY_UNKNOWN;
  p.MemoryPoolPreference=D3D12_MEMORY_POOL_UNKNOWN; p.CreationNodeMask=1; p.VisibleNodeMask=1; return p;
}
D3D12_RESOURCE_DESC buffer_desc(UINT64 bytes, D3D12_RESOURCE_FLAGS flags=D3D12_RESOURCE_FLAG_NONE) {
  D3D12_RESOURCE_DESC d{}; d.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER; d.Width=bytes;
  d.Height=1; d.DepthOrArraySize=1; d.MipLevels=1; d.Format=DXGI_FORMAT_UNKNOWN;
  d.SampleDesc.Count=1; d.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR; d.Flags=flags; return d;
}
ComPtr<IDXGIAdapter1> adapter(IDXGIFactory6* f) {
  for (UINT i=0;;++i) {
    ComPtr<IDXGIAdapter1> a; HRESULT hr=f->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&a));
    if (hr==DXGI_ERROR_NOT_FOUND) break; if (FAILED(hr)) continue;
    DXGI_ADAPTER_DESC1 d{}; a->GetDesc1(&d); if(d.Flags&DXGI_ADAPTER_FLAG_SOFTWARE) continue;
    if(SUCCEEDED(D3D12CreateDevice(a.Get(),D3D_FEATURE_LEVEL_12_0,__uuidof(ID3D12Device),nullptr))) return a;
  }
  return {};
}
ComPtr<ID3D12Resource> upload_buffer(ID3D12Device* dev, const void* data, UINT64 bytes, D3D12_GPU_VIRTUAL_ADDRESS* gpu) {
  ComPtr<ID3D12Resource> r; auto d=buffer_desc(bytes); auto hp=heap(D3D12_HEAP_TYPE_UPLOAD);
  check(dev->CreateCommittedResource(&hp,D3D12_HEAP_FLAG_NONE,&d,
    D3D12_RESOURCE_STATE_GENERIC_READ,nullptr,IID_PPV_ARGS(&r)),"Create upload buffer");
  void* mapped=nullptr; D3D12_RANGE read{0,0}; check(r->Map(0,&read,&mapped),"Map upload buffer");
  std::memcpy(mapped,data,static_cast<size_t>(bytes)); r->Unmap(0,nullptr); *gpu=r->GetGPUVirtualAddress(); return r;
}
void wait_gpu(Context& c) {
  ++c.fence_value; check(c.queue->Signal(c.fence.Get(),c.fence_value),"Signal fence");
  if(c.fence->GetCompletedValue()<c.fence_value){ check(c.fence->SetEventOnCompletion(c.fence_value,c.fence_event),"SetEventOnCompletion"); WaitForSingleObject(c.fence_event,INFINITE); }
}
void make_context(Context& c) {
  ComPtr<ID3D12Debug> debug;
  if (SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)))) {
    debug->EnableDebugLayer();
    std::puts("D3D12 Debug Layer: enabled");
  } else {
    std::puts("D3D12 Debug Layer: unavailable");
  }
  check(CreateDXGIFactory2(0,IID_PPV_ARGS(&c.factory)),"CreateDXGIFactory2");
  auto a=adapter(c.factory.Get()); if(!a){std::fprintf(stderr,"No D3D12 hardware adapter\n");std::exit(EXIT_FAILURE);}
  DXGI_ADAPTER_DESC1 ad{}; a->GetDesc1(&ad); std::wprintf(L"adapter: %ls\n",ad.Description);
  check(D3D12CreateDevice(a.Get(),D3D_FEATURE_LEVEL_12_0,IID_PPV_ARGS(&c.device)),"D3D12CreateDevice(ID3D12Device5)");
  if (SUCCEEDED(c.device.As(&c.info_queue))) std::puts("D3D12 InfoQueue: attached");
  D3D12_FEATURE_DATA_D3D12_OPTIONS5 o5{}; check(c.device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS5,&o5,sizeof(o5)),"Check OPTIONS5");
  std::printf("raytracing tier: %d\n",static_cast<int>(o5.RaytracingTier));
  if(o5.RaytracingTier==D3D12_RAYTRACING_TIER_NOT_SUPPORTED){std::fprintf(stderr,"DXR unsupported\n");std::exit(EXIT_FAILURE);}
  D3D12_COMMAND_QUEUE_DESC q{}; q.Type=D3D12_COMMAND_LIST_TYPE_DIRECT;
  check(c.device->CreateCommandQueue(&q,IID_PPV_ARGS(&c.queue)),"CreateCommandQueue");
  check(c.device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&c.allocator)),"CreateCommandAllocator");
  check(c.device->CreateCommandList1(0,D3D12_COMMAND_LIST_TYPE_DIRECT,D3D12_COMMAND_LIST_FLAG_NONE,IID_PPV_ARGS(&c.list)),"CreateCommandList4");
  check(c.device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&c.fence)),"CreateFence");
  c.fence_event=CreateEventW(nullptr,FALSE,FALSE,nullptr); if(!c.fence_event){std::fprintf(stderr,"CreateEvent failed\n");std::exit(EXIT_FAILURE);}
}
void validate_info_queue(Context& c) {
  if (!c.info_queue) { std::puts("InfoQueue validation: unavailable"); return; }
  UINT64 errors=0,warnings=0;
  const UINT64 count=c.info_queue->GetNumStoredMessagesAllowedByRetrievalFilter();
  for(UINT64 i=0;i<count;++i){
    SIZE_T bytes=0; c.info_queue->GetMessage(i,nullptr,&bytes);
    auto* message=static_cast<D3D12_MESSAGE*>(std::malloc(bytes));
    if(!message){std::fprintf(stderr,"InfoQueue allocation failed\n");std::exit(EXIT_FAILURE);}
    if(SUCCEEDED(c.info_queue->GetMessage(i,message,&bytes))){
      if(message->Severity==D3D12_MESSAGE_SEVERITY_CORRUPTION||message->Severity==D3D12_MESSAGE_SEVERITY_ERROR) ++errors;
      else if(message->Severity==D3D12_MESSAGE_SEVERITY_WARNING) ++warnings;
      if(message->Severity==D3D12_MESSAGE_SEVERITY_CORRUPTION||message->Severity==D3D12_MESSAGE_SEVERITY_ERROR||message->Severity==D3D12_MESSAGE_SEVERITY_WARNING)
        std::fprintf(stderr,"InfoQueue message id=%d severity=%d: %s\n",static_cast<int>(message->ID),static_cast<int>(message->Severity),message->pDescription);
    }
    std::free(message);
  }
  std::printf("InfoQueue: errors=%llu warnings=%llu stored=%llu\n",
    static_cast<unsigned long long>(errors),static_cast<unsigned long long>(warnings),static_cast<unsigned long long>(count));
  if(errors||warnings) { std::fprintf(stderr,"InfoQueue validation failed\n"); std::exit(EXIT_FAILURE); }
}
int main(){
  std::puts("R.9 BLAS build / one triangle / no TLAS or DispatchRays");
  Context c{}; make_context(c);
  const Vertex vertices[3]={{0,1,0},{-1,-1,0},{1,-1,0}};
  const uint32_t indices[3]={0,1,2};
  D3D12_GPU_VIRTUAL_ADDRESS vb_addr=0, ib_addr=0;
  auto vb=upload_buffer(c.device.Get(),vertices,sizeof(vertices),&vb_addr);
  auto ib=upload_buffer(c.device.Get(),indices,sizeof(indices),&ib_addr);
  D3D12_RAYTRACING_GEOMETRY_TRIANGLES_DESC tri{};
  tri.VertexBuffer.StartAddress=vb_addr; tri.VertexBuffer.StrideInBytes=sizeof(Vertex);
  tri.VertexCount=3; tri.VertexFormat=DXGI_FORMAT_R32G32B32_FLOAT;
  tri.IndexBuffer=ib_addr; tri.IndexCount=3; tri.IndexFormat=DXGI_FORMAT_R32_UINT;
  D3D12_RAYTRACING_GEOMETRY_DESC geom{}; geom.Type=D3D12_RAYTRACING_GEOMETRY_TYPE_TRIANGLES;
  geom.Flags=D3D12_RAYTRACING_GEOMETRY_FLAG_OPAQUE; geom.Triangles=tri;
  D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS inputs{};
  inputs.Type=D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL;
  inputs.DescsLayout=D3D12_ELEMENTS_LAYOUT_ARRAY; inputs.NumDescs=1; inputs.pGeometryDescs=&geom;
  inputs.Flags=D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE;
  D3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO info{};
  c.device->GetRaytracingAccelerationStructurePrebuildInfo(&inputs,&info);
  std::printf("prebuild result=%llu bytes scratch=%llu update_scratch=%llu\n",
    static_cast<unsigned long long>(info.ResultDataMaxSizeInBytes),static_cast<unsigned long long>(info.ScratchDataSizeInBytes),static_cast<unsigned long long>(info.UpdateScratchDataSizeInBytes));
  if(!info.ResultDataMaxSizeInBytes||!info.ScratchDataSizeInBytes){std::fprintf(stderr,"invalid prebuild info\n");return EXIT_FAILURE;}
  UINT64 result_bytes=align_up(info.ResultDataMaxSizeInBytes,kASAlignment);
  UINT64 scratch_bytes=align_up(info.ScratchDataSizeInBytes,kScratchAlignment);
  ComPtr<ID3D12Resource> result,scratch;
  auto rd=buffer_desc(result_bytes,D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
  auto sd=buffer_desc(scratch_bytes,D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
  auto hp=heap(D3D12_HEAP_TYPE_DEFAULT);
  check(c.device->CreateCommittedResource(&hp,D3D12_HEAP_FLAG_NONE,&rd,D3D12_RESOURCE_STATE_RAYTRACING_ACCELERATION_STRUCTURE,nullptr,IID_PPV_ARGS(&result)),"Create BLAS result");
  // Buffer 的初始状态由 Debug Layer 约束为 COMMON；不能假装创建时就是 UAV。
  check(c.device->CreateCommittedResource(&hp,D3D12_HEAP_FLAG_NONE,&sd,D3D12_RESOURCE_STATE_COMMON,nullptr,IID_PPV_ARGS(&scratch)),"Create BLAS scratch");
  std::printf("aligned result=%llu scratch=%llu result_gpu=0x%llx\n",static_cast<unsigned long long>(result_bytes),static_cast<unsigned long long>(scratch_bytes),static_cast<unsigned long long>(result->GetGPUVirtualAddress()));
  D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC build{};
  build.DestAccelerationStructureData=result->GetGPUVirtualAddress(); build.ScratchAccelerationStructureData=scratch->GetGPUVirtualAddress(); build.Inputs=inputs;
  check(c.list->Reset(c.allocator.Get(),nullptr),"Reset command list");
  D3D12_RESOURCE_BARRIER scratch_to_uav{}; scratch_to_uav.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
  scratch_to_uav.Transition.pResource=scratch.Get(); scratch_to_uav.Transition.Subresource=D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
  scratch_to_uav.Transition.StateBefore=D3D12_RESOURCE_STATE_COMMON; scratch_to_uav.Transition.StateAfter=D3D12_RESOURCE_STATE_UNORDERED_ACCESS;
  c.list->ResourceBarrier(1,&scratch_to_uav);
  c.list->BuildRaytracingAccelerationStructure(&build,0,nullptr);
  D3D12_RESOURCE_BARRIER barrier{}; barrier.Type=D3D12_RESOURCE_BARRIER_TYPE_UAV; barrier.UAV.pResource=result.Get();
  c.list->ResourceBarrier(1,&barrier);
  check(c.list->Close(),"Close command list");
  ID3D12CommandList* lists[]={c.list.Get()}; c.queue->ExecuteCommandLists(1,lists); wait_gpu(c);
  check(c.fence->GetCompletedValue()>=c.fence_value?S_OK:E_FAIL,"BLAS GPU completion");
  validate_info_queue(c);
  std::puts("BLAS build: PASS");
  CloseHandle(c.fence_event); return EXIT_SUCCESS;
}
