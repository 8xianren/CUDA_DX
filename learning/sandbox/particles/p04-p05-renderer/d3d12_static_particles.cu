#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE

#include <cuda_runtime.h>

#include <windows.h>
#include <d3d12.h>
#include <d3dcompiler.h>
#include <dxgi1_6.h>
#include <wrl/client.h>

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

using Microsoft::WRL::ComPtr;

// CUDA、D3D12 和 DXGI 都大量使用“返回错误码”的 API。
// 教学 demo 在错误发生处立即停止，并打印失败调用，避免把真正原因拖成
// 后续的黑屏、设备移除或空指针访问。
#define CUDA_CHECK(call)                                                        \
  do {                                                                          \
    const cudaError_t cuda_check_result = (call);                                \
    if (cuda_check_result != cudaSuccess) {                                      \
      std::fprintf(stderr, "%s failed: %s\n", #call,                         \
                   cudaGetErrorString(cuda_check_result));                       \
      std::exit(EXIT_FAILURE);                                                   \
    }                                                                            \
  } while (0)

#define HR_CHECK(call)                                                          \
  do {                                                                          \
    const HRESULT hr_check_result = (call);                                      \
    if (FAILED(hr_check_result)) {                                               \
      std::fprintf(stderr, "%s failed: HRESULT 0x%08lx\n", #call,            \
                   static_cast<unsigned long>(hr_check_result));                 \
      std::exit(EXIT_FAILURE);                                                   \
    }                                                                            \
  } while (0)

constexpr UINT kWindowWidth = 1280;
constexpr UINT kWindowHeight = 720;
constexpr UINT kBackBufferCount = 2;
constexpr UINT kParticleGridSide = 64;
constexpr UINT kParticleCount = kParticleGridSide * kParticleGridSide;
constexpr wchar_t kWindowClassName[] = L"CudaD3D12StaticParticlesClass";

// 一个 Back Buffer 对应一套可独立复用的帧资源。
//
// Command Allocator 持有 command list 录制后的底层命令内存。GPU 尚未执行完
// 这些命令时，CPU 不能 Reset allocator。因此双缓冲中的每张交换链图像都有
// 自己的 allocator，并用 fence_value 标记它上一次提交完成的时间点。
struct FrameResources {
  ComPtr<ID3D12CommandAllocator> command_allocator;
  ComPtr<ID3D12Resource> back_buffer;
  D3D12_CPU_DESCRIPTOR_HANDLE rtv{};
  UINT64 fence_value = 0;
};

struct Renderer {
  ComPtr<IDXGIFactory6> factory;
  ComPtr<ID3D12Device> device;
  ComPtr<ID3D12CommandQueue> command_queue;
  ComPtr<IDXGISwapChain3> swap_chain;
  ComPtr<ID3D12DescriptorHeap> rtv_heap;
  ComPtr<ID3D12GraphicsCommandList> command_list;
  ComPtr<ID3D12Fence> fence;
  std::array<FrameResources, kBackBufferCount> frames;

  // P.4.2 新增的图形管线对象。
  // Root Signature 定义“着色器允许从哪里取资源”；PSO 固化着色器和固定功能
  // 状态；shader-visible SRV heap 保存 t0/t1 两个 GPU 可见描述符。
  ComPtr<ID3D12RootSignature> root_signature;
  ComPtr<ID3D12PipelineState> pipeline_state;
  ComPtr<ID3D12DescriptorHeap> srv_heap;

  // 这是一块连续的 Default Heap Buffer，物理上只创建一个 allocation，逻辑上
  // 按 SoA 切成 position[N]、velocity[N]、color[N] 三段。P.4.3 会把同样布局的
  // Buffer 改成 shared heap，让 CUDA 直接写 position/velocity。
  ComPtr<ID3D12Resource> particle_buffer;

  D3D12_VIEWPORT viewport{};
  D3D12_RECT scissor{};

  HANDLE fence_event = nullptr;
  UINT64 next_fence_value = 1;
  UINT64 frame_reuse_cpu_waits = 0;
};

LRESULT CALLBACK window_procedure(HWND window, UINT message, WPARAM w_param,
                                  LPARAM l_param) {
  switch (message) {
    case WM_KEYDOWN:
      if (w_param == VK_ESCAPE) {
        DestroyWindow(window);
        return 0;
      }
      break;

    case WM_DESTROY:
      PostQuitMessage(0);
      return 0;

    default:
      break;
  }
  return DefWindowProcW(window, message, w_param, l_param);
}

HWND create_window(HINSTANCE instance) {
  // 固定窗口尺寸，让本节集中在资源绑定与 DrawInstanced；窗口缩放需要
  // ResizeBuffers、RTV 重建和 GPU flush，将在需要时再单独处理。
  constexpr DWORD window_style =
      WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;

  WNDCLASSEXW window_class{};
  window_class.cbSize = sizeof(window_class);
  window_class.style = CS_HREDRAW | CS_VREDRAW;
  window_class.lpfnWndProc = window_procedure;
  window_class.hInstance = instance;
  window_class.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  window_class.lpszClassName = kWindowClassName;
  if (RegisterClassExW(&window_class) == 0) {
    std::fprintf(stderr, "RegisterClassExW failed: %lu\n", GetLastError());
    std::exit(EXIT_FAILURE);
  }

  RECT window_rectangle{0, 0, static_cast<LONG>(kWindowWidth),
                        static_cast<LONG>(kWindowHeight)};
  if (!AdjustWindowRect(&window_rectangle, window_style, FALSE)) {
    std::fprintf(stderr, "AdjustWindowRect failed: %lu\n", GetLastError());
    std::exit(EXIT_FAILURE);
  }

  HWND window = CreateWindowExW(
      0, kWindowClassName,
      L"CUDA + D3D12 Particle Project - Static SoA Particles",
      window_style, CW_USEDEFAULT, CW_USEDEFAULT,
      window_rectangle.right - window_rectangle.left,
      window_rectangle.bottom - window_rectangle.top, nullptr, nullptr,
      instance, nullptr);
  if (window == nullptr) {
    std::fprintf(stderr, "CreateWindowExW failed: %lu\n", GetLastError());
    std::exit(EXIT_FAILURE);
  }

  ShowWindow(window, SW_SHOWDEFAULT);
  UpdateWindow(window);
  return window;
}

// CUDA 与 D3D12 必须落在同一块物理 GPU 上，资源才可能在 P.4.3 共享。
// 适配器名称只适合给人看，不能作为可靠身份；Windows LUID 是 8-byte 身份键，
// CUDA device property 与 DXGI adapter 的 LUID 完全相等才算真正配对。
ComPtr<IDXGIAdapter1> find_cuda_adapter(IDXGIFactory6* factory,
                                        const cudaDeviceProp& properties) {
  static_assert(sizeof(LUID) == 8, "Windows LUID must contain 8 bytes");

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
    if ((description.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0) {
      continue;
    }

    if (std::memcmp(properties.luid, &description.AdapterLuid,
                    sizeof(properties.luid)) == 0) {
      std::printf("matched CUDA/D3D12 adapter: %ls\n",
                  description.Description);
      return adapter;
    }
  }

  std::fprintf(stderr, "No DXGI adapter matches CUDA device 0 LUID.\n");
  std::exit(EXIT_FAILURE);
}

// 这些小辅助函数显式填完 D3D12 结构体，避免依赖 d3dx12.h。
// Buffer 的 Layout 必须是 ROW_MAJOR；它不像纹理那样具有不透明 tiled layout。
D3D12_HEAP_PROPERTIES make_heap_properties(D3D12_HEAP_TYPE type) {
  D3D12_HEAP_PROPERTIES properties{};
  properties.Type = type;
  properties.CPUPageProperty = D3D12_CPU_PAGE_PROPERTY_UNKNOWN;
  properties.MemoryPoolPreference = D3D12_MEMORY_POOL_UNKNOWN;
  properties.CreationNodeMask = 1;
  properties.VisibleNodeMask = 1;
  return properties;
}

D3D12_RESOURCE_DESC make_buffer_description(UINT64 byte_count) {
  D3D12_RESOURCE_DESC description{};
  description.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
  description.Alignment = 0;
  description.Width = byte_count;
  description.Height = 1;
  description.DepthOrArraySize = 1;
  description.MipLevels = 1;
  description.Format = DXGI_FORMAT_UNKNOWN;
  description.SampleDesc.Count = 1;
  description.SampleDesc.Quality = 0;
  description.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
  description.Flags = D3D12_RESOURCE_FLAG_NONE;
  return description;
}

Renderer create_renderer(HWND window) {
  Renderer renderer{};

  CUDA_CHECK(cudaSetDevice(0));
  cudaDeviceProp cuda_properties{};
  CUDA_CHECK(cudaGetDeviceProperties(&cuda_properties, 0));

  HR_CHECK(CreateDXGIFactory2(0, IID_PPV_ARGS(&renderer.factory)));
  ComPtr<IDXGIAdapter1> adapter =
      find_cuda_adapter(renderer.factory.Get(), cuda_properties);
  HR_CHECK(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0,
                             IID_PPV_ARGS(&renderer.device)));

  // DIRECT queue 同时支持复制、资源屏障和 graphics draw。
  D3D12_COMMAND_QUEUE_DESC queue_description{};
  queue_description.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
  queue_description.Priority = D3D12_COMMAND_QUEUE_PRIORITY_NORMAL;
  queue_description.Flags = D3D12_COMMAND_QUEUE_FLAG_NONE;
  HR_CHECK(renderer.device->CreateCommandQueue(
      &queue_description, IID_PPV_ARGS(&renderer.command_queue)));

  DXGI_SWAP_CHAIN_DESC1 swap_chain_description{};
  swap_chain_description.Width = kWindowWidth;
  swap_chain_description.Height = kWindowHeight;
  swap_chain_description.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
  swap_chain_description.SampleDesc.Count = 1;
  swap_chain_description.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
  swap_chain_description.BufferCount = kBackBufferCount;
  swap_chain_description.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
  swap_chain_description.Scaling = DXGI_SCALING_STRETCH;
  swap_chain_description.AlphaMode = DXGI_ALPHA_MODE_UNSPECIFIED;

  ComPtr<IDXGISwapChain1> swap_chain1;
  HR_CHECK(renderer.factory->CreateSwapChainForHwnd(
      renderer.command_queue.Get(), window, &swap_chain_description, nullptr,
      nullptr, &swap_chain1));
  HR_CHECK(swap_chain1.As(&renderer.swap_chain));
  HR_CHECK(renderer.factory->MakeWindowAssociation(
      window, DXGI_MWA_NO_ALT_ENTER));

  // RTV heap 不需要 SHADER_VISIBLE：它由 OMSetRenderTargets 在 CPU 录制命令时
  // 直接引用。与之相对，稍后 t0/t1 的 SRV heap 必须让 shader 在 GPU 上访问。
  D3D12_DESCRIPTOR_HEAP_DESC rtv_heap_description{};
  rtv_heap_description.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
  rtv_heap_description.NumDescriptors = kBackBufferCount;
  rtv_heap_description.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_NONE;
  HR_CHECK(renderer.device->CreateDescriptorHeap(
      &rtv_heap_description, IID_PPV_ARGS(&renderer.rtv_heap)));

  const UINT rtv_increment = renderer.device->GetDescriptorHandleIncrementSize(
      D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
  D3D12_CPU_DESCRIPTOR_HANDLE rtv =
      renderer.rtv_heap->GetCPUDescriptorHandleForHeapStart();

  for (UINT frame_index = 0; frame_index < kBackBufferCount; ++frame_index) {
    FrameResources& frame = renderer.frames[frame_index];
    HR_CHECK(renderer.swap_chain->GetBuffer(
        frame_index, IID_PPV_ARGS(&frame.back_buffer)));
    renderer.device->CreateRenderTargetView(frame.back_buffer.Get(), nullptr,
                                            rtv);
    frame.rtv = rtv;
    rtv.ptr += rtv_increment;

    HR_CHECK(renderer.device->CreateCommandAllocator(
        D3D12_COMMAND_LIST_TYPE_DIRECT,
        IID_PPV_ARGS(&frame.command_allocator)));
  }

  // command list 是可复用的录制器；首次创建时处于 open 状态，这里先 Close，
  // 后续每帧才能用 Reset(frame allocator, PSO) 开始一次新录制。
  HR_CHECK(renderer.device->CreateCommandList(
      0, D3D12_COMMAND_LIST_TYPE_DIRECT,
      renderer.frames[0].command_allocator.Get(), nullptr,
      IID_PPV_ARGS(&renderer.command_list)));
  HR_CHECK(renderer.command_list->Close());

  HR_CHECK(renderer.device->CreateFence(
      0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&renderer.fence)));
  renderer.fence_event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (renderer.fence_event == nullptr) {
    std::fprintf(stderr, "CreateEventW failed: %lu\n", GetLastError());
    std::exit(EXIT_FAILURE);
  }

  renderer.viewport.TopLeftX = 0.0f;
  renderer.viewport.TopLeftY = 0.0f;
  renderer.viewport.Width = static_cast<float>(kWindowWidth);
  renderer.viewport.Height = static_cast<float>(kWindowHeight);
  renderer.viewport.MinDepth = 0.0f;
  renderer.viewport.MaxDepth = 1.0f;
  renderer.scissor = {0, 0, static_cast<LONG>(kWindowWidth),
                      static_cast<LONG>(kWindowHeight)};
  return renderer;
}

std::wstring executable_directory() {
  // 从 exe 路径定位 HLSL，而不是依赖进程当前工作目录。这样无论从仓库根目录、
  // sandbox 目录还是 IDE 启动，都会读取与 exe 同目录的着色器文件。
  std::array<wchar_t, 32768> path_buffer{};
  const DWORD length = GetModuleFileNameW(
      nullptr, path_buffer.data(), static_cast<DWORD>(path_buffer.size()));
  if (length == 0 || length >= path_buffer.size()) {
    std::fprintf(stderr, "GetModuleFileNameW failed: %lu\n", GetLastError());
    std::exit(EXIT_FAILURE);
  }

  std::wstring path(path_buffer.data(), length);
  const std::wstring::size_type separator = path.find_last_of(L"\\/");
  if (separator == std::wstring::npos) {
    std::fprintf(stderr, "Executable path has no directory separator.\n");
    std::exit(EXIT_FAILURE);
  }
  return path.substr(0, separator);
}

ComPtr<ID3DBlob> compile_shader(const std::wstring& path,
                                const char* entry_point,
                                const char* target) {
  // vs_5_1/ps_5_1 足以使用 StructuredBuffer 与系统值语义，也与本节创建的
  // D3D12 设备兼容。编译错误 blob 包含 HLSL 文件名、行号和诊断，必须先打印，
  // 否则单看 HRESULT 很难知道是语法、入口点还是 target 出错。
  UINT flags = D3DCOMPILE_ENABLE_STRICTNESS;
#if defined(_DEBUG)
  flags |= D3DCOMPILE_DEBUG | D3DCOMPILE_SKIP_OPTIMIZATION;
#else
  flags |= D3DCOMPILE_OPTIMIZATION_LEVEL3;
#endif

  ComPtr<ID3DBlob> bytecode;
  ComPtr<ID3DBlob> diagnostics;
  const HRESULT result = D3DCompileFromFile(
      path.c_str(), nullptr, D3D_COMPILE_STANDARD_FILE_INCLUDE, entry_point,
      target, flags, 0, &bytecode, &diagnostics);

  if (diagnostics != nullptr && diagnostics->GetBufferSize() > 0) {
    std::fwrite(diagnostics->GetBufferPointer(), 1,
                diagnostics->GetBufferSize(), stderr);
    std::fputc('\n', stderr);
  }
  if (FAILED(result)) {
    std::fprintf(stderr,
                 "D3DCompileFromFile(%s, %s) failed: HRESULT 0x%08lx\n",
                 entry_point, target, static_cast<unsigned long>(result));
    std::exit(EXIT_FAILURE);
  }
  return bytecode;
}

void create_root_signature_and_pipeline(Renderer& renderer) {
  // 一个 descriptor range 连续覆盖 t0 和 t1：
  //   t0 -> position StructuredBuffer<float4>
  //   t1 -> color    StructuredBuffer<float4>
  // Root Parameter 本身不保存资源；它只规定根参数 0 是一张 SRV descriptor
  // table。逐帧录制时再把 shader-visible heap 的 GPU 起始地址绑定进去。
  D3D12_DESCRIPTOR_RANGE srv_range{};
  srv_range.RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
  srv_range.NumDescriptors = 2;
  srv_range.BaseShaderRegister = 0;
  srv_range.RegisterSpace = 0;
  srv_range.OffsetInDescriptorsFromTableStart = 0;

  D3D12_ROOT_PARAMETER root_parameter{};
  root_parameter.ParameterType =
      D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
  root_parameter.DescriptorTable.NumDescriptorRanges = 1;
  root_parameter.DescriptorTable.pDescriptorRanges = &srv_range;
  root_parameter.ShaderVisibility = D3D12_SHADER_VISIBILITY_VERTEX;

  D3D12_ROOT_SIGNATURE_DESC root_description{};
  root_description.NumParameters = 1;
  root_description.pParameters = &root_parameter;
  root_description.NumStaticSamplers = 0;
  root_description.pStaticSamplers = nullptr;
  // 虽然没有 Vertex Buffer，DrawInstanced 仍经过 Input Assembler 产生拓扑，
  // 因而允许 IA；空 Input Layout 表示 VS 输入完全来自系统语义和 SRV。
  root_description.Flags =
      D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;

  ComPtr<ID3DBlob> serialized_signature;
  ComPtr<ID3DBlob> signature_diagnostics;
  const HRESULT serialize_result = D3D12SerializeRootSignature(
      &root_description, D3D_ROOT_SIGNATURE_VERSION_1,
      &serialized_signature, &signature_diagnostics);
  if (signature_diagnostics != nullptr &&
      signature_diagnostics->GetBufferSize() > 0) {
    std::fwrite(signature_diagnostics->GetBufferPointer(), 1,
                signature_diagnostics->GetBufferSize(), stderr);
    std::fputc('\n', stderr);
  }
  HR_CHECK(serialize_result);
  HR_CHECK(renderer.device->CreateRootSignature(
      0, serialized_signature->GetBufferPointer(),
      serialized_signature->GetBufferSize(),
      IID_PPV_ARGS(&renderer.root_signature)));

  const std::wstring shader_path =
      executable_directory() + L"\\d3d12_static_particles.hlsl";
  ComPtr<ID3DBlob> vertex_shader =
      compile_shader(shader_path, "VSMain", "vs_5_1");
  ComPtr<ID3DBlob> pixel_shader =
      compile_shader(shader_path, "PSMain", "ps_5_1");

  D3D12_RASTERIZER_DESC rasterizer{};
  rasterizer.FillMode = D3D12_FILL_MODE_SOLID;
  // quad 顶点绕序并不是本课重点；关闭背面剔除也避免由于屏幕坐标约定不同，
  // 整个粒子被错误剔除。DepthClipEnable 仍保留正常裁剪空间行为。
  rasterizer.CullMode = D3D12_CULL_MODE_NONE;
  rasterizer.FrontCounterClockwise = FALSE;
  rasterizer.DepthBias = D3D12_DEFAULT_DEPTH_BIAS;
  rasterizer.DepthBiasClamp = D3D12_DEFAULT_DEPTH_BIAS_CLAMP;
  rasterizer.SlopeScaledDepthBias = D3D12_DEFAULT_SLOPE_SCALED_DEPTH_BIAS;
  rasterizer.DepthClipEnable = TRUE;
  rasterizer.MultisampleEnable = FALSE;
  rasterizer.AntialiasedLineEnable = FALSE;
  rasterizer.ForcedSampleCount = 0;
  rasterizer.ConservativeRaster =
      D3D12_CONSERVATIVE_RASTERIZATION_MODE_OFF;

  D3D12_BLEND_DESC blend{};
  blend.AlphaToCoverageEnable = FALSE;
  blend.IndependentBlendEnable = FALSE;
  for (D3D12_RENDER_TARGET_BLEND_DESC& target : blend.RenderTarget) {
    target.BlendEnable = FALSE;
    target.LogicOpEnable = FALSE;
    target.SrcBlend = D3D12_BLEND_ONE;
    target.DestBlend = D3D12_BLEND_ZERO;
    target.BlendOp = D3D12_BLEND_OP_ADD;
    target.SrcBlendAlpha = D3D12_BLEND_ONE;
    target.DestBlendAlpha = D3D12_BLEND_ZERO;
    target.BlendOpAlpha = D3D12_BLEND_OP_ADD;
    target.LogicOp = D3D12_LOGIC_OP_NOOP;
    target.RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
  }

  D3D12_DEPTH_STENCILOP_DESC disabled_stencil_face{};
  disabled_stencil_face.StencilFailOp = D3D12_STENCIL_OP_KEEP;
  disabled_stencil_face.StencilDepthFailOp = D3D12_STENCIL_OP_KEEP;
  disabled_stencil_face.StencilPassOp = D3D12_STENCIL_OP_KEEP;
  disabled_stencil_face.StencilFunc = D3D12_COMPARISON_FUNC_ALWAYS;

  D3D12_DEPTH_STENCIL_DESC depth_stencil{};
  depth_stencil.DepthEnable = FALSE;
  depth_stencil.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ZERO;
  depth_stencil.DepthFunc = D3D12_COMPARISON_FUNC_ALWAYS;
  depth_stencil.StencilEnable = FALSE;
  depth_stencil.StencilReadMask = D3D12_DEFAULT_STENCIL_READ_MASK;
  depth_stencil.StencilWriteMask = D3D12_DEFAULT_STENCIL_WRITE_MASK;
  depth_stencil.FrontFace = disabled_stencil_face;
  depth_stencil.BackFace = disabled_stencil_face;

  D3D12_GRAPHICS_PIPELINE_STATE_DESC pipeline_description{};
  pipeline_description.pRootSignature = renderer.root_signature.Get();
  pipeline_description.VS = {vertex_shader->GetBufferPointer(),
                             vertex_shader->GetBufferSize()};
  pipeline_description.PS = {pixel_shader->GetBufferPointer(),
                             pixel_shader->GetBufferSize()};
  // Input Layout 为空：每个 quad 的六个角在 VS 内由 SV_VertexID 生成。
  pipeline_description.InputLayout = {nullptr, 0};
  pipeline_description.BlendState = blend;
  pipeline_description.SampleMask = UINT_MAX;
  pipeline_description.RasterizerState = rasterizer;
  pipeline_description.DepthStencilState = depth_stencil;
  pipeline_description.PrimitiveTopologyType =
      D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
  pipeline_description.NumRenderTargets = 1;
  pipeline_description.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
  pipeline_description.DSVFormat = DXGI_FORMAT_UNKNOWN;
  pipeline_description.SampleDesc.Count = 1;
  pipeline_description.SampleDesc.Quality = 0;
  HR_CHECK(renderer.device->CreateGraphicsPipelineState(
      &pipeline_description, IID_PPV_ARGS(&renderer.pipeline_state)));
}

void wait_for_fence_value(Renderer& renderer, UINT64 value,
                          const char* context) {
  if (renderer.fence->GetCompletedValue() >= value) {
    return;
  }
  HR_CHECK(renderer.fence->SetEventOnCompletion(value,
                                                 renderer.fence_event));
  const DWORD wait_result =
      WaitForSingleObject(renderer.fence_event, INFINITE);
  if (wait_result != WAIT_OBJECT_0) {
    std::fprintf(stderr, "%s wait failed: %lu\n", context, GetLastError());
    std::exit(EXIT_FAILURE);
  }
}

void create_and_upload_particle_buffer(Renderer& renderer) {
  // SoA 的三个连续区段均以 float4 为元素：
  //   [0, N)   position：xy=NDC 中心，z=深度，w=NDC 半径
  //   [N, 2N)  velocity：本节为 0；P.4.3 由 CUDA 积分器更新
  //   [2N, 3N) color：rgb 颜色，a=1
  //
  // 只创建一块 Buffer 是为了保持与后续 external memory 完全一致的 allocation
  // 形态；D3D12 通过两个 SRV 描述这块 Buffer 的不同元素区间。
  std::vector<float4> initial_soa(
      static_cast<std::size_t>(kParticleCount) * 3);
  float4* const positions = initial_soa.data();
  float4* const velocities = positions + kParticleCount;
  float4* const colors = velocities + kParticleCount;

  for (UINT row = 0; row < kParticleGridSide; ++row) {
    for (UINT column = 0; column < kParticleGridSide; ++column) {
      const UINT index = row * kParticleGridSide + column;
      const float u = static_cast<float>(column) /
                      static_cast<float>(kParticleGridSide - 1);
      const float v = static_cast<float>(row) /
                      static_cast<float>(kParticleGridSide - 1);

      // NDC 的 x/y 可见范围是 [-1, 1]；留 0.1 边距后铺成 64x64 网格。
      // 半径 0.0105 小于网格半间距约 0.0143，因此相邻圆不会完全粘住。
      positions[index] =
          make_float4(-0.9f + 1.8f * u, -0.9f + 1.8f * v,
                      0.5f, 0.0105f);
      velocities[index] = make_float4(0.0f, 0.0f, 0.0f, 0.0f);
      colors[index] =
          make_float4(0.15f + 0.85f * u,
                      0.20f + 0.75f * v,
                      0.95f - 0.45f * u, 1.0f);
    }
  }

  const UINT64 buffer_byte_count =
      static_cast<UINT64>(initial_soa.size() * sizeof(float4));
  const D3D12_RESOURCE_DESC buffer_description =
      make_buffer_description(buffer_byte_count);

  // Default Heap 位于 GPU 最适合访问的内存域，但 CPU 不能直接 Map。
  // 所以先创建 COPY_DEST 状态的最终资源，再借助可 Map 的 Upload Heap 暂存。
  const D3D12_HEAP_PROPERTIES default_heap =
      make_heap_properties(D3D12_HEAP_TYPE_DEFAULT);
  HR_CHECK(renderer.device->CreateCommittedResource(
      &default_heap, D3D12_HEAP_FLAG_NONE, &buffer_description,
      D3D12_RESOURCE_STATE_COPY_DEST, nullptr,
      IID_PPV_ARGS(&renderer.particle_buffer)));

  ComPtr<ID3D12Resource> upload_buffer;
  const D3D12_HEAP_PROPERTIES upload_heap =
      make_heap_properties(D3D12_HEAP_TYPE_UPLOAD);
  HR_CHECK(renderer.device->CreateCommittedResource(
      &upload_heap, D3D12_HEAP_FLAG_NONE, &buffer_description,
      D3D12_RESOURCE_STATE_GENERIC_READ, nullptr,
      IID_PPV_ARGS(&upload_buffer)));

  void* mapped_upload = nullptr;
  // read_range={0,0} 告诉驱动“CPU 不会读取此映射”，可避免无意义的 cache 工作。
  const D3D12_RANGE no_cpu_reads{0, 0};
  HR_CHECK(upload_buffer->Map(0, &no_cpu_reads, &mapped_upload));
  std::memcpy(mapped_upload, initial_soa.data(),
              static_cast<std::size_t>(buffer_byte_count));
  const D3D12_RANGE cpu_written_range{
      0, static_cast<SIZE_T>(buffer_byte_count)};
  upload_buffer->Unmap(0, &cpu_written_range);

  // 初始化上传使用独立 allocator/list，并只在初始化末尾等待一次。
  // 这次 CPU wait 是为了安全销毁临时 Upload Buffer，不在逐帧路径中。
  ComPtr<ID3D12CommandAllocator> upload_allocator;
  HR_CHECK(renderer.device->CreateCommandAllocator(
      D3D12_COMMAND_LIST_TYPE_DIRECT,
      IID_PPV_ARGS(&upload_allocator)));
  ComPtr<ID3D12GraphicsCommandList> upload_list;
  HR_CHECK(renderer.device->CreateCommandList(
      0, D3D12_COMMAND_LIST_TYPE_DIRECT, upload_allocator.Get(), nullptr,
      IID_PPV_ARGS(&upload_list)));
  upload_list->CopyBufferRegion(renderer.particle_buffer.Get(), 0,
                                upload_buffer.Get(), 0, buffer_byte_count);

  // Copy 完成后，VS 将该 Buffer 当作 SRV 读取，因此状态转为
  // NON_PIXEL_SHADER_RESOURCE。资源状态描述“未来如何访问”，不是所有权本身；
  // P.4.3 的 CUDA/D3D12 跨 API 所有权还要另用 shared Fence 排序。
  D3D12_RESOURCE_BARRIER to_vertex_shader_read{};
  to_vertex_shader_read.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
  to_vertex_shader_read.Transition.pResource =
      renderer.particle_buffer.Get();
  to_vertex_shader_read.Transition.Subresource =
      D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
  to_vertex_shader_read.Transition.StateBefore =
      D3D12_RESOURCE_STATE_COPY_DEST;
  to_vertex_shader_read.Transition.StateAfter =
      D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
  upload_list->ResourceBarrier(1, &to_vertex_shader_read);
  HR_CHECK(upload_list->Close());

  ID3D12CommandList* upload_lists[] = {upload_list.Get()};
  renderer.command_queue->ExecuteCommandLists(1, upload_lists);
  const UINT64 upload_fence_value = renderer.next_fence_value++;
  HR_CHECK(renderer.command_queue->Signal(renderer.fence.Get(),
                                           upload_fence_value));
  wait_for_fence_value(renderer, upload_fence_value, "initial upload");

  // 两个描述符必须连续，顺序与 Root Signature 的 t0/t1 range 一致。
  // SRV 的 FirstElement 以“结构化元素”为单位，而不是 byte：color 从第 2N 个
  // float4 开始，正好跳过 position 和 velocity 两段。
  D3D12_DESCRIPTOR_HEAP_DESC srv_heap_description{};
  srv_heap_description.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
  srv_heap_description.NumDescriptors = 2;
  srv_heap_description.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
  HR_CHECK(renderer.device->CreateDescriptorHeap(
      &srv_heap_description, IID_PPV_ARGS(&renderer.srv_heap)));

  D3D12_SHADER_RESOURCE_VIEW_DESC srv_description{};
  srv_description.Shader4ComponentMapping =
      D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
  srv_description.Format = DXGI_FORMAT_UNKNOWN;
  srv_description.ViewDimension = D3D12_SRV_DIMENSION_BUFFER;
  srv_description.Buffer.FirstElement = 0;
  srv_description.Buffer.NumElements = kParticleCount;
  srv_description.Buffer.StructureByteStride = sizeof(float4);
  srv_description.Buffer.Flags = D3D12_BUFFER_SRV_FLAG_NONE;

  D3D12_CPU_DESCRIPTOR_HANDLE srv =
      renderer.srv_heap->GetCPUDescriptorHandleForHeapStart();
  renderer.device->CreateShaderResourceView(
      renderer.particle_buffer.Get(), &srv_description, srv);

  const UINT srv_increment = renderer.device->GetDescriptorHandleIncrementSize(
      D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
  srv.ptr += srv_increment;
  srv_description.Buffer.FirstElement =
      static_cast<UINT64>(2) * kParticleCount;
  renderer.device->CreateShaderResourceView(
      renderer.particle_buffer.Get(), &srv_description, srv);

  std::printf("uploaded static SoA buffer: %llu bytes, %u particles\n",
              static_cast<unsigned long long>(buffer_byte_count),
              kParticleCount);
}

void wait_until_frame_is_reusable(Renderer& renderer, FrameResources& frame) {
  if (frame.fence_value == 0 ||
      renderer.fence->GetCompletedValue() >= frame.fence_value) {
    return;
  }
  wait_for_fence_value(renderer, frame.fence_value, "frame resource");
  ++renderer.frame_reuse_cpu_waits;
}

void render_particle_frame(Renderer& renderer) {
  const UINT frame_index = renderer.swap_chain->GetCurrentBackBufferIndex();
  FrameResources& frame = renderer.frames[frame_index];

  wait_until_frame_is_reusable(renderer, frame);
  HR_CHECK(frame.command_allocator->Reset());
  HR_CHECK(renderer.command_list->Reset(frame.command_allocator.Get(),
                                        renderer.pipeline_state.Get()));

  D3D12_RESOURCE_BARRIER to_render_target{};
  to_render_target.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
  to_render_target.Transition.pResource = frame.back_buffer.Get();
  to_render_target.Transition.Subresource =
      D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
  to_render_target.Transition.StateBefore = D3D12_RESOURCE_STATE_PRESENT;
  to_render_target.Transition.StateAfter =
      D3D12_RESOURCE_STATE_RENDER_TARGET;
  renderer.command_list->ResourceBarrier(1, &to_render_target);

  renderer.command_list->OMSetRenderTargets(1, &frame.rtv, FALSE, nullptr);
  const float clear_color[4] = {0.008f, 0.014f, 0.035f, 1.0f};
  renderer.command_list->ClearRenderTargetView(frame.rtv, clear_color, 0,
                                                nullptr);

  // Viewport 把 NDC 映射到窗口像素；Scissor 进一步限制可写矩形。
  // Root Signature/descriptor heap/root table 三步分别绑定“接口布局”、
  // “当前 GPU 可见描述符堆”和“根参数 0 指向堆的哪个位置”。
  renderer.command_list->RSSetViewports(1, &renderer.viewport);
  renderer.command_list->RSSetScissorRects(1, &renderer.scissor);
  renderer.command_list->SetGraphicsRootSignature(
      renderer.root_signature.Get());
  ID3D12DescriptorHeap* shader_visible_heaps[] = {
      renderer.srv_heap.Get()};
  renderer.command_list->SetDescriptorHeaps(1, shader_visible_heaps);
  renderer.command_list->SetGraphicsRootDescriptorTable(
      0, renderer.srv_heap->GetGPUDescriptorHandleForHeapStart());

  // 每个实例画 6 个顶点（两个三角形组成一个 quad），共 4096 个实例。
  // VS 中：SV_VertexID 选择 quad 角点，SV_InstanceID 选择粒子 SoA 元素。
  // Pixel Shader 再 clip 掉 quad 四角，视觉上得到圆形粒子。
  renderer.command_list->IASetPrimitiveTopology(
      D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  renderer.command_list->DrawInstanced(6, kParticleCount, 0, 0);

  D3D12_RESOURCE_BARRIER to_present = to_render_target;
  to_present.Transition.StateBefore =
      D3D12_RESOURCE_STATE_RENDER_TARGET;
  to_present.Transition.StateAfter = D3D12_RESOURCE_STATE_PRESENT;
  renderer.command_list->ResourceBarrier(1, &to_present);
  HR_CHECK(renderer.command_list->Close());

  ID3D12CommandList* command_lists[] = {renderer.command_list.Get()};
  renderer.command_queue->ExecuteCommandLists(1, command_lists);
  HR_CHECK(renderer.swap_chain->Present(1, 0));

  // Present 后 signal 一个新时间线值，并把值记在本帧的 allocator 上。
  // 下次交换链重新给出这个 frame_index 时，CPU 只有在该值尚未完成才阻塞。
  const UINT64 submitted_value = renderer.next_fence_value++;
  HR_CHECK(renderer.command_queue->Signal(renderer.fence.Get(),
                                           submitted_value));
  frame.fence_value = submitted_value;
}

void flush_gpu(Renderer& renderer) {
  // 只在退出时等待整条 queue 清空，确保 COM 资源不会在 GPU 仍引用时析构。
  const UINT64 flush_value = renderer.next_fence_value++;
  HR_CHECK(renderer.command_queue->Signal(renderer.fence.Get(), flush_value));
  wait_for_fence_value(renderer, flush_value, "shutdown");
}

int parse_frame_limit(int argc, char** argv) {
  // 默认 180 帧便于自动验证后退出；--frames 0 表示一直运行到 Esc/关闭窗口。
  int frame_limit = 180;
  for (int index = 1; index + 1 < argc; ++index) {
    if (std::strcmp(argv[index], "--frames") == 0) {
      const long parsed = std::strtol(argv[index + 1], nullptr, 10);
      if (parsed >= 0) {
        frame_limit = static_cast<int>(parsed);
      }
    }
  }
  return frame_limit;
}

int main(int argc, char** argv) {
  SetProcessDPIAware();

  HINSTANCE instance = GetModuleHandleW(nullptr);
  HWND window = create_window(instance);
  Renderer renderer = create_renderer(window);
  create_root_signature_and_pipeline(renderer);
  create_and_upload_particle_buffer(renderer);
  const int frame_limit = parse_frame_limit(argc, argv);

  bool running = true;
  std::uint64_t rendered_frames = 0;
  while (running) {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      if (message.message == WM_QUIT) {
        running = false;
        break;
      }
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
    if (!running) {
      break;
    }

    render_particle_frame(renderer);
    ++rendered_frames;
    if (frame_limit > 0 &&
        rendered_frames >= static_cast<std::uint64_t>(frame_limit)) {
      running = false;
    }
  }

  flush_gpu(renderer);
  std::printf("rendered frames: %llu\n",
              static_cast<unsigned long long>(rendered_frames));
  std::printf("frame-resource CPU waits: %llu\n",
              static_cast<unsigned long long>(
                  renderer.frame_reuse_cpu_waits));
  std::printf("particles per frame: %u\n", kParticleCount);
  std::printf("D3D12 static SoA particles: PASS\n");

  if (renderer.fence_event != nullptr) {
    CloseHandle(renderer.fence_event);
    renderer.fence_event = nullptr;
  }
  if (IsWindow(window)) {
    DestroyWindow(window);
  }
  UnregisterClassW(kWindowClassName, instance);
  return EXIT_SUCCESS;
}
