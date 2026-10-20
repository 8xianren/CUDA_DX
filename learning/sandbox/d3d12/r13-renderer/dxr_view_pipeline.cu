// R.13.4：沿用矩阵相机和双槽帧资源，增加共享VB/IB的属性读取与非均匀缩放诊断。
// BLAS -> TLAS -> DXIL library -> State Object -> SBT -> DispatchRays。
// 编译前用 Windows SDK 的 dxc -T lib_6_3 -Fo dxr_view.dxil dxr_view.hlsl；
// 本程序 argv[1] 接受该 DXIL 文件路径。作为新版R.13后续扩展起点，旧实验保留对照。
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
#include <filesystem>
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
#include "dxr_surface_reference.h"
#include "dxr_lighting_reference.h"
#include "dxr_progressive_runner.h"
#include "dxr_history_runner.h"
#include "dxr_window_runner.h"
#include "dxr_resize_runner.h"
int main(int argc,char** argv) try {
  std::setvbuf(stdout,nullptr,_IONBF,0);
  require(argc==2||(argc==3&&(std::strcmp(argv[2],"lighting")==0||std::strcmp(argv[2],"progressive")==0||std::strcmp(argv[2],"history")==0||std::strcmp(argv[2],"window")==0||std::strcmp(argv[2],"resize")==0)),"usage: dxr_view_pipeline.exe <dxil> [lighting|progressive|history|window|resize]");
  // lighting必须配合ENABLE_DIRECT_LIGHT=1编译的DXIL；默认保留R.13.4的诊断协议。
  const bool lighting=argc==3;
  const bool historyMode=argc==3&&std::strcmp(argv[2],"history")==0;
  const bool resizeMode=argc==3&&std::strcmp(argv[2],"resize")==0;
  const bool windowMode=resizeMode||(argc==3&&std::strcmp(argv[2],"window")==0);
  const bool progressive=historyMode||windowMode||(argc==3&&std::strcmp(argv[2],"progressive")==0);
  const UINT kWidth=view_reference::CanvasW,kHeight=view_reference::CanvasH;
  const UINT64 kOutputBytes=UINT64(kWidth)*kHeight*(lighting?sizeof(lighting_reference::GpuRecord):sizeof(surface_reference::GpuRecord));
  const std::string dxilPath=argv[1];
  // 结果依附本示例的DXIL所在目录，按小节归档；不依赖启动程序时的工作目录。
  // 创建失败由main的异常处理报告，避免静默丢失读回结果。
  const auto results=std::filesystem::path(dxilPath).parent_path()/"results"/(resizeMode?"r13-08c":windowMode?"r13-08b":historyMode?"r13-07":progressive?"r13-06":lighting?"r13-05":"r13-04");
  std::filesystem::create_directories(results);
  const std::string imagePrefix=(results/(std::filesystem::path(dxilPath).stem().string()+(lighting?"_direct":"_surface"))).string();
  const auto cases=lighting?lighting_reference::cases():view_reference::cases();
  // 先验证所有相机输入并生成矩阵，避免GPU提交后才因相机退化而抛出异常。
  std::array<view_reference::ViewData,8> preparedViews;
  for(unsigned i=0;i<cases.size();++i){preparedViews[i]=view_reference::make_view(cases[i],i+1);
    if(lighting)preparedViews[i].targetInfo[3]=lighting_reference::mode(i);}
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

  // 局部倾斜平面实例化为两块竖板和地板。VB/IB除了构建AS，还需供ClosestHit读取。
  const auto& verts=surface_reference::Vertices;
  const auto& indices=surface_reference::Indices;
  auto vb=upload(dev.Get(),verts,sizeof(verts)); auto ib=upload(dev.Get(),indices,sizeof(indices));
  D3D12_RAYTRACING_GEOMETRY_DESC geom{};
  geom.Type=D3D12_RAYTRACING_GEOMETRY_TYPE_TRIANGLES;
  geom.Flags=D3D12_RAYTRACING_GEOMETRY_FLAG_OPAQUE;
  geom.Triangles.VertexBuffer.StartAddress=vb->GetGPUVirtualAddress();
  geom.Triangles.VertexBuffer.StrideInBytes=sizeof(view_reference::Vertex);
  geom.Triangles.VertexCount=4; geom.Triangles.VertexFormat=DXGI_FORMAT_R32G32B32_FLOAT;
  geom.Triangles.IndexBuffer=ib->GetGPUVirtualAddress();
  geom.Triangles.IndexCount=6; geom.Triangles.IndexFormat=DXGI_FORMAT_R32_UINT;
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
  // 三实例共用同一BLAS；应用ID=1/2/3，所有SBT contribution保持0，不将ID当记录偏移。
  std::vector<D3D12_RAYTRACING_INSTANCE_DESC> instances;
  for(const auto& src:surface_reference::instances()){
    D3D12_RAYTRACING_INSTANCE_DESC in{};
    std::memcpy(in.Transform,src.m,sizeof(in.Transform));
    in.InstanceID=src.id;in.InstanceMask=1u<<(src.id-1);in.AccelerationStructure=blas->GetGPUVirtualAddress();
    // 实例分别占mask位1/2/4；旧模式射线mask=255仍全包含，R.13.7可选择可见集合。
    instances.push_back(in);
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

  // root参数索引与shader寄存器号是不同命名空间：2号root参数绑定b0。
  // 全局SRV t0=TLAS，UAV u0=输出，CBV b0=视图，SRV t1=VB/t2=IB；总计10 DWORD。
  // root CBV直接持有GPU VA，不创建CBV descriptor heap，也不调用CreateConstantBufferView。
  D3D12_ROOT_PARAMETER params[7]{};
  params[0].ParameterType=D3D12_ROOT_PARAMETER_TYPE_SRV;
  params[1].ParameterType=D3D12_ROOT_PARAMETER_TYPE_UAV;
  params[2].ParameterType=D3D12_ROOT_PARAMETER_TYPE_CBV;
  params[3].ParameterType=params[4].ParameterType=D3D12_ROOT_PARAMETER_TYPE_SRV;
  for(auto& p:params){p.Descriptor.ShaderRegister=0;p.Descriptor.RegisterSpace=0;p.ShaderVisibility=D3D12_SHADER_VISIBILITY_ALL;}
  params[3].Descriptor.ShaderRegister=1;params[4].Descriptor.ShaderRegister=2;
  // R.13.6增加u1历史（2 DWORD）与b1采样常量（4 DWORD），总计16 DWORD。
  params[5].ParameterType=D3D12_ROOT_PARAMETER_TYPE_UAV;params[5].Descriptor.ShaderRegister=1;
  params[6].ParameterType=D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;params[6].Constants.ShaderRegister=1;params[6].Constants.Num32BitValues=4;
  D3D12_ROOT_SIGNATURE_DESC rd{};rd.NumParameters=progressive?7:5;rd.pParameters=params;
  ComPtr<ID3DBlob> root_blob,root_err;
  HRESULT hr=D3D12SerializeRootSignature(&rd,D3D_ROOT_SIGNATURE_VERSION_1,&root_blob,&root_err);
  if(FAILED(hr) && root_err) std::fprintf(stderr,"RootSig: %s\n",(char*)root_err->GetBufferPointer());
  check(hr,"SerializeRootSignature");
  ComPtr<ID3D12RootSignature> root;
  check(dev->CreateRootSignature(0,root_blob->GetBufferPointer(),root_blob->GetBufferSize(),IID_PPV_ARGS(&root)),"CreateRootSignature");

  D3D12_DXIL_LIBRARY_DESC lib{};
  lib.DXILLibrary={dxil.data(),dxil.size()}; // 未指定 exports：导出 RayGen/PrimaryMiss/SurfaceHit。
  D3D12_HIT_GROUP_DESC hit{}; hit.HitGroupExport=L"HitGroup";
  hit.ClosestHitShaderImport=L"SurfaceHit"; hit.Type=D3D12_HIT_GROUP_TYPE_TRIANGLES;
  // Payload为5个float4+uint id共84B；输出另外保存射线与帧号，总stride128。
  D3D12_RAYTRACING_SHADER_CONFIG sc{}; sc.MaxPayloadSizeInBytes=lighting?116:84;
  sc.MaxAttributeSizeInBytes=8; // 内建 triangle barycentrics: float2。
  D3D12_GLOBAL_ROOT_SIGNATURE gr{}; gr.pGlobalRootSignature=root.Get();
  D3D12_RAYTRACING_PIPELINE_CONFIG pc{}; pc.MaxTraceRecursionDepth=lighting?2:1;
  // 光照模式在主ClosestHit内TraceRay阴影，嵌套深度为2；不代表两次间接反弹。
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
  // RG offset0；Miss表offset64仅PrimaryMiss一条32B记录；Hit表offset128。
  // 无local参数，仅identifier32B；表起点64B对齐，不要求每条Miss也64B对齐。
  unsigned char sbt[160]{};
  const wchar_t* names[]={L"RayGen",L"PrimaryMiss",L"HitGroup"};
  const UINT offsets[]={0,64,128};
  for(UINT i=0;i<3;++i) {
    const void* id=properties->GetShaderIdentifier(names[i]);
    require(id!=nullptr,"missing export"); std::memcpy(sbt+offsets[i],id,32);
  }
  if(lighting){const void* id=properties->GetShaderIdentifier(L"ShadowMiss");
    require(id!=nullptr,"lighting requires ENABLE_DIRECT_LIGHT=1 DXIL");std::memcpy(sbt+96,id,32);}
  // lighting的Miss表为PrimaryMiss@64和ShadowMiss@96两条，stride仍32B。
  auto shader_table=upload(dev.Get(),sbt,sizeof(sbt));
  require(shader_table->GetGPUVirtualAddress()%64==0,"SBT alignment");
  // 先单独构建静态AS并以Fence=1收束；每帧只更换相机，不重建场景。
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
  check(list->Close(),"Close AS build");
  ID3D12CommandList* buildLists[]={list.Get()};queue->ExecuteCommandLists(1,buildLists);
  check(queue->Signal(fence.Get(),1),"Signal AS build");
  auto waitFor=[&](UINT64 value){
    if(!value)return;
    UINT64 completed=fence->GetCompletedValue();
    require(completed!=UINT64_MAX,"Device removed while checking fence");
    if(completed<value){
      check(fence->SetEventOnCompletion(value,event),"SetEventOnCompletion");
      DWORD result=WaitForSingleObject(event,10000);
      if(result!=WAIT_OBJECT_0){
        std::fprintf(stderr,"Fence wait result=%lu removed=0x%08lx\n",result,(unsigned long)dev->GetDeviceRemovedReason());
        require(false,"Fence wait timeout/failure");
      }
    }
    require(fence->GetCompletedValue()!=UINT64_MAX && fence->GetCompletedValue()>=value,"Fence not completed");
  };
  waitFor(1);
  if(resizeMode){
    bool pass=run_resize(factory.Get(),dev.Get(),queue.Get(),fence.Get(),root.Get(),state.Get(),tlas.Get(),vb.Get(),ib.Get(),shader_table.Get(),waitFor,results);
    CloseHandle(event);verify_messages(info.Get());std::printf("R.13.8c resize / minimize / history: %s\n",pass?"PASS":"FAIL");return pass?0:1;
  }
  if(windowMode){
    bool pass=run_window(factory.Get(),dev.Get(),queue.Get(),fence.Get(),root.Get(),state.Get(),tlas.Get(),vb.Get(),ib.Get(),shader_table.Get(),waitFor,results);
    CloseHandle(event);verify_messages(info.Get());std::printf("R.13.8b GPU display / Present: %s\n",pass?"PASS":"FAIL");return pass?0:1;
  }
  if(historyMode){
    bool pass=run_history(dev.Get(),queue.Get(),fence.Get(),root.Get(),state.Get(),tlas.Get(),vb.Get(),ib.Get(),shader_table.Get(),waitFor,results);
    CloseHandle(event);verify_messages(info.Get());std::printf("R.13.7 history validity / reset: %s\n",pass?"PASS":"FAIL");return pass?0:1;
  }
  if(progressive){
    bool pass=run_progressive(dev.Get(),queue.Get(),fence.Get(),root.Get(),state.Get(),tlas.Get(),vb.Get(),ib.Get(),shader_table.Get(),waitFor,results);
    CloseHandle(event);verify_messages(info.Get());
    std::printf("R.13.6 pixel sampling / linear accumulation: %s\n",pass?"PASS":"FAIL");return pass?0:1;
  }
  constexpr UINT kSlots=2;
  const UINT64 cbStride=align_up(sizeof(view_reference::ViewData),D3D12_CONSTANT_BUFFER_DATA_PLACEMENT_ALIGNMENT);
  require(cbStride==256,"Unexpected CB stride");
  auto viewUpload=make_buffer(dev.Get(),D3D12_HEAP_TYPE_UPLOAD,kSlots*cbStride,
      D3D12_RESOURCE_FLAG_NONE,D3D12_RESOURCE_STATE_GENERIC_READ);
  unsigned char* mapped=nullptr;D3D12_RANGE noRead{0,0};
  check(viewUpload->Map(0,&noRead,reinterpret_cast<void**>(&mapped)),"Map persistent View upload");
  // Map只提供CPU地址，不等待GPU。保持映射也不意味着可随时覆盖；以每槽Fence管理写权限。
  // 128B有效数据/256B槽步长/512B总分配，三者不可混淆。CPU只memcpy写入，不读回Upload。
  struct FrameSlot {
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList4> list;
    ComPtr<ID3D12Resource> output,readback;
    UINT64 retireFence=0;unsigned caseIndex=0;
    D3D12_RESOURCE_STATES outputState=D3D12_RESOURCE_STATE_COMMON;
  };
  FrameSlot slots[kSlots];
  for(auto& s:slots){
    check(dev->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&s.allocator)),"Create frame allocator");
    check(dev->CreateCommandList1(0,D3D12_COMMAND_LIST_TYPE_DIRECT,D3D12_COMMAND_LIST_FLAG_NONE,IID_PPV_ARGS(&s.list)),"Create frame list");
    s.output=make_buffer(dev.Get(),D3D12_HEAP_TYPE_DEFAULT,kOutputBytes,result_flags,D3D12_RESOURCE_STATE_COMMON);
    s.readback=make_buffer(dev.Get(),D3D12_HEAP_TYPE_READBACK,kOutputBytes,D3D12_RESOURCE_FLAG_NONE,D3D12_RESOURCE_STATE_COPY_DEST);
  }
  bool pass=true;unsigned verified=0,reuses=0;
  auto retire=[&](FrameSlot& s){
    if(!s.retireFence)return;
    waitFor(s.retireFence); // 覆盖相机、Reset allocator以及读取旧结果之前的唯一完成条件。
    D3D12_RANGE range{0,SIZE_T(kOutputBytes)};void* data=nullptr;
    check(s.readback->Map(0,&range,reinterpret_cast<void**>(&data)),"Map ray readback");
    bool framePass=lighting?
      lighting_reference::verify(static_cast<lighting_reference::GpuRecord*>(data),cases[s.caseIndex],s.caseIndex+1,imagePrefix):
      surface_reference::verify(static_cast<surface_reference::GpuRecord*>(data),cases[s.caseIndex],s.caseIndex+1,imagePrefix);
    pass=framePass&&pass; // 即使先前失败，仍验证后续帧并排空GPU再正常释放。
    D3D12_RANGE noWrite{0,0};s.readback->Unmap(0,&noWrite);++verified;
    s.retireFence=0;
  };
  for(unsigned frame=0;frame<cases.size();++frame){
    UINT slotIndex=frame%kSlots;FrameSlot& s=slots[slotIndex];
    if(s.retireFence){++reuses;retire(s);} // frame0/1可依次提交；复用frame0槽前才等待其完成。
    const auto& view=preparedViews[frame];
    std::memcpy(mapped+slotIndex*cbStride,&view,sizeof(view));
    check(s.allocator->Reset(),"Reset retired allocator");
    check(s.list->Reset(s.allocator.Get(),nullptr),"Reset frame list");
    transition(s.list.Get(),s.output.Get(),s.outputState,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    s.list->SetComputeRootSignature(root.Get());
    s.list->SetComputeRootShaderResourceView(0,tlas->GetGPUVirtualAddress());
    s.list->SetComputeRootUnorderedAccessView(1,s.output->GetGPUVirtualAddress());
    D3D12_GPU_VIRTUAL_ADDRESS viewVA=viewUpload->GetGPUVirtualAddress()+slotIndex*cbStride;
    require(viewVA%256==0,"CBV address alignment");
    s.list->SetComputeRootConstantBufferView(2,viewVA); // 记录地址，不复制/冻结其中128B内容。
    // Root SRV仅给GPU地址；shader中的StructuredBuffer<float3>决定12B stride，raw IB用字节寻址。
    // Upload资源保持GENERIC_READ，同时支持AS构建输入和shader读取；Fence完成前不可释放。
    s.list->SetComputeRootShaderResourceView(3,vb->GetGPUVirtualAddress());
    s.list->SetComputeRootShaderResourceView(4,ib->GetGPUVirtualAddress());
    s.list->SetPipelineState1(state.Get());
    D3D12_GPU_VIRTUAL_ADDRESS base=shader_table->GetGPUVirtualAddress();
    D3D12_DISPATCH_RAYS_DESC dispatch{};
    dispatch.RayGenerationShaderRecord={base,32};dispatch.MissShaderTable={base+64,lighting?64u:32u,32};
    dispatch.HitGroupTable={base+128,32,32};dispatch.Width=kWidth;dispatch.Height=kHeight;dispatch.Depth=1;
    s.list->DispatchRays(&dispatch);
    // UAV->COPY_SOURCE transition同时建立本次UAV写与后续copy读的顺序，不另加重复UAV barrier。
    transition(s.list.Get(),s.output.Get(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_COPY_SOURCE);
    s.outputState=D3D12_RESOURCE_STATE_COPY_SOURCE;
    s.list->CopyResource(s.readback.Get(),s.output.Get());
    check(s.list->Close(),"Close frame list");
    ID3D12CommandList* frameLists[]={s.list.Get()};queue->ExecuteCommandLists(1,frameLists);
    s.retireFence=frame+2;s.caseIndex=frame;
    check(queue->Signal(fence.Get(),s.retireFence),"Signal frame fence");
    std::printf("submit frame=%u slot=%u cbOffset=%llu fence=%llu\n",frame+1,slotIndex,
      (unsigned long long)(slotIndex*cbStride),(unsigned long long)s.retireFence);
  }
  for(auto& s:slots)retire(s); // 最后两帧仍在途；必须排空后才能Unmap/释放相机和AS/SBT。
  D3D12_RANGE written{0,SIZE_T(kSlots*cbStride)};viewUpload->Unmap(0,&written);CloseHandle(event);
  std::printf("View payload=%zu stride=%llu slots=%u reused=%u verified=%u fence target=9 completed=%llu\n",
      sizeof(view_reference::ViewData),(unsigned long long)cbStride,kSlots,reuses,verified,(unsigned long long)fence->GetCompletedValue());
  require(verified==cases.size(),"Missing frame verification");verify_messages(info.Get());
  std::printf("%s: %s\n",lighting?"R.13.5 Lambert / rectangular NEE":"R.13.4 surface attributes / normals",pass?"PASS":"FAIL");return pass?0:1;
} catch(const std::exception& e){std::fprintf(stderr,"FAIL: %s\n",e.what());return 1;}
