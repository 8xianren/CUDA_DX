// R.12 第二部分：矩形面积光 NEE，保留第一部分点光代码。
// BLAS -> TLAS -> DXIL library -> State Object -> SBT -> DispatchRays。
// 编译前用 Windows SDK 的 dxc -T lib_6_3 -Fo dxr_area.dxil dxr_area.hlsl；
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
#include <cmath>
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
#include "dxr_area_reference.h"
// 每个测试4096个独立输出槽，8个测试；float4 stride16，总524288B。
// CPU参考与HLSL都使用相同的固定样本编号；这里不新增跨线程归约或原子操作。
constexpr UINT kSamples=area_reference::Samples, kCases=area_reference::Cases;
constexpr UINT64 kOutputBytes=UINT64(kSamples)*kCases*sizeof(area_reference::GpuResult);
struct Vertex { float x,y,z; };
int main(int argc,char** argv) {
  std::setvbuf(stdout,nullptr,_IONBF,0);
  require(argc==2,"usage: dxr_area_pipeline.exe <dxr_area.dxil>");
  std::ifstream file(argv[1],std::ios::binary);
  require(file.good(),"DXIL file not found: compile HLSL with dxc -T lib_6_3 first");
  std::vector<char> dxil((std::istreambuf_iterator<char>(file)),std::istreambuf_iterator<char>());
  require(!dxil.empty(),"DXIL file is empty");
  ComPtr<ID3D12Debug> debug;
  check(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)),"Debug required");
  debug->EnableDebugLayer(); std::puts("Debug Layer: enabled");
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
  ComPtr<ID3D12InfoQueue> info; check(dev.As(&info),"InfoQueue required");
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

  // 几何输入是 Upload buffer；一个局部 BLAS 被多组测试的接收面/挡板实例复用。
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
  // 接收面mask1，挡板mask2；各case间隔8单位，有限阴影段不会交叉到邻列。
  // 共享同一BLAS；挡板只在XY缩放、Z平移，CPU用同样几何的解析平面测试。
  // 光源只存在于HLSL/CPU采样参数，不作为TLAS几何，因此本课不渲染灯本身。
  std::vector<D3D12_RAYTRACING_INSTANCE_DESC> instances;
  auto add_instance=[&](float x,float z,float scale,UINT mask) {
    D3D12_RAYTRACING_INSTANCE_DESC in{};
    in.Transform[0][0]=in.Transform[1][1]=scale; in.Transform[2][2]=1;
    in.Transform[0][3]=x; in.Transform[2][3]=z;
    in.InstanceMask=mask; in.AccelerationStructure=blas->GetGPUVirtualAddress();
    instances.push_back(in);
  };
  for(UINT test=0;test<kCases;++test) {
    const float x=8.0f*test; add_instance(x,0,1,1);
    if(test==1)add_instance(x,1.5f,.35f,2); // 部分遮挡：有些灯点仍可见。
    if(test==3)add_instance(x,4,4,2);      // 位于z3光源后，有限射线应忽略。
    if(test==7)add_instance(x,1.5f,2,2);  // 足够大，挡住全部灯样本。
  }
  // InstanceDesc 数组起始地址至少 16B 对齐；UPLOAD buffer GPU VA 满足此要求。
  auto instance=upload(dev.Get(),instances.data(),instances.size()*sizeof(instances[0]));
  D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS ti{};
  ti.Type=D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL;
  ti.DescsLayout=D3D12_ELEMENTS_LAYOUT_ARRAY; ti.NumDescs=UINT(instances.size());
  ti.InstanceDescs=instance->GetGPUVirtualAddress();
  ti.Flags=D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE;
  D3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO tp{};
  dev->GetRaytracingAccelerationStructurePrebuildInfo(&ti,&tp);
  require(tp.ResultDataMaxSizeInBytes && tp.ScratchDataSizeInBytes,"TLAS prebuild sizes invalid");
  auto tlas=make_buffer(dev.Get(),D3D12_HEAP_TYPE_DEFAULT,align_up(tp.ResultDataMaxSizeInBytes,256),result_flags,as_state);
  auto ts=make_buffer(dev.Get(),D3D12_HEAP_TYPE_DEFAULT,align_up(tp.ScratchDataSizeInBytes,256),result_flags,D3D12_RESOURCE_STATE_COMMON);

  // root SRV(t0) 直接传 TLAS GPU VA；root UAV(u0) 直接传 32768*float4（524288B）的 buffer VA；每样本16B。
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
  lib.DXILLibrary={dxil.data(),dxil.size()}; // 未指定 exports：导出 RayGen/PrimaryMiss/ShadowMiss/SurfaceHit。
  D3D12_HIT_GROUP_DESC hit{}; hit.HitGroupExport=L"HitGroup";
  hit.ClosestHitShaderImport=L"SurfaceHit"; hit.Type=D3D12_HIT_GROUP_TYPE_TRIANGLES;
  // 主payload为uint+float4共20B，阴影4B，声明最大20B；不使用常量缓冲16B打包规则推断payload。
  D3D12_RAYTRACING_SHADER_CONFIG sc{}; sc.MaxPayloadSizeInBytes=20;
  sc.MaxAttributeSizeInBytes=8; // 内建 triangle barycentrics: float2。
  D3D12_GLOBAL_ROOT_SIGNATURE gr{}; gr.pGlobalRootSignature=root.Get();
  D3D12_RAYTRACING_PIPELINE_CONFIG pc{}; pc.MaxTraceRecursionDepth=2; // RayGen→SurfaceHit→Shadow，TraceRay嵌套深度2
  // TraceRay深度与路径反弹次数不是同一概念。
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
  // RG offset0；Miss表offset64，两条32B记录：PrimaryMiss/ShadowMiss；Hit表offset128。
  // 无local参数，仅identifier32B；表起点64B对齐，不要求每条Miss也64B对齐。
  unsigned char sbt[160]{};
  const wchar_t* names[]={L"RayGen",L"PrimaryMiss",L"ShadowMiss",L"HitGroup"};
  const UINT offsets[]={0,64,96,128};
  for(UINT i=0;i<4;++i) {
    const void* id=properties->GetShaderIdentifier(names[i]);
    require(id!=nullptr,"missing export"); std::memcpy(sbt+offsets[i],id,32);
  }
  auto shader_table=upload(dev.Get(),sbt,sizeof(sbt));
  require(shader_table->GetGPUVirtualAddress()%64==0,"SBT alignment");
  // 普通 Default buffer 实际从 COMMON 创建；显式转为 UAV，避免忽略 InitialState 的警告。
  auto output=make_buffer(dev.Get(),D3D12_HEAP_TYPE_DEFAULT,kOutputBytes,result_flags,D3D12_RESOURCE_STATE_COMMON);
  auto readback=make_buffer(dev.Get(),D3D12_HEAP_TYPE_READBACK,kOutputBytes,D3D12_RESOURCE_FLAG_NONE,D3D12_RESOURCE_STATE_COPY_DEST);
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
  dispatch.MissShaderTable={base+64,64,32};
  dispatch.HitGroupTable={base+128,32,32};
  dispatch.Width=kSamples; dispatch.Height=kCases; dispatch.Depth=1;
  list->DispatchRays(&dispatch);
  transition(list.Get(),output.Get(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_COPY_SOURCE);
  list->CopyResource(readback.Get(),output.Get());
  check(list->Close(),"Close command list");
  ID3D12CommandList* lists[]={list.Get()}; queue->ExecuteCommandLists(1,lists);
  check(queue->Signal(fence.Get(),1),"Signal fence");
  if(fence->GetCompletedValue()<1) {
    check(fence->SetEventOnCompletion(1,event),"SetEventOnCompletion");
    require(WaitForSingleObject(event,10000)==WAIT_OBJECT_0,"Fence wait failed");
  }
  CloseHandle(event);
  // Fence已完成才允许CPU读取；Map范围为整个输出，Unmap声明CPU没有写入。
  D3D12_RANGE read{0,SIZE_T(kOutputBytes)}; area_reference::GpuResult* values=nullptr;
  check(readback->Map(0,&read,(void**)&values),"Map readback");
  const bool pass=area_reference::verify(values);
  D3D12_RANGE wrote{0,0}; readback->Unmap(0,&wrote);
  std::printf("Fence target=1 completed=%llu; samples=%u cases=%u output_bytes=%llu\n",
    (unsigned long long)fence->GetCompletedValue(),kSamples,kCases,(unsigned long long)kOutputBytes);
  verify_messages(info.Get());
  std::puts(pass ? "R.12 area NEE: PASS" : "R.12: FAIL");
  return pass ? 0 : 1;
}
