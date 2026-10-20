// R.11 第三部分：独立窗口输出，双 Hit Group + Local Root Arguments，保留第一部分。
// 每帧提交后 fence 等待，命令行可指定自动结束帧数。
// R.11 窗口 DXR：BLAS -> TLAS -> DXIL library -> State Object -> SBT -> DispatchRays。
// 编译前用 Windows SDK 的 dxc -T lib_6_3 -Fo dxr_window.dxil dxr_window.hlsl；
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
#pragma comment(lib, "user32.lib")
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
// 固定客户区 840x480，避免此小节引入 ResizeBuffers 与 descriptor 重建。
// 关闭或 ESC 可退出；自动验收模式仍必须呈现完指定帧数，否则失败。
constexpr UINT width=840,height=480;
LRESULT CALLBACK window_proc(HWND hwnd,UINT msg,WPARAM wp,LPARAM lp) {
  if(msg==WM_CLOSE || (msg==WM_KEYDOWN && wp==VK_ESCAPE)) { DestroyWindow(hwnd); return 0; }
  if(msg==WM_DESTROY) { PostQuitMessage(0); return 0; }
  return DefWindowProcW(hwnd,msg,wp,lp);
}
struct Vertex { float x,y,z; };
int main(int argc,char** argv) {
  // 重定向 stdout 时也即时输出：异常退出不能让缓冲日志全部丢失。
  std::setvbuf(stdout,nullptr,_IONBF,0);
  std::setvbuf(stderr,nullptr,_IONBF,0);
  require(argc==2 || argc==3,"usage: dxr_window_pipeline.exe <dxr_window.dxil> [frame-count]");
  const UINT target_frames=argc==3 ? UINT(std::atoi(argv[2])) : 180;
  require(target_frames>0,"frame count must be positive");
  const bool swap_local=false; // 保留两项 local 数据，不提供第二部分对照选项。
  std::ifstream file(argv[1],std::ios::binary);
  require(file.good(),"DXIL file not found: compile HLSL with dxc -T lib_6_3 first");
  std::vector<char> dxil((std::istreambuf_iterator<char>(file)),std::istreambuf_iterator<char>());
  require(!dxil.empty(),"DXIL file is empty");
  ComPtr<ID3D12Debug> debug;
  check(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)),"Debug Layer required for acceptance");
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

  // Win32 创建真实 HWND；style 不含 sizing/maximize，固定客户区尺寸。
  HINSTANCE module=GetModuleHandleW(nullptr);
  WNDCLASSW wc{}; wc.lpfnWndProc=window_proc; wc.hInstance=module;
  wc.lpszClassName=L"DXRWindowLesson"; wc.hCursor=LoadCursor(nullptr,IDC_ARROW);
  require(RegisterClassW(&wc)!=0,"RegisterClass failed");
  DWORD style=WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU|WS_MINIMIZEBOX;
  RECT rect{0,0,LONG(width),LONG(height)}; require(AdjustWindowRect(&rect,style,FALSE)!=0,"AdjustWindowRect");
  HWND hwnd=CreateWindowExW(0,wc.lpszClassName,L"R.11 DXR - red HitGroupA / green HitGroupB",style,
    100,100,rect.right-rect.left,rect.bottom-rect.top,nullptr,nullptr,module,nullptr);
  require(hwnd!=nullptr,"CreateWindowEx failed"); ShowWindow(hwnd,SW_SHOW); UpdateWindow(hwnd);
  // Flip discard 两张 Back Buffer；不要求交换链图像本身支持 UAV。
  // RayGen 写离屏 UAV，再 CopyResource 到 Back Buffer：更通用且便于状态与读回验证。
  DXGI_SWAP_CHAIN_DESC1 sd{}; sd.Width=width; sd.Height=height;
  sd.Format=DXGI_FORMAT_R8G8B8A8_UNORM; sd.SampleDesc.Count=1;
  sd.BufferUsage=DXGI_USAGE_RENDER_TARGET_OUTPUT; sd.BufferCount=2;
  sd.SwapEffect=DXGI_SWAP_EFFECT_FLIP_DISCARD;
  ComPtr<IDXGISwapChain1> swap1;
  check(factory->CreateSwapChainForHwnd(queue.Get(),hwnd,&sd,nullptr,nullptr,&swap1),"CreateSwapChainForHwnd");
  ComPtr<IDXGISwapChain3> swap; check(swap1.As(&swap),"SwapChain3");
  check(factory->MakeWindowAssociation(hwnd,DXGI_MWA_NO_ALT_ENTER),"MakeWindowAssociation");
  D3D12_DESCRIPTOR_HEAP_DESC rh{}; rh.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV; rh.NumDescriptors=2;
  ComPtr<ID3D12DescriptorHeap> rtv_heap; check(dev->CreateDescriptorHeap(&rh,IID_PPV_ARGS(&rtv_heap)),"RTV heap");
  ComPtr<ID3D12Resource> back[2];
  auto rtv=rtv_heap->GetCPUDescriptorHandleForHeapStart();
  UINT rtv_step=dev->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
  for(UINT i=0;i<2;++i) {
    check(swap->GetBuffer(i,IID_PPV_ARGS(&back[i])),"GetBuffer");
    dev->CreateRenderTargetView(back[i].Get(),nullptr,rtv); rtv.ptr+=rtv_step;
  }
  // RTV 已创建以对应光栅化呈现资源；本例不 Draw、不 OMSetRenderTargets，复制不消费 RTV。
  std::printf("Window created: %ux%u; swapchain buffers=2; RTVs=2\n",width,height);

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
    in.Transform[0][3]=float(i*3); in.InstanceID=7; // ID 相同，证明选择不是 InstanceID 分支
    in.InstanceMask=0xff;
    in.InstanceContributionToHitGroupIndex=i; // 真正选择 Hit record 0/1
    in.AccelerationStructure=blas->GetGPUVirtualAddress();
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

  // root SRV(t0) 直接传 TLAS GPU VA；u0 纹理改为 descriptor table。
  // TLAS 不需堆描述符；输出纹理必须有堆中的 UAV；局部 b0 仍由 Hit record 提供。
  D3D12_ROOT_PARAMETER params[2]{};
  params[0].ParameterType=D3D12_ROOT_PARAMETER_TYPE_SRV;
  params[0].Descriptor.ShaderRegister=0; params[0].ShaderVisibility=D3D12_SHADER_VISIBILITY_ALL;
  // 纹理不能 root UAV GPU VA 直绑：参数1改成 descriptor table，范围覆盖 u0/space0。
  D3D12_DESCRIPTOR_RANGE range{}; range.RangeType=D3D12_DESCRIPTOR_RANGE_TYPE_UAV;
  range.NumDescriptors=1; range.BaseShaderRegister=0; range.RegisterSpace=0;
  range.OffsetInDescriptorsFromTableStart=0;
  params[1].ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
  params[1].DescriptorTable.NumDescriptorRanges=1; params[1].DescriptorTable.pDescriptorRanges=&range;
  params[1].ShaderVisibility=D3D12_SHADER_VISIBILITY_ALL;
  D3D12_ROOT_SIGNATURE_DESC rd{}; rd.NumParameters=2; rd.pParameters=params;
  ComPtr<ID3DBlob> root_blob,root_err;
  HRESULT hr=D3D12SerializeRootSignature(&rd,D3D_ROOT_SIGNATURE_VERSION_1,&root_blob,&root_err);
  if(FAILED(hr) && root_err) std::fprintf(stderr,"RootSig: %s\n",(char*)root_err->GetBufferPointer());
  check(hr,"SerializeRootSignature");
  ComPtr<ID3D12RootSignature> root;
  check(dev->CreateRootSignature(0,root_blob->GetBufferPointer(),root_blob->GetBufferSize(),IID_PPV_ARGS(&root)),"CreateRootSignature");

  // Local Root Signature 是 record 字节解释规则，不用 SetComputeRoot32BitConstants 绑定。
  // parameter 0: b0/space0 两个 DWORD，顺序与 HLSL material/cookie 和 SBT +32/+36 相同。
  // Global 只有 t0/u0，Local 只有 b0，无 register 重叠；二者共同满足 Hit shader 绑定。
  D3D12_ROOT_PARAMETER lp{};
  lp.ParameterType=D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
  lp.Constants.ShaderRegister=0; lp.Constants.RegisterSpace=0; lp.Constants.Num32BitValues=2;
  lp.ShaderVisibility=D3D12_SHADER_VISIBILITY_ALL;
  D3D12_ROOT_SIGNATURE_DESC lrd{}; lrd.NumParameters=1; lrd.pParameters=&lp;
  lrd.Flags=D3D12_ROOT_SIGNATURE_FLAG_LOCAL_ROOT_SIGNATURE;
  ComPtr<ID3DBlob> local_blob,local_error;
  hr=D3D12SerializeRootSignature(&lrd,D3D_ROOT_SIGNATURE_VERSION_1,&local_blob,&local_error);
  if(FAILED(hr) && local_error) std::fprintf(stderr,"Local RootSig: %s\n",(char*)local_error->GetBufferPointer());
  check(hr,"Serialize Local Root Signature");
  ComPtr<ID3D12RootSignature> local_root;
  check(dev->CreateRootSignature(0,local_blob->GetBufferPointer(),local_blob->GetBufferSize(),IID_PPV_ARGS(&local_root)),"Create Local Root Signature");

  D3D12_DXIL_LIBRARY_DESC lib{};
  lib.DXILLibrary={dxil.data(),dxil.size()}; // 导出 RayGen/Miss/ClosestHitA/ClosestHitB。
  D3D12_HIT_GROUP_DESC hits[2]{};
  hits[0].HitGroupExport=L"HitGroupA"; hits[0].ClosestHitShaderImport=L"ClosestHitA";
  hits[1].HitGroupExport=L"HitGroupB"; hits[1].ClosestHitShaderImport=L"ClosestHitB";
  for(auto& h:hits) h.Type=D3D12_HIT_GROUP_TYPE_TRIANGLES; // 固定功能求交，无 Intersection/AnyHit。
  D3D12_RAYTRACING_SHADER_CONFIG sc{16,8};
  D3D12_GLOBAL_ROOT_SIGNATURE gr{root.Get()};
  D3D12_LOCAL_ROOT_SIGNATURE lr{local_root.Get()};
  D3D12_RAYTRACING_PIPELINE_CONFIG pc{1}; // RayGen 一次 TraceRay，无递归。
  // 数组固定大小，不能 push_back 后让 association 指针失效。
  // local signature 明确关联到两个 Hit Group，RayGen/Miss 不使用局部 b0。
  D3D12_STATE_SUBOBJECT sub[8]{};
  sub[0]={D3D12_STATE_SUBOBJECT_TYPE_DXIL_LIBRARY,&lib};
  sub[1]={D3D12_STATE_SUBOBJECT_TYPE_HIT_GROUP,&hits[0]};
  sub[2]={D3D12_STATE_SUBOBJECT_TYPE_HIT_GROUP,&hits[1]};
  sub[3]={D3D12_STATE_SUBOBJECT_TYPE_RAYTRACING_SHADER_CONFIG,&sc};
  sub[4]={D3D12_STATE_SUBOBJECT_TYPE_GLOBAL_ROOT_SIGNATURE,&gr};
  sub[5]={D3D12_STATE_SUBOBJECT_TYPE_RAYTRACING_PIPELINE_CONFIG,&pc};
  sub[6]={D3D12_STATE_SUBOBJECT_TYPE_LOCAL_ROOT_SIGNATURE,&lr};
  const wchar_t* local_exports[]={L"HitGroupA",L"HitGroupB"};
  D3D12_SUBOBJECT_TO_EXPORTS_ASSOCIATION association{};
  association.pSubobjectToAssociate=&sub[6]; association.NumExports=2;
  association.pExports=local_exports;
  sub[7]={D3D12_STATE_SUBOBJECT_TYPE_SUBOBJECT_TO_EXPORTS_ASSOCIATION,&association};
  D3D12_STATE_OBJECT_DESC sod{}; sod.Type=D3D12_STATE_OBJECT_TYPE_RAYTRACING_PIPELINE;
  sod.NumSubobjects=8; sod.pSubobjects=sub;
  ComPtr<ID3D12StateObject> state;
  check(dev->CreateStateObject(&sod,IID_PPV_ARGS(&state)),"CreateStateObject");
  ComPtr<ID3D12StateObjectProperties> properties;
  check(state.As(&properties),"StateObjectProperties");

  // CPU 字节布局验证：不是把编译器的 struct padding 当成 SBT 契约。
  // 每条 Hit record = identifier[32] + material[4] + cookie[4] + padding[24] = 64B。
  // record stride 是 align_up(40,32)=64；表起点是 64B 对齐；两者本次数值相同但含义不同。
  constexpr UINT id_bytes=D3D12_SHADER_IDENTIFIER_SIZE_IN_BYTES;
  constexpr UINT hit_stride=64, hit_start=128;
  static_assert(id_bytes==32 && hit_stride % D3D12_RAYTRACING_SHADER_RECORD_BYTE_ALIGNMENT==0,"SBT record alignment");
  unsigned char sbt[256]{}; // RG 在 0，Miss 在 64，Hit 两条在 128/192。
  auto put_identifier=[&](UINT offset,const wchar_t* name) {
    const void* identifier=properties->GetShaderIdentifier(name);
    require(identifier!=nullptr,"Missing shader export identifier");
    std::memcpy(sbt+offset,identifier,id_bytes);
  };
  put_identifier(0,L"RayGen"); put_identifier(64,L"Miss");
  uint32_t args[2][2]={{0x11,0x5a},{0x22,0xa5}};
  if(swap_local) { std::swap(args[0][0],args[1][0]); std::swap(args[0][1],args[1][1]); }
  for(UINT i=0;i<2;++i) {
    UINT offset=hit_start+i*hit_stride;
    put_identifier(offset,local_exports[i]);
    std::memcpy(sbt+offset+id_bytes,args[i],sizeof(args[i]));
    std::printf("Hit record[%u]: offset=%u identifier=32 args=(0x%02x,0x%02x) padding=24 stride=64\n",i,offset,args[i][0],args[i][1]);
  }
  auto shader_table=upload(dev.Get(),sbt,sizeof(sbt));
  const auto sbt_base=shader_table->GetGPUVirtualAddress();
  require(sbt_base % D3D12_RAYTRACING_SHADER_TABLE_BYTE_ALIGNMENT==0,"SBT table base alignment");
  std::puts("Hit index: instance 0 -> record 0 / HitGroupA; instance 1 -> record 1 / HitGroupB; InstanceID=7 for both");
  // 格式是普通 UNORM，UAV 写 float4 会量化成 RGBA8；本课无 HDR/tone mapping/sRGB编码。
  D3D12_RESOURCE_DESC td{}; td.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;
  td.Width=width; td.Height=height; td.DepthOrArraySize=1; td.MipLevels=1;
  td.Format=DXGI_FORMAT_R8G8B8A8_UNORM; td.SampleDesc.Count=1;
  td.Flags=D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
  auto dh=heap(D3D12_HEAP_TYPE_DEFAULT); ComPtr<ID3D12Resource> output;
  check(dev->CreateCommittedResource(&dh,D3D12_HEAP_FLAG_NONE,&td,D3D12_RESOURCE_STATE_COMMON,nullptr,IID_PPV_ARGS(&output)),"UAV texture");
  D3D12_DESCRIPTOR_HEAP_DESC uh{}; uh.Type=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
  uh.NumDescriptors=1; uh.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
  ComPtr<ID3D12DescriptorHeap> uav_heap; check(dev->CreateDescriptorHeap(&uh,IID_PPV_ARGS(&uav_heap)),"shader visible heap");
  D3D12_UNORDERED_ACCESS_VIEW_DESC ud{}; ud.Format=td.Format; ud.ViewDimension=D3D12_UAV_DIMENSION_TEXTURE2D;
  dev->CreateUnorderedAccessView(output.Get(),nullptr,&ud,uav_heap->GetCPUDescriptorHandleForHeapStart());
  // 纹理读回不能当紧凑 buffer 直接 CopyResource；footprint 的 RowPitch 包含行填充。
  D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{}; UINT rows=0; UINT64 row_bytes=0,total=0;
  dev->GetCopyableFootprints(&td,0,1,0,&footprint,&rows,&row_bytes,&total);
  auto readback=make_buffer(dev.Get(),D3D12_HEAP_TYPE_READBACK,total,D3D12_RESOURCE_FLAG_NONE,D3D12_RESOURCE_STATE_COPY_DEST);
  UINT64 serial=0;
  auto submit_wait=[&]() {
    check(list->Close(),"Close"); ID3D12CommandList* lists[]={list.Get()}; queue->ExecuteCommandLists(1,lists);
    check(queue->Signal(fence.Get(),++serial),"Signal");
    check(fence->SetEventOnCompletion(serial,event),"SetEventOnCompletion");
    require(WaitForSingleObject(event,10000)==WAIT_OBJECT_0,"GPU fence timeout");
  };
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
  const auto base=shader_table->GetGPUVirtualAddress();
  // 静态 AS 只构建一次；等待后才开始复用 allocator，SBT/描述符全程保持不变。
  submit_wait();
  D3D12_DISPATCH_RAYS_DESC dispatch{};
  dispatch.RayGenerationShaderRecord={base,32}; dispatch.MissShaderTable={base+64,32,32};
  dispatch.HitGroupTable={base+hit_start,128,64};
  dispatch.Width=width; dispatch.Height=height; dispatch.Depth=1;
  UINT frames=0; bool quit=false;
  while(frames<target_frames && !quit) {
    MSG msg{}; while(PeekMessageW(&msg,nullptr,0,0,PM_REMOVE)) {
      if(msg.message==WM_QUIT) quit=true;
      TranslateMessage(&msg); DispatchMessageW(&msg);
    }
    if(quit) break;
    // 教学单帧串行：前次 GPU 已结束，才 Reset allocator/list；不冒充生产多帧并行。
    check(allocator->Reset(),"Reset allocator"); check(list->Reset(allocator.Get(),nullptr),"Reset list");
    transition(list.Get(),output.Get(),frames==0 ? D3D12_RESOURCE_STATE_COMMON : D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    ID3D12DescriptorHeap* heaps[]={uav_heap.Get()}; list->SetDescriptorHeaps(1,heaps);
    list->SetComputeRootSignature(root.Get());
    list->SetComputeRootShaderResourceView(0,tlas->GetGPUVirtualAddress()); // TLAS 仍 root SRV t0。
    list->SetComputeRootDescriptorTable(1,uav_heap->GetGPUDescriptorHandleForHeapStart()); // u0 纹理从堆取。
    list->SetPipelineState1(state.Get()); list->DispatchRays(&dispatch);
    transition(list.Get(),output.Get(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_COPY_SOURCE);
    UINT index=swap->GetCurrentBackBufferIndex();
    transition(list.Get(),back[index].Get(),D3D12_RESOURCE_STATE_PRESENT,D3D12_RESOURCE_STATE_COPY_DEST);
    list->CopyResource(back[index].Get(),output.Get()); // 相同尺寸/格式/采样数。
    // 每帧复制同一输出供最终 CPU 验证；读回状态固定 COPY_DEST。
    D3D12_TEXTURE_COPY_LOCATION dst{}; dst.pResource=readback.Get(); dst.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT; dst.PlacedFootprint=footprint;
    D3D12_TEXTURE_COPY_LOCATION src{}; src.pResource=output.Get(); src.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    list->CopyTextureRegion(&dst,0,0,0,&src,nullptr);
    transition(list.Get(),back[index].Get(),D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_PRESENT);
    submit_wait(); // command list 已提交且 GPU 完成，才 Present；简化但正确。
    HRESULT presented=swap->Present(1,0); check(presented,"Present");
    require(presented==S_OK,"Present did not report S_OK (possibly occluded)");
    ++frames;
    if(frames==1 || frames%60==0 || frames==target_frames) std::printf("Frame %u: DispatchRays %ux%u, Present S_OK, fence=%llu\n",frames,width,height,(unsigned long long)serial);
  }
  require(frames==target_frames,"Window closed before requested frame count");
  // CPU 检查两个三角形内部像素与背景；RowPitch 用 footprint，不假定 width*4。
  unsigned char* pixels=nullptr; D3D12_RANGE read{0,SIZE_T(total)};
  check(readback->Map(0,&read,(void**)&pixels),"Map texture readback");
  auto pixel=[&](UINT x,UINT y) { return pixels+footprint.Offset+y*footprint.Footprint.RowPitch+x*4; };
  auto a=pixel(240,240); auto b=pixel(600,240); auto bg=pixel(10,10);
  std::printf("Readback A=(%u,%u,%u,%u) B=(%u,%u,%u,%u) Miss=(%u,%u,%u,%u) RowPitch=%u\n",a[0],a[1],a[2],a[3],b[0],b[1],b[2],b[3],bg[0],bg[1],bg[2],bg[3],footprint.Footprint.RowPitch);
  bool pass=a[0]>180 && a[1]<50 && b[1]>160 && b[0]<30 && bg[0]<20 && bg[2]>20 && a[3]==255 && b[3]==255;
  // GPU 输出 PPM 是渲染结果证据，不将它称作桌面/窗口截图。
  std::ofstream image("learning/sandbox/d3d12/r11-03-window/dxr_window_output.ppm",std::ios::binary);
  image<<"P6\n"<<width<<" "<<height<<"\n255\n";
  for(UINT y=0;y<height;++y) for(UINT x=0;x<width;++x) image.write((char*)pixel(x,y),3);
  require(image.good(),"write PPM failed"); image.close();
  D3D12_RANGE wrote{0,0}; readback->Unmap(0,&wrote);
  verify_messages(info.Get()); require(pass,"color readback mismatch");
  std::printf("Render validation complete; frames=%u; color readback=PASS\n",frames);
  // Present 也向同一 direct queue 引入工作；先前 fence 只覆盖 Present 之前的渲染。
  // 必须在最后一次 Present 之后再次 Signal/等待，再销毁交换链及队列。
  check(queue->Signal(fence.Get(),++serial),"Signal after final Present");
  check(fence->SetEventOnCompletion(serial,event),"Final Present fence event");
  require(WaitForSingleObject(event,10000)==WAIT_OBJECT_0,"Final Present fence timeout");
  std::printf("Final Present drained: fence=%llu completed=%llu\n",(unsigned long long)serial,(unsigned long long)fence->GetCompletedValue());
  // 显式记录销毁阶段，区分渲染成功与退出时 COM 生命周期错误。
  std::puts("Shutdown: release swapchain");
  // 正常退出统一按 back buffer 引用、交换链、窗口的顺序释放；不借此推断所有 DXGI 实现的内部所有权。
  std::puts("release back0"); back[0].Reset();
  std::puts("release back1"); back[1].Reset();
  std::puts("release swap3"); swap.Reset();
  std::puts("release swap1"); swap1.Reset();
  std::puts("Shutdown: destroy window");
  CloseHandle(event); if(IsWindow(hwnd)) DestroyWindow(hwnd);
  UnregisterClassW(wc.lpszClassName,module);
  // 逐步释放 GPU 对象后检查退出，避免仅在 main 返回后的隐式析构中丢失定位信息。
  std::puts("Shutdown: release GPU resources");
  std::puts("release readback/output/SBT"); readback.Reset(); output.Reset(); shader_table.Reset();
  std::puts("release heaps"); uav_heap.Reset(); rtv_heap.Reset();
  std::puts("release state/roots"); state.Reset(); properties.Reset(); local_root.Reset(); root.Reset();
  std::puts("release AS/uploads"); tlas.Reset(); ts.Reset(); blas.Reset(); bs.Reset(); instance.Reset(); vb.Reset(); ib.Reset();
  std::puts("release list"); list.Reset();
  std::puts("release allocator"); allocator.Reset();
  std::puts("release queue"); queue.Reset();
  std::puts("release fence"); fence.Reset();
  std::puts("Shutdown: release device");
  verify_messages(info.Get());
  info.Reset(); dev.Reset(); adapter.Reset(); factory.Reset(); debug.Reset();
  std::printf("DXR window: PASS; frames=%u; shutdown complete; exit=0\n",frames);
  return 0;
}
