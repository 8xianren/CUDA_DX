// R.11 最小、无窗口 DXR：BLAS -> TLAS -> DXIL library -> State Object -> SBT -> DispatchRays。
// 编译前用 Windows SDK 的 dxc -T lib_6_3 -Fo dxr_minimal.dxil dxr_minimal.hlsl；
// 本程序 argv[1] 接受该 DXIL 文件路径。与 R.10 独立，不修改已有示例。
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d12.h>
#include <d3d12sdklayers.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <vector>
#pragma comment(lib, "d3d12.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "dxguid.lib")
using Microsoft::WRL::ComPtr;
void check(HRESULT hr, const char* name) {
  if (FAILED(hr)) { std::fprintf(stderr, "%s: HRESULT 0x%08lx\n", name, (unsigned long)hr); std::exit(1); }
}
void require(bool ok, const char* name) { if (!ok) { std::fprintf(stderr, "%s\n", name); std::exit(1); } }
UINT64 align_up(UINT64 n, UINT64 a) { return (n+a-1)/a*a; }
D3D12_HEAP_PROPERTIES heap(D3D12_HEAP_TYPE type) {
  D3D12_HEAP_PROPERTIES h{}; h.Type=type; h.CreationNodeMask=h.VisibleNodeMask=1; return h;
}
D3D12_RESOURCE_DESC buffer(UINT64 bytes, D3D12_RESOURCE_FLAGS flags=D3D12_RESOURCE_FLAG_NONE) {
  D3D12_RESOURCE_DESC d{}; d.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER; d.Width=bytes;
  d.Height=1; d.DepthOrArraySize=1; d.MipLevels=1; d.SampleDesc.Count=1;
  d.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR; d.Flags=flags; return d;
}
ComPtr<ID3D12Resource> make_buffer(ID3D12Device* dev, D3D12_HEAP_TYPE type,
     UINT64 size, D3D12_RESOURCE_FLAGS flags, D3D12_RESOURCE_STATES state) {
  auto h=heap(type); auto d=buffer(size,flags); ComPtr<ID3D12Resource> r;
  check(dev->CreateCommittedResource(&h,D3D12_HEAP_FLAG_NONE,&d,state,nullptr,IID_PPV_ARGS(&r)),"CreateCommittedResource");
  return r;
}
// CPU 只写 Upload；即使 Unmap，也不能在 GPU 使用结束前释放或覆写它。
ComPtr<ID3D12Resource> upload(ID3D12Device* dev,const void* src,UINT64 bytes) {
  auto r=make_buffer(dev,D3D12_HEAP_TYPE_UPLOAD,bytes,D3D12_RESOURCE_FLAG_NONE,D3D12_RESOURCE_STATE_GENERIC_READ);
  void* p=nullptr; D3D12_RANGE read{0,0}; check(r->Map(0,&read,&p),"Map upload");
  std::memcpy(p,src,(size_t)bytes); D3D12_RANGE written{0,(SIZE_T)bytes}; r->Unmap(0,&written);
  return r;
}
void transition(ID3D12GraphicsCommandList4* list,ID3D12Resource* r,
                D3D12_RESOURCE_STATES before,D3D12_RESOURCE_STATES after) {
  D3D12_RESOURCE_BARRIER b{}; b.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
  b.Transition.pResource=r; b.Transition.Subresource=D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
  b.Transition.StateBefore=before; b.Transition.StateAfter=after; list->ResourceBarrier(1,&b);
}
void uav_barrier(ID3D12GraphicsCommandList4* list,ID3D12Resource* r) {
  // BuildRaytracingAccelerationStructure 写 Result：后续构建/遍历前必须建立 UAV 写后读顺序。
  D3D12_RESOURCE_BARRIER b{}; b.Type=D3D12_RESOURCE_BARRIER_TYPE_UAV; b.UAV.pResource=r;
  list->ResourceBarrier(1,&b);
}
void verify_messages(ID3D12InfoQueue* q) {
  if (!q) { std::puts("InfoQueue unavailable"); return; }
  UINT errors=0,warnings=0;
  for(UINT64 i=0;i<q->GetNumStoredMessagesAllowedByRetrievalFilter();++i) {
    SIZE_T size=0; q->GetMessage(i,nullptr,&size);
    std::vector<unsigned char> data(size); auto* m=(D3D12_MESSAGE*)data.data();
    check(q->GetMessage(i,m,&size),"GetMessage");
    if(m->Severity<=D3D12_MESSAGE_SEVERITY_WARNING) {
      std::fprintf(stderr,"D3D12 severity=%d id=%d: %s\n",(int)m->Severity,(int)m->ID,m->pDescription);
      if(m->Severity<=D3D12_MESSAGE_SEVERITY_ERROR) ++errors; else ++warnings;
    }
  }
  std::printf("InfoQueue: errors=%u warnings=%u\n",errors,warnings);
  require(errors==0 && warnings==0,"Debug Layer validation failed");
}
struct Vertex { float x,y,z; };
int main(int argc,char** argv) {
  require(argc==2,"usage: dxr_minimal_pipeline.exe <dxr_minimal.dxil>");
  std::ifstream file(argv[1],std::ios::binary);
  require(file.good(),"DXIL file not found: compile HLSL with dxc -T lib_6_3 first");
  std::vector<char> dxil((std::istreambuf_iterator<char>(file)),std::istreambuf_iterator<char>());
  require(!dxil.empty(),"DXIL file is empty");
  ComPtr<ID3D12Debug> debug;
  if(SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)))) { debug->EnableDebugLayer(); std::puts("Debug Layer: enabled"); }
  ComPtr<IDXGIFactory6> factory; check(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory)),"CreateDXGIFactory2");
  ComPtr<IDXGIAdapter1> adapter;
  for(UINT i=0;;++i) {
    ComPtr<IDXGIAdapter1> a;
    HRESULT hr=factory->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&a));
    if(hr==DXGI_ERROR_NOT_FOUND) break;
    if(FAILED(hr)) continue;
    DXGI_ADAPTER_DESC1 d{}; a->GetDesc1(&d);
    if(!(d.Flags&DXGI_ADAPTER_FLAG_SOFTWARE) && SUCCEEDED(D3D12CreateDevice(a.Get(),D3D_FEATURE_LEVEL_12_0,__uuidof(ID3D12Device),nullptr))) {adapter=a;break;}
  }
  require(!!adapter,"No hardware D3D12 adapter");
  DXGI_ADAPTER_DESC1 ad{}; adapter->GetDesc1(&ad); std::wprintf(L"adapter: %ls\n",ad.Description);
  ComPtr<ID3D12Device5> dev; check(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_12_0,IID_PPV_ARGS(&dev)),"CreateDevice5");
  ComPtr<ID3D12InfoQueue> info; dev.As(&info);
  D3D12_FEATURE_DATA_D3D12_OPTIONS5 options{};
  check(dev->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS5,&options,sizeof(options)),"OPTIONS5");
  std::printf("raytracing tier: %d\n",(int)options.RaytracingTier);
  require(options.RaytracingTier!=D3D12_RAYTRACING_TIER_NOT_SUPPORTED,"DXR unsupported");
  D3D12_COMMAND_QUEUE_DESC qdesc{}; qdesc.Type=D3D12_COMMAND_LIST_TYPE_DIRECT;
  ComPtr<ID3D12CommandQueue> queue; check(dev->CreateCommandQueue(&qdesc,IID_PPV_ARGS(&queue)),"CreateCommandQueue");
  ComPtr<ID3D12CommandAllocator> allocator; check(dev->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&allocator)),"CreateAllocator");
  ComPtr<ID3D12GraphicsCommandList4> list; check(dev->CreateCommandList1(0,D3D12_COMMAND_LIST_TYPE_DIRECT,D3D12_COMMAND_LIST_FLAG_NONE,IID_PPV_ARGS(&list)),"CreateCommandList4");
  ComPtr<ID3D12Fence> fence; check(dev->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&fence)),"CreateFence");
  HANDLE event=CreateEventW(nullptr,FALSE,FALSE,nullptr); require(event!=nullptr,"CreateEventW failed");

  // 几何输入是 upload buffer；一个局部 BLAS 被两个 TLAS 实例复用。
  Vertex verts[3]={{0,1,0},{-1,-1,0},{1,-1,0}};
  uint32_t indices[3]={0,1,2};
  auto vb=upload(dev.Get(),verts,sizeof(verts)); auto ib=upload(dev.Get(),indices,sizeof(indices));
  D3D12_RAYTRACING_GEOMETRY_DESC geom{};
  geom.Type=D3D12_RAYTRACING_GEOMETRY_TYPE_TRIANGLES;
  geom.Flags=D3D12_RAYTRACING_GEOMETRY_FLAG_OPAQUE;
  geom.Triangles.VertexBuffer.StartAddress=vb->GetGPUVirtualAddress();
  geom.Triangles.VertexBuffer.StrideInBytes=sizeof(Vertex);
  geom.Triangles.VertexCount=3; geom.Triangles.VertexFormat=DXGI_FORMAT_R32G32B32_FLOAT;
  geom.Triangles.IndexBuffer=ib->GetGPUVirtualAddress();
  geom.Triangles.IndexCount=3; geom.Triangles.IndexFormat=DXGI_FORMAT_R32_UINT;
  D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS bi{};
  bi.Type=D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL;
  bi.DescsLayout=D3D12_ELEMENTS_LAYOUT_ARRAY; bi.NumDescs=1; bi.pGeometryDescs=&geom;
  bi.Flags=D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE;
  D3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO bp{};
  dev->GetRaytracingAccelerationStructurePrebuildInfo(&bi,&bp);
  require(bp.ResultDataMaxSizeInBytes && bp.ScratchDataSizeInBytes,"BLAS prebuild sizes invalid");
  auto result_flags=D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
  auto as_state=D3D12_RESOURCE_STATE_RAYTRACING_ACCELERATION_STRUCTURE;
  auto blas=make_buffer(dev.Get(),D3D12_HEAP_TYPE_DEFAULT,align_up(bp.ResultDataMaxSizeInBytes,256),result_flags,as_state);
  auto bs=make_buffer(dev.Get(),D3D12_HEAP_TYPE_DEFAULT,align_up(bp.ScratchDataSizeInBytes,256),result_flags,D3D12_RESOURCE_STATE_COMMON);
  D3D12_RAYTRACING_INSTANCE_DESC instances[2]{};
  for(int i=0;i<2;++i) {
    auto& in=instances[i]; in.Transform[0][0]=in.Transform[1][1]=in.Transform[2][2]=1;
    in.Transform[0][3]=float(i*3); in.InstanceID=i+1; in.InstanceMask=0xff;
    in.InstanceContributionToHitGroupIndex=0; in.AccelerationStructure=blas->GetGPUVirtualAddress();
  }
  // InstanceDesc 数组起始地址至少 16B 对齐；UPLOAD buffer GPU VA 满足此要求。
  auto instance=upload(dev.Get(),instances,sizeof(instances));
  D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS ti{};
  ti.Type=D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL;
  ti.DescsLayout=D3D12_ELEMENTS_LAYOUT_ARRAY; ti.NumDescs=2;
  ti.InstanceDescs=instance->GetGPUVirtualAddress();
  ti.Flags=D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE;
  D3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO tp{};
  dev->GetRaytracingAccelerationStructurePrebuildInfo(&ti,&tp);
  require(tp.ResultDataMaxSizeInBytes && tp.ScratchDataSizeInBytes,"TLAS prebuild sizes invalid");
  auto tlas=make_buffer(dev.Get(),D3D12_HEAP_TYPE_DEFAULT,align_up(tp.ResultDataMaxSizeInBytes,256),result_flags,as_state);
  auto ts=make_buffer(dev.Get(),D3D12_HEAP_TYPE_DEFAULT,align_up(tp.ScratchDataSizeInBytes,256),result_flags,D3D12_RESOURCE_STATE_COMMON);

  // root SRV(t0) 直接传 TLAS GPU VA；root UAV(u0) 直接传 8*uint 的 buffer VA。
  // 两者都是 buffer root descriptors，因此无需 descriptor heap；也没有 local root arguments。
  D3D12_ROOT_PARAMETER params[2]{};
  params[0].ParameterType=D3D12_ROOT_PARAMETER_TYPE_SRV;
  params[0].Descriptor.ShaderRegister=0; params[0].ShaderVisibility=D3D12_SHADER_VISIBILITY_ALL;
  params[1].ParameterType=D3D12_ROOT_PARAMETER_TYPE_UAV;
  params[1].Descriptor.ShaderRegister=0; params[1].ShaderVisibility=D3D12_SHADER_VISIBILITY_ALL;
  D3D12_ROOT_SIGNATURE_DESC rd{}; rd.NumParameters=2; rd.pParameters=params;
  ComPtr<ID3DBlob> root_blob,root_err;
  HRESULT hr=D3D12SerializeRootSignature(&rd,D3D_ROOT_SIGNATURE_VERSION_1,&root_blob,&root_err);
  if(FAILED(hr) && root_err) std::fprintf(stderr,"RootSig: %s\n",(char*)root_err->GetBufferPointer());
  check(hr,"SerializeRootSignature");
  ComPtr<ID3D12RootSignature> root;
  check(dev->CreateRootSignature(0,root_blob->GetBufferPointer(),root_blob->GetBufferSize(),IID_PPV_ARGS(&root)),"CreateRootSignature");

  D3D12_DXIL_LIBRARY_DESC lib{};
  lib.DXILLibrary={dxil.data(),dxil.size()}; // 未指定 exports：导出 library 内的 RayGen/Miss/ClosestHit。
  D3D12_HIT_GROUP_DESC hit{}; hit.HitGroupExport=L"HitGroup";
  hit.ClosestHitShaderImport=L"ClosestHit"; hit.Type=D3D12_HIT_GROUP_TYPE_TRIANGLES;
  D3D12_RAYTRACING_SHADER_CONFIG sc{}; sc.MaxPayloadSizeInBytes=sizeof(uint32_t);
  sc.MaxAttributeSizeInBytes=8; // 内建 triangle barycentrics: float2。
  D3D12_GLOBAL_ROOT_SIGNATURE gr{}; gr.pGlobalRootSignature=root.Get();
  D3D12_RAYTRACING_PIPELINE_CONFIG pc{}; pc.MaxTraceRecursionDepth=1;
  D3D12_STATE_SUBOBJECT sub[5]{};
  sub[0]={D3D12_STATE_SUBOBJECT_TYPE_DXIL_LIBRARY,&lib};
  sub[1]={D3D12_STATE_SUBOBJECT_TYPE_HIT_GROUP,&hit};
  sub[2]={D3D12_STATE_SUBOBJECT_TYPE_RAYTRACING_SHADER_CONFIG,&sc};
  sub[3]={D3D12_STATE_SUBOBJECT_TYPE_GLOBAL_ROOT_SIGNATURE,&gr};
  sub[4]={D3D12_STATE_SUBOBJECT_TYPE_RAYTRACING_PIPELINE_CONFIG,&pc};
  D3D12_STATE_OBJECT_DESC sod{}; sod.Type=D3D12_STATE_OBJECT_TYPE_RAYTRACING_PIPELINE;
  sod.NumSubobjects=5; sod.pSubobjects=sub;
  ComPtr<ID3D12StateObject> state;
  check(dev->CreateStateObject(&sod,IID_PPV_ARGS(&state)),"CreateStateObject");
  ComPtr<ID3D12StateObjectProperties> properties;
  check(state.As(&properties),"StateObjectProperties");
  // SBT：每条 record 含 32B opaque shader identifier；无 local root -> 无附加字节。
  // record stride 32B 对齐；表起始地址 64B 对齐：分别放在 offset 0/64/128。
  constexpr UINT stride=D3D12_RAYTRACING_SHADER_RECORD_BYTE_ALIGNMENT;
  constexpr UINT table=D3D12_RAYTRACING_SHADER_TABLE_BYTE_ALIGNMENT;
  static_assert(stride==32 && table==64,"Unexpected DXR SBT alignment");
  unsigned char sbt[table*3]{};
  const wchar_t* names[]={L"RayGen",L"Miss",L"HitGroup"};
  for(int i=0;i<3;++i) {
    const void* identifier=properties->GetShaderIdentifier(names[i]);
    require(identifier!=nullptr,"GetShaderIdentifier returned null: check export names");
    std::memcpy(sbt+i*table,identifier,D3D12_SHADER_IDENTIFIER_SIZE_IN_BYTES);
  }
  auto shader_table=upload(dev.Get(),sbt,sizeof(sbt));
  // 普通 Default buffer 实际从 COMMON 创建；显式转为 UAV，避免忽略 InitialState 的警告。
  auto output=make_buffer(dev.Get(),D3D12_HEAP_TYPE_DEFAULT,8*sizeof(uint32_t),result_flags,D3D12_RESOURCE_STATE_COMMON);
  auto readback=make_buffer(dev.Get(),D3D12_HEAP_TYPE_READBACK,8*sizeof(uint32_t),D3D12_RESOURCE_FLAG_NONE,D3D12_RESOURCE_STATE_COPY_DEST);
  // 一条 direct queue、一个提交：命令顺序 + UAV barriers 负责 GPU 依赖；
  // 最后的 fence 负责 CPU readback 和 upload/scratch/SBT 的存活期。
  check(list->Reset(allocator.Get(),nullptr),"Reset command list");
  transition(list.Get(),bs.Get(),D3D12_RESOURCE_STATE_COMMON,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
  transition(list.Get(),ts.Get(),D3D12_RESOURCE_STATE_COMMON,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
  D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC build{};
  build.Inputs=bi; build.DestAccelerationStructureData=blas->GetGPUVirtualAddress();
  build.ScratchAccelerationStructureData=bs->GetGPUVirtualAddress();
  list->BuildRaytracingAccelerationStructure(&build,0,nullptr);
  uav_barrier(list.Get(),blas.Get());
  build={}; build.Inputs=ti; build.DestAccelerationStructureData=tlas->GetGPUVirtualAddress();
  build.ScratchAccelerationStructureData=ts->GetGPUVirtualAddress();
  list->BuildRaytracingAccelerationStructure(&build,0,nullptr);
  uav_barrier(list.Get(),tlas.Get());
  transition(list.Get(),output.Get(),D3D12_RESOURCE_STATE_COMMON,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
  list->SetComputeRootSignature(root.Get());
  list->SetComputeRootShaderResourceView(0,tlas->GetGPUVirtualAddress());
  list->SetComputeRootUnorderedAccessView(1,output->GetGPUVirtualAddress());
  list->SetPipelineState1(state.Get());
  D3D12_GPU_VIRTUAL_ADDRESS base=shader_table->GetGPUVirtualAddress();
  D3D12_DISPATCH_RAYS_DESC dispatch{};
  dispatch.RayGenerationShaderRecord={base,D3D12_SHADER_IDENTIFIER_SIZE_IN_BYTES};
  dispatch.MissShaderTable={base+table,stride,stride};
  dispatch.HitGroupTable={base+2*table,stride,stride};
  dispatch.Width=8; dispatch.Height=1; dispatch.Depth=1;
  list->DispatchRays(&dispatch);
  transition(list.Get(),output.Get(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_COPY_SOURCE);
  list->CopyResource(readback.Get(),output.Get());
  check(list->Close(),"Close command list");
  ID3D12CommandList* lists[]={list.Get()}; queue->ExecuteCommandLists(1,lists);
  check(queue->Signal(fence.Get(),1),"Signal fence");
  if(fence->GetCompletedValue()<1) {
    check(fence->SetEventOnCompletion(1,event),"SetEventOnCompletion");
    require(WaitForSingleObject(event,INFINITE)==WAIT_OBJECT_0,"Fence wait failed");
  }
  CloseHandle(event);
  D3D12_RANGE read{0,8*sizeof(uint32_t)}; uint32_t* values=nullptr;
  check(readback->Map(0,&read,(void**)&values),"Map readback");
  const uint32_t expected[8]={1,1,1,0,2,2,2,0};
  bool pass=true; unsigned miss=0,first=0,second=0;
  for(int i=0;i<8;++i) {
    std::printf("ray[%d] = %u (expected %u)\n",i,values[i],expected[i]);
    pass&=(values[i]==expected[i]);
    miss+=(values[i]==0); first+=(values[i]==1); second+=(values[i]==2);
  }
  D3D12_RANGE wrote{0,0}; readback->Unmap(0,&wrote);
  std::printf("Miss=%u ClosestHit(ID=1)=%u ClosestHit(ID=2)=%u\n",miss,first,second);
  verify_messages(info.Get());
  std::puts(pass ? "DispatchRays: PASS" : "DispatchRays: FAIL");
  return pass ? 0 : 1;
}
