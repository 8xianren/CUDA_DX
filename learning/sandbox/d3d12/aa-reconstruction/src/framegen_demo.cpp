// F.9 官方帧生成最小工程：D3D12 实时场景 -> FG Prepare -> 官方插值 -> 后置 UI -> 代理交换链。
// 这是用于隔离 Present/队列/测量契约的独立程序，不复制 F.1-F.8 的抗锯齿器。
// 注意：显示回调次数是交给交换链的显示帧数，不能证明屏幕实际扫描了全部帧。
#include <windows.h>
#include <wrl/client.h>
#include <d3d12.h>
#include <d3d12sdklayers.h>
#include <dxgi1_6.h>
#include <d3dcompiler.h>
#include <api/include/ffx_api.h>
#include <api/include/dx12/ffx_api_dx12.h>
#include <framegeneration/include/ffx_framegeneration.h>
#include <framegeneration/include/dx12/ffx_api_framegeneration_dx12.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
using Microsoft::WRL::ComPtr;
namespace fs = std::filesystem;
constexpr UINT Width=1280, Height=720, MaxFrames=600, CaptureFrame=60;
static void Hr(HRESULT hr,const char* call) {
    if(FAILED(hr)) { char s[96]; sprintf_s(s,"%s HRESULT=0x%08X",call,unsigned(hr)); throw std::runtime_error(s); }
}
static void Fx(ffxReturnCode_t rc,const char* call) {
    if(rc) throw std::runtime_error(std::string(call)+" ffxReturnCode="+std::to_string(rc));
}
static double NowMs() {
    LARGE_INTEGER q,f; QueryPerformanceCounter(&q); QueryPerformanceFrequency(&f);
    return 1000.0*double(q.QuadPart)/double(f.QuadPart);
}
static std::atomic<unsigned> FfxErrors{0};
static void FfxMessage(uint32_t type,const wchar_t* msg) {
    if(type==FFX_API_MESSAGE_TYPE_ERROR) ++FfxErrors;
    std::wcerr << L"[FFX] " << msg << L"\n";
}
struct Api {
    HMODULE dll=nullptr;
    PfnFfxCreateContext create=nullptr; PfnFfxDestroyContext destroy=nullptr;
    PfnFfxConfigure configure=nullptr; PfnFfxQuery query=nullptr; PfnFfxDispatch dispatch=nullptr;
    Api() {
        // 只加载 exe 同目录固定版本 DLL，避免依赖当前工作目录或系统 PATH 中的同名库。
        wchar_t exe[MAX_PATH]; GetModuleFileNameW(nullptr,exe,MAX_PATH);
        auto path=fs::path(exe).parent_path()/L"amd_fidelityfx_loader_dx12.dll";
        dll=LoadLibraryExW(path.c_str(),nullptr,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        if(!dll) throw std::runtime_error("LoadLibrary FFX loader failed: "+std::to_string(GetLastError()));
        create=reinterpret_cast<PfnFfxCreateContext>(GetProcAddress(dll,"ffxCreateContext"));
        destroy=reinterpret_cast<PfnFfxDestroyContext>(GetProcAddress(dll,"ffxDestroyContext"));
        configure=reinterpret_cast<PfnFfxConfigure>(GetProcAddress(dll,"ffxConfigure"));
        query=reinterpret_cast<PfnFfxQuery>(GetProcAddress(dll,"ffxQuery"));
        dispatch=reinterpret_cast<PfnFfxDispatch>(GetProcAddress(dll,"ffxDispatch"));
        if(!create||!destroy||!configure||!query||!dispatch) throw std::runtime_error("FFX exports incomplete");
        ffxConfigureDescGlobalDebug cfg{}; cfg.header.type=FFX_API_CONFIGURE_DESC_TYPE_GLOBALDEBUG;
        cfg.fpMessage=FfxMessage; cfg.debugLevel=FFX_API_CONFIGURE_GLOBALDEBUG_LEVEL_WARNINGS;
        cfg.effectId=FFX_API_EFFECT_ID_FRAMEGENERATION; Fx(configure(nullptr,&cfg.header),"FFX debug config");
    }
    ~Api(){if(dll) FreeLibrary(dll);}
};
static void Barrier(ID3D12GraphicsCommandList* list,ID3D12Resource* r,D3D12_RESOURCE_STATES a,D3D12_RESOURCE_STATES b) {
    if(a==b) return;
    D3D12_RESOURCE_BARRIER x{}; x.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    x.Transition={r,D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,a,b}; list->ResourceBarrier(1,&x);
}
static D3D12_RESOURCE_STATES State(uint32_t f) {
    UINT r=0;
    if(f&FFX_API_RESOURCE_STATE_UNORDERED_ACCESS) r|=D3D12_RESOURCE_STATE_UNORDERED_ACCESS;
    if(f&FFX_API_RESOURCE_STATE_COMPUTE_READ) r|=D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
    if(f&FFX_API_RESOURCE_STATE_PIXEL_READ) r|=D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE;
    if(f&FFX_API_RESOURCE_STATE_COPY_SRC) r|=D3D12_RESOURCE_STATE_COPY_SOURCE;
    if(f&FFX_API_RESOURCE_STATE_COPY_DEST) r|=D3D12_RESOURCE_STATE_COPY_DEST;
    if(f&FFX_API_RESOURCE_STATE_RENDER_TARGET) r|=D3D12_RESOURCE_STATE_RENDER_TARGET;
    return D3D12_RESOURCE_STATES(r); // COMMON 和 PRESENT 都是 D3D12 的 0，不是 FFX 枚举的 0。
}
static LRESULT CALLBACK WindowProc(HWND h,UINT m,WPARAM w,LPARAM l) {
    if(m==WM_CLOSE){DestroyWindow(h);return 0;} if(m==WM_DESTROY){PostQuitMessage(0);return 0;}
    return DefWindowProcW(h,m,w,l);
}
struct DisplayEvent {uint64_t frame; bool generated; double qpcMs;};
struct RealEvent {uint64_t frame; double sampleMs,submitMs,presentBeginMs,presentEndMs;};
struct ScanoutEvent {UINT presentId,refresh,syncRefresh;double syncQpcMs,observedQpcMs;};
struct Demo {
    // api 必须晚于上下文销毁；全部应用对象/回调用户指针活到 WaitForPresents 后。
    Api api;
    HWND window=nullptr;
    ComPtr<IDXGIFactory6> factory;
    ComPtr<ID3D12Device> device; ComPtr<ID3D12InfoQueue> info;
    ComPtr<ID3D12CommandQueue> queue;
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList> list;
    ComPtr<ID3D12Fence> fence; HANDLE fenceEvent=nullptr,latencyEvent=nullptr,frameTimer=nullptr; uint64_t fenceValue=0;
    IDXGISwapChain4* swap=nullptr; // SDK context 拥有代理交换链；不把它和独立 ComPtr 双重释放。
    ffxContext swapContext=nullptr,fgContext=nullptr;
    ffxCreateBackendDX12Desc backend{};
    ffxCreateContextDescFrameGeneration fgCreate{};
    ffxCreateContextDescFrameGenerationVersion fgVersion{};
    ffxCreateContextDescFrameGenerationSwapChainForHwndDX12 swapCreate{};
    ffxCreateContextDescFrameGenerationSwapChainVersionDX12 swapVersion{};
    DXGI_SWAP_CHAIN_DESC1 swapDesc{};
    ffxConfigureDescFrameGeneration fgConfig{};
    ComPtr<ID3D12DescriptorHeap> rtvHeap; UINT rtvStride=0;
    ComPtr<ID3D12Resource> color,depth,motion;
    ComPtr<ID3D12RootSignature> root; ComPtr<ID3D12PipelineState> pso;
    ComPtr<ID3D12QueryHeap> timestamps; ComPtr<ID3D12Resource> timestampReadback;
    // 每个真实帧四个独立 query：scene+prepare 起止，官方 FG 起止，绝不复用尚在执行的槽。
    UINT64 gpuFrequency=0;
    std::array<ComPtr<ID3D12Resource>,3> captures; // previous real / generated / current real。
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{}; UINT64 captureBytes=0;
    std::array<bool,3> captured{};
    std::vector<DisplayEvent> displayEvents; std::vector<RealEvent> realEvents;
    std::vector<ScanoutEvent> scanoutEvents;
    std::thread statisticsThread;std::atomic<bool> stopStatistics{false};
    unsigned statisticsFailures=0;double maxStatisticsPollGapMs=0;
    std::mutex eventsMutex;
    std::atomic<unsigned> callbackErrors{0},generationCalls{0},generatedRequests{0};
    std::string provider,swapProvider,adapterName;
    bool enabled=true,debug=true,closed=false;
    UINT frames=180,lastPresentCount=0; HRESULT statisticsHr=E_FAIL; DXGI_FRAME_STATISTICS statistics{};
    fs::path output,shader;
    Demo(bool fg,bool validation,UINT n,fs::path out,fs::path sh):enabled(fg),debug(validation),frames(n),output(std::move(out)),shader(std::move(sh)) {
        displayEvents.reserve(MaxFrames*2); realEvents.reserve(MaxFrames);scanoutEvents.reserve(MaxFrames*3);
        try {InitD3D(); InitFfx(); InitScene();}
        catch(...) {try{Close();}catch(...){} throw;}
    }
    ComPtr<ID3D12Resource> Resource(D3D12_RESOURCE_DESC d,D3D12_HEAP_TYPE heap,D3D12_RESOURCE_STATES state) {
        D3D12_HEAP_PROPERTIES h{};h.Type=heap;h.CreationNodeMask=h.VisibleNodeMask=1;
        ComPtr<ID3D12Resource> r;Hr(device->CreateCommittedResource(&h,D3D12_HEAP_FLAG_NONE,&d,state,nullptr,IID_PPV_ARGS(&r)),"CreateResource");return r;
    }
    ComPtr<ID3D12Resource> Buffer(UINT64 bytes) {
        D3D12_RESOURCE_DESC d{};d.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;d.Width=bytes;d.Height=1;
        d.DepthOrArraySize=d.MipLevels=1;d.SampleDesc.Count=1;d.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        return Resource(d,D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
    }
    ComPtr<ID3D12Resource> Texture(DXGI_FORMAT format) {
        D3D12_RESOURCE_DESC d{};d.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;d.Width=Width;d.Height=Height;
        d.DepthOrArraySize=d.MipLevels=1;d.SampleDesc.Count=1;d.Format=format;d.Flags=D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
        return Resource(d,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_RENDER_TARGET);
    }
    D3D12_CPU_DESCRIPTOR_HANDLE Rtv(UINT i){auto h=rtvHeap->GetCPUDescriptorHandleForHeapStart();h.ptr+=SIZE_T(i)*rtvStride;return h;}
    void FlushMain() {
        Hr(queue->Signal(fence.Get(),++fenceValue),"Signal");
        if(fence->GetCompletedValue()<fenceValue){Hr(fence->SetEventOnCompletion(fenceValue,fenceEvent),"Fence event");
            if(WaitForSingleObject(fenceEvent,30000)!=WAIT_OBJECT_0)throw std::runtime_error("main queue fence timeout");}
    }
    void InitD3D() {
        if(debug){ComPtr<ID3D12Debug> d;Hr(D3D12GetDebugInterface(IID_PPV_ARGS(&d)),"Debug layer");d->EnableDebugLayer();}
        Hr(CreateDXGIFactory2(debug?DXGI_CREATE_FACTORY_DEBUG:0,IID_PPV_ARGS(&factory)),"Factory");
        ComPtr<IDXGIAdapter1> adapter;Hr(factory->EnumAdapterByGpuPreference(0,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&adapter)),"Adapter");
        DXGI_ADAPTER_DESC1 desc{};adapter->GetDesc1(&desc);for(auto c:desc.Description){if(!c)break;adapterName+=char(c<128?c:'?');}
        Hr(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_12_0,IID_PPV_ARGS(&device)),"Device");
        if(debug)device.As(&info);
        D3D12_COMMAND_QUEUE_DESC q{};q.Type=D3D12_COMMAND_LIST_TYPE_DIRECT;Hr(device->CreateCommandQueue(&q,IID_PPV_ARGS(&queue)),"Queue");
        Hr(device->CreateCommandAllocator(q.Type,IID_PPV_ARGS(&allocator)),"Allocator");
        Hr(device->CreateCommandList(0,q.Type,allocator.Get(),nullptr,IID_PPV_ARGS(&list)),"List");Hr(list->Close(),"initial Close");
        Hr(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&fence)),"Fence");fenceEvent=CreateEventW(nullptr,FALSE,FALSE,nullptr);
        Hr(queue->GetTimestampFrequency(&gpuFrequency),"TimestampFrequency");
        WNDCLASSW wc{};wc.hInstance=GetModuleHandleW(nullptr);wc.lpfnWndProc=WindowProc;wc.lpszClassName=L"F9FrameGeneration";
        RegisterClassW(&wc);RECT rect{0,0,Width,Height};AdjustWindowRect(&rect,WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU,FALSE);
        window=CreateWindowW(wc.lpszClassName,enabled?L"F.9 Official FSR Frame Generation ON":L"F.9 Official FSR Frame Generation OFF",
            WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU,CW_USEDEFAULT,CW_USEDEFAULT,rect.right-rect.left,rect.bottom-rect.top,nullptr,nullptr,wc.hInstance,nullptr);
        if(!window)throw std::runtime_error("CreateWindow failed");ShowWindow(window,SW_SHOW);
        // 自动验收窗口短暂置顶，避免被编辑器完全遮挡而触发 DWM 的可见性节流。
        // 这只作用于本实验窗口；程序退出即销毁，不修改用户其他窗口的状态。
        if(!SetWindowPos(window,HWND_TOPMOST,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_SHOWWINDOW))
            throw std::runtime_error("Could not make measurement window visible");
        frameTimer=CreateWaitableTimerExW(nullptr,nullptr,CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,TIMER_ALL_ACCESS);
        if(!frameTimer)throw std::runtime_error("High-resolution frame timer unavailable");
    }
    std::string Provider(ffxContext* context) {
        ffxQueryGetProviderVersion q{};q.header.type=FFX_API_QUERY_DESC_TYPE_GET_PROVIDER_VERSION;
        Fx(api.query(context,&q.header),"query provider");return q.versionName?q.versionName:"unknown";
    }
    void InitFfx() {
        swapDesc.Width=Width;swapDesc.Height=Height;swapDesc.Format=DXGI_FORMAT_R8G8B8A8_UNORM;
        swapDesc.SampleDesc.Count=1;swapDesc.BufferUsage=DXGI_USAGE_RENDER_TARGET_OUTPUT;swapDesc.BufferCount=3;
        swapDesc.SwapEffect=DXGI_SWAP_EFFECT_FLIP_DISCARD;swapDesc.Flags=DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;
        swapCreate.header.type=FFX_API_CREATE_CONTEXT_DESC_TYPE_FRAMEGENERATIONSWAPCHAIN_FOR_HWND_DX12;
        swapCreate.swapchain=&swap;swapCreate.hwnd=window;swapCreate.desc=&swapDesc;swapCreate.dxgiFactory=factory.Get();swapCreate.gameQueue=queue.Get();
        swapVersion.header.type=FFX_API_CREATE_CONTEXT_DESC_TYPE_FRAMEGENERATIONSWAPCHAIN_VERSION_DX12;
        swapVersion.version=FFX_FRAMEGENERATION_SWAPCHAIN_DX12_VERSION;swapCreate.header.pNext=&swapVersion.header;
        Fx(api.create(&swapContext,&swapCreate.header,nullptr),"create FG swapchain");
        factory->MakeWindowAssociation(window,DXGI_MWA_NO_ALT_ENTER);
        Hr(swap->SetMaximumFrameLatency(2),"SetMaximumFrameLatency");latencyEvent=swap->GetFrameLatencyWaitableObject();
        fgCreate.header.type=FFX_API_CREATE_CONTEXT_DESC_TYPE_FRAMEGENERATION;
        fgCreate.displaySize=fgCreate.maxRenderSize={Width,Height};fgCreate.backBufferFormat=FFX_API_SURFACE_FORMAT_R8G8B8A8_UNORM;
        fgCreate.flags=FFX_FRAMEGENERATION_ENABLE_DISPLAY_RESOLUTION_MOTION_VECTORS|FFX_FRAMEGENERATION_ENABLE_DEBUG_CHECKING;
        backend.header.type=FFX_API_CREATE_CONTEXT_DESC_TYPE_BACKEND_DX12;backend.device=device.Get();
        fgVersion.header.type=FFX_API_CREATE_CONTEXT_DESC_TYPE_FRAMEGENERATION_VERSION;fgVersion.version=FFX_FRAMEGENERATION_VERSION;
        fgCreate.header.pNext=&fgVersion.header;fgVersion.header.pNext=&backend.header;
        Fx(api.create(&fgContext,&fgCreate.header,nullptr),"create FG context");
        provider=Provider(&fgContext);swapProvider=Provider(&swapContext);
        std::cout<<"GPU: "<<adapterName<<"\nFG provider: "<<provider<<"\nSwapchain provider: "<<swapProvider<<"\n";
        fgConfig.header.type=FFX_API_CONFIGURE_DESC_TYPE_FRAMEGENERATION;fgConfig.swapChain=swap;
        fgConfig.frameGenerationEnabled=enabled;fgConfig.allowAsyncWorkloads=false;
        fgConfig.presentCallback=PresentCallback;fgConfig.presentCallbackUserContext=this;
        fgConfig.frameGenerationCallback=GenerateCallback;fgConfig.frameGenerationCallbackUserContext=this;
        fgConfig.generationRect={0,0,Width,Height};
    }
    void InitScene() {
        D3D12_DESCRIPTOR_HEAP_DESC h{};h.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV;h.NumDescriptors=4;
        Hr(device->CreateDescriptorHeap(&h,IID_PPV_ARGS(&rtvHeap)),"RTV heap");rtvStride=device->GetDescriptorHandleIncrementSize(h.Type);
        color=Texture(DXGI_FORMAT_R8G8B8A8_UNORM);depth=Texture(DXGI_FORMAT_R32_FLOAT);motion=Texture(DXGI_FORMAT_R16G16_FLOAT);
        device->CreateRenderTargetView(color.Get(),nullptr,Rtv(0));device->CreateRenderTargetView(depth.Get(),nullptr,Rtv(1));device->CreateRenderTargetView(motion.Get(),nullptr,Rtv(2));
        D3D12_ROOT_PARAMETER p{};p.ParameterType=D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;p.Constants={0,0,4};p.ShaderVisibility=D3D12_SHADER_VISIBILITY_PIXEL;
        D3D12_ROOT_SIGNATURE_DESC rs{};rs.NumParameters=1;rs.pParameters=&p;
        ComPtr<ID3DBlob> blob,error;Hr(D3D12SerializeRootSignature(&rs,D3D_ROOT_SIGNATURE_VERSION_1,&blob,&error),"Serialize RS");
        Hr(device->CreateRootSignature(0,blob->GetBufferPointer(),blob->GetBufferSize(),IID_PPV_ARGS(&root)),"RootSignature");
        auto compile=[&](const char* entry,const char* target){ComPtr<ID3DBlob>b,e;
            HRESULT hr=D3DCompileFromFile(shader.c_str(),nullptr,D3D_COMPILE_STANDARD_FILE_INCLUDE,entry,target,D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&b,&e);
            if(FAILED(hr)&&e)std::cerr<<static_cast<char*>(e->GetBufferPointer());Hr(hr,"D3DCompile scene");return b;};
        auto vs=compile("VSMain","vs_5_1"),ps=compile("PSMain","ps_5_1");
        D3D12_GRAPHICS_PIPELINE_STATE_DESC pd{};pd.pRootSignature=root.Get();pd.VS={vs->GetBufferPointer(),vs->GetBufferSize()};pd.PS={ps->GetBufferPointer(),ps->GetBufferSize()};
        pd.SampleMask=UINT_MAX;pd.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;pd.RasterizerState.CullMode=D3D12_CULL_MODE_NONE;pd.RasterizerState.DepthClipEnable=TRUE;
        for(auto&rt:pd.BlendState.RenderTarget)rt.RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;
        pd.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;pd.NumRenderTargets=3;
        pd.RTVFormats[0]=DXGI_FORMAT_R8G8B8A8_UNORM;pd.RTVFormats[1]=DXGI_FORMAT_R32_FLOAT;pd.RTVFormats[2]=DXGI_FORMAT_R16G16_FLOAT;pd.SampleDesc.Count=1;
        Hr(device->CreateGraphicsPipelineState(&pd,IID_PPV_ARGS(&pso)),"Scene PSO");
        D3D12_QUERY_HEAP_DESC q{};q.Type=D3D12_QUERY_HEAP_TYPE_TIMESTAMP;q.Count=MaxFrames*4;
        Hr(device->CreateQueryHeap(&q,IID_PPV_ARGS(&timestamps)),"QueryHeap");timestampReadback=Buffer(MaxFrames*4*sizeof(uint64_t));
        auto desc=color->GetDesc();device->GetCopyableFootprints(&desc,0,1,0,&footprint,nullptr,nullptr,&captureBytes);
        for(auto& c:captures)c=Buffer(captureBytes);
    }
    static ffxReturnCode_t GenerateCallback(ffxDispatchDescFrameGeneration* params,void* user) {
        auto& d=*static_cast<Demo*>(user);auto* cmd=static_cast<ID3D12GraphicsCommandList*>(params->commandList);
        const UINT slot=UINT(params->frameID)*4+2;
        if(slot+1>=MaxFrames*4){++d.callbackErrors;return FFX_API_RETURN_ERROR_PARAMETER;}
        cmd->EndQuery(d.timestamps.Get(),D3D12_QUERY_TYPE_TIMESTAMP,slot);
        const auto rc=d.api.dispatch(&d.fgContext,&params->header);
        cmd->EndQuery(d.timestamps.Get(),D3D12_QUERY_TYPE_TIMESTAMP,slot+1);
        cmd->ResolveQueryData(d.timestamps.Get(),D3D12_QUERY_TYPE_TIMESTAMP,slot,2,d.timestampReadback.Get(),slot*sizeof(uint64_t));
        ++d.generationCalls;d.generatedRequests+=params->numGeneratedFrames;
        if(rc)++d.callbackErrors;return rc;
    }
    static ffxReturnCode_t PresentCallback(ffxCallbackDescFrameGenerationPresent* params,void* user) {
        auto& d=*static_cast<Demo*>(user);auto* cmd=static_cast<ID3D12GraphicsCommandList*>(params->commandList);
        auto* src=static_cast<ID3D12Resource*>(params->currentBackBuffer.resource);
        auto* dst=static_cast<ID3D12Resource*>(params->outputSwapChainBuffer.resource);
        if(!src||!dst){++d.callbackErrors;return FFX_API_RETURN_ERROR_PARAMETER;}
        // 回调由 SDK present worker 调用。不得改主线程 allocator/list；这里只录入 SDK 传入的列表。
        // callback 要恢复 SDK 告知的资源状态，不能假设输出已处于 RT 或输入已处于 COPY_SOURCE。
        const auto a=State(params->currentBackBuffer.state),b=State(params->outputSwapChainBuffer.state);
        Barrier(cmd,src,a,D3D12_RESOURCE_STATE_COPY_SOURCE);Barrier(cmd,dst,b,D3D12_RESOURCE_STATE_COPY_DEST);
        cmd->CopyResource(dst,src);Barrier(cmd,src,D3D12_RESOURCE_STATE_COPY_SOURCE,a);
        Barrier(cmd,dst,D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_RENDER_TARGET);
        // CPU-only RTV descriptor 在录制时即被消费。单 present worker 串行录制此槽，避免跨线程改描述符。
        d.device->CreateRenderTargetView(dst,nullptr,d.Rtv(3));
        const float cyan[4]={0,1,1,1},white[4]={1,1,1,1};
        const D3D12_RECT bar{20,20,300,50},cross[2]={{635,345,645,375},{625,355,655,365}};
        cmd->ClearRenderTargetView(d.Rtv(3),cyan,1,&bar);cmd->ClearRenderTargetView(d.Rtv(3),white,2,cross);
        int capture=-1;
        if(params->frameID==CaptureFrame-1&&!params->isGeneratedFrame)capture=0;
        if(params->frameID==CaptureFrame)capture=params->isGeneratedFrame?1:2;
        if(capture>=0){Barrier(cmd,dst,D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_COPY_SOURCE);
            D3D12_TEXTURE_COPY_LOCATION target{};target.pResource=d.captures[capture].Get();target.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;target.PlacedFootprint=d.footprint;
            D3D12_TEXTURE_COPY_LOCATION source{};source.pResource=dst;source.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
            cmd->CopyTextureRegion(&target,0,0,0,&source,nullptr);Barrier(cmd,dst,D3D12_RESOURCE_STATE_COPY_SOURCE,b);d.captured[capture]=true;
        }else Barrier(cmd,dst,D3D12_RESOURCE_STATE_RENDER_TARGET,b);
        {std::lock_guard<std::mutex> lock(d.eventsMutex);d.displayEvents.push_back({params->frameID,params->isGeneratedFrame,NowMs()});}
        return FFX_API_RETURN_OK;
    }
    void Run() {
        // 给独立 ETW 采集器按 PID 附着的时间；这 1 秒不进入逐帧统计。
        std::this_thread::sleep_for(std::chrono::seconds(1));
        (void)swap->GetFrameStatistics(&statistics); // 第一次通常返回 DISJOINT，建立统计序列。
        statisticsThread=std::thread([this]{
            LARGE_INTEGER frequency;QueryPerformanceFrequency(&frequency);
            HANDLE pollTimer=CreateWaitableTimerExW(nullptr,nullptr,CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,TIMER_ALL_ACCESS);
            LARGE_INTEGER due{};due.QuadPart=-10000; // 相对时间单位 100ns；1ms，避免系统粗粒度 Sleep 漏过 120Hz 刷新。
            if(pollTimer&&!SetWaitableTimer(pollTimer,&due,1,nullptr,nullptr,FALSE)){CloseHandle(pollTimer);pollTimer=nullptr;}
            UINT previousId=0;double previousPoll=NowMs();
            while(!stopStatistics.load()){
                DXGI_FRAME_STATISTICS s{};const auto hr=swap->GetFrameStatistics(&s);const double now=NowMs();
                maxStatisticsPollGapMs=std::max(maxStatisticsPollGapMs,now-previousPoll);previousPoll=now;
                if(SUCCEEDED(hr)&&s.PresentCount!=0&&s.PresentCount!=previousId){
                    scanoutEvents.push_back({s.PresentCount,s.PresentRefreshCount,s.SyncRefreshCount,
                        1000.0*double(s.SyncQPCTime.QuadPart)/double(frequency.QuadPart),now});previousId=s.PresentCount;
                }else if(FAILED(hr))++statisticsFailures;
                // 轮询只读取 DXGI 系统统计，不调用 FFX context，不碰渲染/显示回调的命令列表。
                // 仍可能漏掉两次轮询间的快速显示变化，最终指标明确命名“观测下界”。
                if(pollTimer)WaitForSingleObject(pollTimer,100);else std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
            if(pollTimer){CancelWaitableTimer(pollTimer);CloseHandle(pollTimer);}
        });
        const auto start=std::chrono::steady_clock::now();
        for(UINT i=0;i<frames;++i){
            MSG msg{};while(PeekMessageW(&msg,nullptr,0,0,PM_REMOVE)){if(msg.message==WM_QUIT)throw std::runtime_error("Window closed before acceptance completed");TranslateMessage(&msg);DispatchMessageW(&msg);}
            // 60 Hz 真实模拟/输入采样；生成帧不会再次执行这里，不会提高输入采样率。
            const auto deadline=start+std::chrono::microseconds(uint64_t(i)*16667);
            const auto remaining=std::chrono::duration_cast<std::chrono::nanoseconds>(deadline-std::chrono::steady_clock::now()).count();
            if(remaining>0){
                // std::sleep_until 在系统 timer 粗粒度下可能形成 30ms/1ms 的交替间隔。
                // 高分辨率 waitable timer 以相对 100ns 单位等待，不忙等，不要求全局 timeBeginPeriod。
                LARGE_INTEGER due{};due.QuadPart=-std::max<int64_t>(1,(remaining+99)/100);
                if(!SetWaitableTimer(frameTimer,&due,0,nullptr,nullptr,FALSE)||WaitForSingleObject(frameTimer,30000)!=WAIT_OBJECT_0)
                    throw std::runtime_error("High-resolution frame limiter wait failed");
            }
            if(latencyEvent&&WaitForSingleObject(latencyEvent,30000)!=WAIT_OBJECT_0)throw std::runtime_error("swapchain frame-latency timeout");
            RealEvent event{};event.frame=i;event.sampleMs=NowMs();(void)GetAsyncKeyState(VK_SPACE);
            fgConfig.frameID=i;Fx(api.configure(&fgContext,&fgConfig.header),"configure FG per-frame");
            Hr(allocator->Reset(),"Allocator Reset");Hr(list->Reset(allocator.Get(),nullptr),"List Reset");
            list->EndQuery(timestamps.Get(),D3D12_QUERY_TYPE_TIMESTAMP,i*4);
            if(i){Barrier(list.Get(),color.Get(),D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_RENDER_TARGET);
                Barrier(list.Get(),depth.Get(),D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_RENDER_TARGET);
                Barrier(list.Get(),motion.Get(),D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_RENDER_TARGET);}
            D3D12_VIEWPORT view{0,0,float(Width),float(Height),0,1};D3D12_RECT scissor{0,0,Width,Height};list->RSSetViewports(1,&view);list->RSSetScissorRects(1,&scissor);
            std::array<D3D12_CPU_DESCRIPTOR_HANDLE,3> targets{Rtv(0),Rtv(1),Rtv(2)};list->OMSetRenderTargets(3,targets.data(),FALSE,nullptr);
            list->SetPipelineState(pso.Get());list->SetGraphicsRootSignature(root.Get());
            const float phase=float(i)*.035f,previous=float(i?i-1:0)*.035f;
            const float constants[4]={float(Width),float(Height),640+std::sin(phase)*280,640+std::sin(previous)*280};
            list->SetGraphicsRoot32BitConstants(0,4,constants,0);list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);list->DrawInstanced(3,1,0,0);
            Barrier(list.Get(),color.Get(),D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_COPY_SOURCE);
            Barrier(list.Get(),depth.Get(),D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            Barrier(list.Get(),motion.Get(),D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            ComPtr<ID3D12Resource> back;Hr(swap->GetBuffer(swap->GetCurrentBackBufferIndex(),IID_PPV_ARGS(&back)),"GetBuffer");
            Barrier(list.Get(),back.Get(),D3D12_RESOURCE_STATE_PRESENT,D3D12_RESOURCE_STATE_COPY_DEST);list->CopyResource(back.Get(),color.Get());
            Barrier(list.Get(),back.Get(),D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_PRESENT);
            if(enabled){
                ffxDispatchDescFrameGenerationPrepareV2 p{};p.header.type=FFX_API_DISPATCH_DESC_TYPE_FRAMEGENERATION_PREPARE_V2;
                p.frameID=i;p.commandList=list.Get();p.renderSize={Width,Height};p.motionVectorScale={1,1};p.frameTimeDelta=16.667f;p.reset=i==0;
                p.cameraNear=.1f;p.cameraFar=100;p.cameraFovAngleVertical=1.04719755f;p.viewSpaceToMetersFactor=1;
                p.depth=ffxApiGetResourceDX12(depth.Get());p.motionVectors=ffxApiGetResourceDX12(motion.Get());
                p.cameraUp[1]=1;p.cameraRight[0]=1;p.cameraForward[2]=1;
                Fx(api.dispatch(&fgContext,&p.header),"FG prepare V2");
            }
            list->EndQuery(timestamps.Get(),D3D12_QUERY_TYPE_TIMESTAMP,i*4+1);
            list->ResolveQueryData(timestamps.Get(),D3D12_QUERY_TYPE_TIMESTAMP,i*4,2,timestampReadback.Get(),i*4*sizeof(uint64_t));
            Hr(list->Close(),"List Close");ID3D12CommandList* lists[]={list.Get()};queue->ExecuteCommandLists(1,lists);event.submitMs=NowMs();
            event.presentBeginMs=NowMs();Hr(swap->Present(0,0),"Present");event.presentEndMs=NowMs();realEvents.push_back(event);
            // 只等待主队列，以便复用本程序 allocator。SDK 的 UI/present 队列此时可以继续工作。
            FlushMain();
        }
        Drain();std::this_thread::sleep_for(std::chrono::milliseconds(100));
        stopStatistics=true;statisticsThread.join();
        Hr(swap->GetLastPresentCount(&lastPresentCount),"GetLastPresentCount");statisticsHr=swap->GetFrameStatistics(&statistics);
        Close();Save(); // 销毁 SDK 也属于 Debug 验收范围，尤其检查在用资源被提前释放。
    }
    void Drain(){
        FlushMain();
        // 主队列 Fence 不覆盖 SDK 隐藏 present 队列；释放 readback/RTV/回调对象前必须再等待 SDK。
        ffxDispatchDescFrameGenerationSwapChainWaitForPresentsDX12 wait{};wait.header.type=FFX_API_DISPATCH_DESC_TYPE_FRAMEGENERATIONSWAPCHAIN_WAIT_FOR_PRESENTS_DX12;
        Fx(api.dispatch(&swapContext,&wait.header),"wait all SDK presents");
    }
    unsigned DebugErrors(){
        unsigned n=0;if(!info)return n;
        std::ofstream log(output/"debug-layer.txt");
        for(UINT64 i=0;i<info->GetNumStoredMessages();++i){SIZE_T size=0;info->GetMessage(i,nullptr,&size);std::vector<char> data(size);auto* m=reinterpret_cast<D3D12_MESSAGE*>(data.data());
            info->GetMessage(i,m,&size);log<<unsigned(m->Severity)<<" "<<m->ID<<" "<<m->pDescription<<"\n";
            if(m->Severity==D3D12_MESSAGE_SEVERITY_ERROR||m->Severity==D3D12_MESSAGE_SEVERITY_CORRUPTION)++n;}
        return n;
    }
    void Save(){
        fs::create_directories(output);
        {std::ofstream csv(output/"real-frames.csv");csv<<"frame_id,input_sample_qpc_ms,cpu_submit_qpc_ms,present_begin_qpc_ms,present_end_qpc_ms,input_to_cpu_submit_ms,present_cpu_ms,scene_prepare_gpu_ms,fg_gpu_ms\n";
            uint64_t* values=nullptr;D3D12_RANGE range{0,MaxFrames*4*sizeof(uint64_t)};Hr(timestampReadback->Map(0,&range,reinterpret_cast<void**>(&values)),"map timestamps");
            for(const auto&e:realEvents){auto* t=values+e.frame*4;csv<<std::setprecision(12)<<e.frame<<','<<e.sampleMs<<','<<e.submitMs<<','<<e.presentBeginMs<<','<<e.presentEndMs<<','
                <<e.submitMs-e.sampleMs<<','<<e.presentEndMs-e.presentBeginMs<<','<<double(t[1]-t[0])*1000.0/gpuFrequency<<','<<(enabled?double(t[3]-t[2])*1000.0/gpuFrequency:0)<<'\n';}
            D3D12_RANGE written{0,0};timestampReadback->Unmap(0,&written);}
        unsigned real=0,generated=0;
        {std::ofstream csv(output/"display-events.csv");csv<<"frame_id,kind,composition_callback_qpc_ms\n";
            for(const auto&e:displayEvents){if(e.generated)++generated;else ++real;csv<<std::setprecision(12)<<e.frame<<','<<(e.generated?"generated":"real")<<','<<e.qpcMs<<'\n';}}
        {std::ofstream csv(output/"dxgi-display-observations.csv");csv<<"present_id,present_refresh_count,sync_refresh_count,sync_qpc_ms,cpu_observed_qpc_ms\n";
            for(const auto&e:scanoutEvents)csv<<std::setprecision(12)<<e.presentId<<','<<e.refresh<<','<<e.syncRefresh<<','<<e.syncQpcMs<<','<<e.observedQpcMs<<'\n';}
        const char* names[]={"previous-real.ppm","generated.ppm","current-real.ppm"};
        for(UINT i=0;i<3;++i)if(captured[i]){
            uint8_t* pixels=nullptr;D3D12_RANGE read{0,SIZE_T(captureBytes)};Hr(captures[i]->Map(0,&read,reinterpret_cast<void**>(&pixels)),"map capture");
            std::ofstream img(output/names[i],std::ios::binary);img<<"P6\n"<<Width<<' '<<Height<<"\n255\n";
            for(UINT y=0;y<Height;++y)for(UINT x=0;x<Width;++x)img.write(reinterpret_cast<char*>(pixels+footprint.Offset+y*footprint.Footprint.RowPitch+x*4),3);
            D3D12_RANGE written{0,0};captures[i]->Unmap(0,&written);
        }
        auto errors=DebugErrors();std::ofstream j(output/"runtime.json");
        j<<"{\n  \"adapter\": \""<<adapterName<<"\",\n  \"fg_provider\": \""<<provider<<"\",\n  \"swapchain_provider\": \""<<swapProvider<<"\",\n"
            <<"  \"fg_enabled\": "<<(enabled?"true":"false")<<",\n  \"debug_layer_enabled\": "<<(debug?"true":"false")<<",\n  \"vsync\": false,\n  \"width\": "<<Width<<",\n  \"height\": "<<Height<<",\n"
            <<"  \"measurement_window_topmost\": true,\n"
            <<"  \"real_frames\": "<<realEvents.size()<<",\n  \"real_display_callbacks\": "<<real<<",\n  \"generated_display_callbacks\": "<<generated<<",\n"
            <<"  \"generation_dispatch_calls\": "<<generationCalls<<",\n  \"requested_generated_frames\": "<<generatedRequests<<",\n  \"dxgi_last_present_count\": "<<lastPresentCount<<",\n"
            <<"  \"dxgi_frame_statistics_hresult\": "<<int(statisticsHr)<<",\n  \"dxgi_statistics_valid\": "<<(SUCCEEDED(statisticsHr)?"true":"false")<<",\n  \"dxgi_statistics_present_count\": "<<(SUCCEEDED(statisticsHr)?std::to_string(statistics.PresentCount):"null")<<",\n  \"dxgi_statistics_refresh_count\": "<<(SUCCEEDED(statisticsHr)?std::to_string(statistics.PresentRefreshCount):"null")<<",\n"
            <<"  \"dxgi_observed_display_changes\": "<<scanoutEvents.size()<<",\n  \"dxgi_statistics_failed_polls\": "<<statisticsFailures<<",\n  \"max_statistics_poll_gap_ms\": "<<maxStatisticsPollGapMs<<",\n"
            <<"  \"debug_errors\": "<<errors<<",\n  \"ffx_errors\": "<<FfxErrors<<",\n  \"callback_errors\": "<<callbackErrors<<",\n  \"physical_scanout_measured\": false,\n  \"end_to_end_input_latency_measured\": false\n}\n";
        std::cout<<"real="<<real<<" generated="<<generated<<" API presents="<<lastPresentCount<<" debug_errors="<<errors<<"\n";
        if(errors||FfxErrors||callbackErrors||real!=frames||(enabled&&generated<frames-3))throw std::runtime_error("F9 runtime acceptance failed");
    }
    void Close(){
        if(closed)return;closed=true;
        stopStatistics=true;if(statisticsThread.joinable())statisticsThread.join();
        if(fgContext&&swapContext){Drain();fgConfig.frameGenerationEnabled=false;fgConfig.presentCallback=nullptr;fgConfig.frameGenerationCallback=nullptr;
            Fx(api.configure(&fgContext,&fgConfig.header),"disable FG");Drain();}
        if(fgContext)Fx(api.destroy(&fgContext,nullptr),"destroy FG");
        if(swapContext)Fx(api.destroy(&swapContext,nullptr),"destroy FG swapchain");swap=nullptr;
        if(latencyEvent){CloseHandle(latencyEvent);latencyEvent=nullptr;} // SDK 3.1.7 返回 DuplicateHandle，context 销毁后由应用关闭。
        if(frameTimer){CancelWaitableTimer(frameTimer);CloseHandle(frameTimer);frameTimer=nullptr;}
        if(fenceEvent){CloseHandle(fenceEvent);fenceEvent=nullptr;}if(window&&IsWindow(window))DestroyWindow(window);
    }
    ~Demo(){try{Close();}catch(const std::exception&e){std::cerr<<"cleanup: "<<e.what()<<'\n';}}
};
int wmain(int argc,wchar_t** argv){
    try{
        bool fg=true,debug=true;UINT frames=180;
        wchar_t exe[MAX_PATH];GetModuleFileNameW(nullptr,exe,MAX_PATH);
        fs::path root=fs::path(exe).parent_path().parent_path().parent_path().parent_path();
        fs::path output=root/"results/f9/on",shader=root/"shaders/framegen_scene.hlsl";
        for(int i=1;i<argc;++i){std::wstring a=argv[i];if(a==L"--fg"&&i+1<argc)fg=std::stoi(argv[++i])!=0;
            else if(a==L"--frames"&&i+1<argc)frames=UINT(std::stoi(argv[++i]));else if(a==L"--output"&&i+1<argc)output=argv[++i];
            else if(a==L"--no-debug")debug=false;else throw std::runtime_error("unknown argument");}
        if(frames<65||frames>MaxFrames)throw std::runtime_error("frames must be 65..600");
        Demo d(fg,debug,frames,output,shader);d.Run();return 0;
    }catch(const std::exception&e){std::cerr<<"F9 failed: "<<e.what()<<'\n';return 1;}
}
