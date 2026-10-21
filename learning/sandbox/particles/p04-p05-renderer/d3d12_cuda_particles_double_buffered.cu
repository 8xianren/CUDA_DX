#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE

#include <cuda_runtime.h>
#include <nvtx3/nvToolsExt.h>

#include <windows.h>
#include <d3d12.h>
#include <d3dcompiler.h>
#include <dxgi1_6.h>
#include <wrl/client.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

using Microsoft::WRL::ComPtr;

// NVTX 只描述 CPU 提交区间；GPU kernel/D3D12 workload 的实际持续时间由
// Nsight Systems 的 CUDA/DX12 activity 提供。用 RAII 配对 push/pop，避免
// 在复杂互操作路径中遗漏结束标记，且不改变 CUDA/D3D12 同步语义。
struct NvtxRange {
  explicit NvtxRange(const char* name) noexcept { nvtxRangePushA(name); }
  ~NvtxRange() noexcept { nvtxRangePop(); }
  NvtxRange(const NvtxRange&) = delete;
  NvtxRange& operator=(const NvtxRange&) = delete;
};

// 教学 demo 采用 fail-fast：CUDA/D3D12 调用一旦失败就立即打印调用名和
// 错误码。图形互操作错误如果继续向后运行，通常只会表现成黑屏或设备移除，
// 反而更难判断究竟是 handle 导入、资源状态还是 kernel 出错。
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
constexpr UINT kParticleStateCount = 2;
constexpr UINT kParticleGridSide = 64;
constexpr UINT kParticleCount = kParticleGridSide * kParticleGridSide;
constexpr UINT64 kParticleBufferBytes =
    static_cast<UINT64>(kParticleCount) * 3 * sizeof(float4);
constexpr float kFixedTimeStep = 1.0f / 120.0f;
constexpr int kMaxSubstepsPerFrame = 8;
constexpr wchar_t kWindowClassName[] =
    L"CudaD3D12DoubleBufferedParticlesClass";

// 每一份 shared allocation 在 CUDA 和 D3D12 中保持完全相同的 SoA 解释：
//
//   float4[0, N)    = position：xy 位置、z 深度、w 粒子半径
//   float4[N, 2N)   = velocity：xy 速度，其余分量预留
//   float4[2N, 3N)  = color：RGBA
//
// CUDA kernel 需要 position+velocity，D3D12 Vertex Shader 只通过两个 SRV
// 读取 position+color。双缓冲拥有两块这样的物理 allocation；每块都在两个
// API 间直接共享，仍然没有逐帧 CPU/GPU 复制。
__global__ void initialize_particle_soa(float4* base, int particle_count,
                                        int grid_side) {
  const int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index >= particle_count) {
    return;
  }

  float4* const positions = base;
  float4* const velocities = base + particle_count;
  float4* const colors = base + 2 * particle_count;

  const int row = index / grid_side;
  const int column = index - row * grid_side;
  const float u = static_cast<float>(column) /
                  static_cast<float>(grid_side - 1);
  const float v = static_cast<float>(row) /
                  static_cast<float>(grid_side - 1);

  // 初始位置放在 NDC 中央的 1.5×1.5 区域，给边界运动留出空间。
  const float x = -0.75f + 1.50f * u;
  const float y = -0.75f + 1.50f * v;
  positions[index] = make_float4(x, y, 0.5f, 0.0090f);

  // 初速度沿绕原点的切线方向，使规则网格开始旋转；归一化时给中心附近
  // 加 epsilon，避免 r=0 导致除零。这里只为直观看见 CUDA 每帧确实在写，
  // 不是试图实现完整的粒子力学系统。
  const float inverse_radius = rsqrtf(fmaxf(x * x + y * y, 1.0e-6f));
  const float speed = 0.12f + 0.05f * u;
  velocities[index] =
      make_float4(-y * inverse_radius * speed,
                  x * inverse_radius * speed, 0.0f, 0.0f);

  colors[index] =
      make_float4(0.15f + 0.85f * u,
                  0.20f + 0.75f * v,
                  0.95f - 0.45f * u, 1.0f);
}

__global__ void simulate_particle_soa(float4* base, int particle_count,
                                      float dt, int substep_count) {
  const int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index >= particle_count) {
    return;
  }

  float4* const positions = base;
  float4* const velocities = base + particle_count;

  // 每个线程把自己粒子的 position/velocity 各读一次到寄存器，在多个固定
  // 子步中复用，最后各写回一次。粒子之间没有相互作用，所以不需要原子操作
  // 或 block 同步，且 SoA 连续索引让相邻线程访问相邻 float4。
  float4 position = positions[index];
  float4 velocity = velocities[index];

  constexpr float horizontal_spring = 0.10f;
  constexpr float gravity_y = -0.20f;
  constexpr float restitution = 0.92f;

  for (int step = 0; step < substep_count; ++step) {
    // 半隐式 Euler：先由加速度更新速度，再使用新速度更新位置。
    // x 方向施加很弱的回中心力，y 方向施加恒定重力，只为形成容易观察的
    // 运动；积分器本身已在 P.3.1 单独验证。
    velocity.x += (-horizontal_spring * position.x) * dt;
    velocity.y += gravity_y * dt;
    position.x += velocity.x * dt;
    position.y += velocity.y * dt;

    // 边界用粒子半径内缩，保证粒子中心反弹时圆盘不会大面积越出窗口。
    // 碰撞时先把位置夹回合法区间，再翻转指向墙外的速度并乘恢复系数，
    // 避免粒子由于一步跨过边界后反复卡在墙外。
    const float limit = 0.95f - position.w;
    if (position.x < -limit) {
      position.x = -limit;
      velocity.x = fabsf(velocity.x) * restitution;
    } else if (position.x > limit) {
      position.x = limit;
      velocity.x = -fabsf(velocity.x) * restitution;
    }

    if (position.y < -limit) {
      position.y = -limit;
      velocity.y = fabsf(velocity.y) * restitution;
    } else if (position.y > limit) {
      position.y = limit;
      velocity.y = -fabsf(velocity.y) * restitution;
    }
  }

  positions[index] = position;
  velocities[index] = velocity;
}

struct FrameResources {
  ComPtr<ID3D12CommandAllocator> command_allocator;
  ComPtr<ID3D12Resource> back_buffer;
  D3D12_CPU_DESCRIPTOR_HANDLE rtv{};

  // 这个值来自只由 D3D12 queue signal 的 d3d_done_fence。CPU 只有即将
  // Reset 同一个 allocator 且该值尚未完成时才等待；它不是 CUDA/D3D12
  // 交接所需的逐帧 CPU 同步。
  UINT64 fence_value = 0;
};

// 一份可独立交接的完整粒子状态。
//
// 两份状态都包含 position/velocity/color 三段 SoA，并分别拥有自己的
// D3D12 committed resource、CUDA external memory 映射和进度值。某一帧中：
//   - render state 只由 D3D12 读取；
//   - update state 只由 CUDA 原地推进到未来模拟时刻。
// 因为访问的是不同 allocation，两项 GPU 工作具备并行执行的条件。
struct SharedParticleState {
  ComPtr<ID3D12Resource> resource;
  cudaExternalMemory_t external_memory = nullptr;
  float4* cuda_base = nullptr;

  // cuda_ready_value 属于 cuda_ready_fence：CUDA signal，D3D12 wait。
  // d3d_done_value 属于 d3d_done_fence：D3D12 signal，CUDA wait。
  UINT64 cuda_ready_value = 0;
  UINT64 d3d_done_value = 0;

  // 两个 Buffer 都从模拟 step 0 初始化。因为它们轮流更新，每次 CUDA
  // 可能需要从较旧 step 一次追到当前 target step。
  UINT64 simulated_step = 0;
  UINT64 rendered_frames = 0;
};

struct Renderer {
  ComPtr<IDXGIFactory6> factory;
  ComPtr<ID3D12Device> device;
  ComPtr<ID3D12CommandQueue> command_queue;
  ComPtr<IDXGISwapChain3> swap_chain;
  ComPtr<ID3D12DescriptorHeap> rtv_heap;
  ComPtr<ID3D12DescriptorHeap> srv_heap;
  ComPtr<ID3D12GraphicsCommandList> command_list;
  ComPtr<ID3D12RootSignature> root_signature;
  ComPtr<ID3D12PipelineState> pipeline_state;
  std::array<FrameResources, kBackBufferCount> frames;

  std::array<SharedParticleState, kParticleStateCount> particle_states;

  // 真正并行时不能让两个独立 GPU 队列随意 signal 同一条 timeline：较大的
  // value 可能先完成，破坏“完成 value N 代表此前 value 都完成”的含义。
  // 因此拆成两条单生产者时间线：
  //   cuda_ready_fence：只由 CUDA signal，只由 D3D12 wait；
  //   d3d_done_fence ：只由 D3D12 signal，只由 CUDA wait。
  ComPtr<ID3D12Fence> cuda_ready_fence;
  ComPtr<ID3D12Fence> d3d_done_fence;
  cudaExternalSemaphore_t cuda_ready_semaphore = nullptr;
  cudaExternalSemaphore_t d3d_done_semaphore = nullptr;
  cudaStream_t cuda_stream = nullptr;
  UINT64 next_cuda_ready_value = 1;
  UINT64 next_d3d_done_value = 1;
  UINT render_state_index = 0;

  D3D12_VIEWPORT viewport{};
  D3D12_RECT scissor{};
  HANDLE fence_event = nullptr;

  UINT64 frame_reuse_cpu_waits = 0;
  UINT64 interop_cpu_waits = 0;
  UINT64 simulated_substeps = 0;
  UINT64 maximum_catch_up_substeps = 0;
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
      L"CUDA + D3D12 Particle Project - Double-Buffered Particles",
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

D3D12_HEAP_PROPERTIES make_heap_properties(D3D12_HEAP_TYPE type) {
  D3D12_HEAP_PROPERTIES properties{};
  properties.Type = type;
  properties.CPUPageProperty = D3D12_CPU_PAGE_PROPERTY_UNKNOWN;
  properties.MemoryPoolPreference = D3D12_MEMORY_POOL_UNKNOWN;
  properties.CreationNodeMask = 1;
  properties.VisibleNodeMask = 1;
  return properties;
}

D3D12_RESOURCE_DESC make_buffer_description(UINT64 byte_count,
                                             D3D12_RESOURCE_FLAGS flags) {
  D3D12_RESOURCE_DESC description{};
  description.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
  description.Width = byte_count;
  description.Height = 1;
  description.DepthOrArraySize = 1;
  description.MipLevels = 1;
  description.Format = DXGI_FORMAT_UNKNOWN;
  description.SampleDesc.Count = 1;
  description.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
  description.Flags = flags;
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

  D3D12_COMMAND_QUEUE_DESC queue_description{};
  queue_description.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
  queue_description.Priority = D3D12_COMMAND_QUEUE_PRIORITY_NORMAL;
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

  D3D12_DESCRIPTOR_HEAP_DESC rtv_heap_description{};
  rtv_heap_description.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
  rtv_heap_description.NumDescriptors = kBackBufferCount;
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

  HR_CHECK(renderer.device->CreateCommandList(
      0, D3D12_COMMAND_LIST_TYPE_DIRECT,
      renderer.frames[0].command_allocator.Get(), nullptr,
      IID_PPV_ARGS(&renderer.command_list)));
  HR_CHECK(renderer.command_list->Close());

  renderer.fence_event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (renderer.fence_event == nullptr) {
    std::fprintf(stderr, "CreateEventW failed: %lu\n", GetLastError());
    std::exit(EXIT_FAILURE);
  }

  renderer.viewport = {0.0f, 0.0f, static_cast<float>(kWindowWidth),
                       static_cast<float>(kWindowHeight), 0.0f, 1.0f};
  renderer.scissor = {0, 0, static_cast<LONG>(kWindowWidth),
                      static_cast<LONG>(kWindowHeight)};
  return renderer;
}

std::wstring executable_directory() {
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
  // 继续复用 P.4.2 的 HLSL 和图形接口：t0=position、t1=color。动态化只改变
  // Buffer 的创建/生产者和同步，不改变消费者，便于隔离互操作问题。
  D3D12_DESCRIPTOR_RANGE srv_range{};
  srv_range.RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
  srv_range.NumDescriptors = 2;
  srv_range.BaseShaderRegister = 0;
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
  root_description.Flags =
      D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;

  ComPtr<ID3DBlob> serialized_signature;
  ComPtr<ID3DBlob> diagnostics;
  const HRESULT serialize_result = D3D12SerializeRootSignature(
      &root_description, D3D_ROOT_SIGNATURE_VERSION_1,
      &serialized_signature, &diagnostics);
  if (diagnostics != nullptr && diagnostics->GetBufferSize() > 0) {
    std::fwrite(diagnostics->GetBufferPointer(), 1,
                diagnostics->GetBufferSize(), stderr);
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
  rasterizer.CullMode = D3D12_CULL_MODE_NONE;
  rasterizer.DepthBias = D3D12_DEFAULT_DEPTH_BIAS;
  rasterizer.DepthBiasClamp = D3D12_DEFAULT_DEPTH_BIAS_CLAMP;
  rasterizer.SlopeScaledDepthBias = D3D12_DEFAULT_SLOPE_SCALED_DEPTH_BIAS;
  rasterizer.DepthClipEnable = TRUE;
  rasterizer.ConservativeRaster =
      D3D12_CONSERVATIVE_RASTERIZATION_MODE_OFF;

  D3D12_BLEND_DESC blend{};
  for (D3D12_RENDER_TARGET_BLEND_DESC& target : blend.RenderTarget) {
    target.SrcBlend = D3D12_BLEND_ONE;
    target.DestBlend = D3D12_BLEND_ZERO;
    target.BlendOp = D3D12_BLEND_OP_ADD;
    target.SrcBlendAlpha = D3D12_BLEND_ONE;
    target.DestBlendAlpha = D3D12_BLEND_ZERO;
    target.BlendOpAlpha = D3D12_BLEND_OP_ADD;
    target.LogicOp = D3D12_LOGIC_OP_NOOP;
    target.RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
  }

  D3D12_DEPTH_STENCILOP_DESC stencil_face{};
  stencil_face.StencilFailOp = D3D12_STENCIL_OP_KEEP;
  stencil_face.StencilDepthFailOp = D3D12_STENCIL_OP_KEEP;
  stencil_face.StencilPassOp = D3D12_STENCIL_OP_KEEP;
  stencil_face.StencilFunc = D3D12_COMPARISON_FUNC_ALWAYS;
  D3D12_DEPTH_STENCIL_DESC depth_stencil{};
  depth_stencil.DepthEnable = FALSE;
  depth_stencil.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ZERO;
  depth_stencil.DepthFunc = D3D12_COMPARISON_FUNC_ALWAYS;
  depth_stencil.StencilEnable = FALSE;
  depth_stencil.StencilReadMask = D3D12_DEFAULT_STENCIL_READ_MASK;
  depth_stencil.StencilWriteMask = D3D12_DEFAULT_STENCIL_WRITE_MASK;
  depth_stencil.FrontFace = stencil_face;
  depth_stencil.BackFace = stencil_face;

  D3D12_GRAPHICS_PIPELINE_STATE_DESC pipeline_description{};
  pipeline_description.pRootSignature = renderer.root_signature.Get();
  pipeline_description.VS = {vertex_shader->GetBufferPointer(),
                             vertex_shader->GetBufferSize()};
  pipeline_description.PS = {pixel_shader->GetBufferPointer(),
                             pixel_shader->GetBufferSize()};
  pipeline_description.InputLayout = {nullptr, 0};
  pipeline_description.BlendState = blend;
  pipeline_description.SampleMask = UINT_MAX;
  pipeline_description.RasterizerState = rasterizer;
  pipeline_description.DepthStencilState = depth_stencil;
  pipeline_description.PrimitiveTopologyType =
      D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
  pipeline_description.NumRenderTargets = 1;
  pipeline_description.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
  pipeline_description.SampleDesc.Count = 1;
  HR_CHECK(renderer.device->CreateGraphicsPipelineState(
      &pipeline_description, IID_PPV_ARGS(&renderer.pipeline_state)));
}

void create_shared_particle_buffer_and_srvs(Renderer& renderer) {
  // 两份状态必须是两个独立 allocation，而不是同一 allocation 内的两个
  // 区段。External interop 的交接和 D3D12 resource state 都以 Resource 为
  // 粒度；拆成两个 Resource，才能让 A 处于 SRV 状态被绘制的同时，B 保持
  // COMMON 状态由 CUDA 写入。
  const D3D12_HEAP_PROPERTIES default_heap =
      make_heap_properties(D3D12_HEAP_TYPE_DEFAULT);
  const D3D12_RESOURCE_DESC description = make_buffer_description(
      kParticleBufferBytes, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
  const D3D12_RESOURCE_ALLOCATION_INFO allocation =
      renderer.device->GetResourceAllocationInfo(0, 1, &description);

  for (UINT state_index = 0; state_index < kParticleStateCount;
       ++state_index) {
    SharedParticleState& state = renderer.particle_states[state_index];
    HR_CHECK(renderer.device->CreateCommittedResource(
        &default_heap, D3D12_HEAP_FLAG_SHARED, &description,
        D3D12_RESOURCE_STATE_COMMON, nullptr,
        IID_PPV_ARGS(&state.resource)));

    HANDLE memory_handle = nullptr;
    HR_CHECK(renderer.device->CreateSharedHandle(
        state.resource.Get(), nullptr, GENERIC_ALL, nullptr,
        &memory_handle));
    cudaExternalMemoryHandleDesc external_memory_description{};
    external_memory_description.type =
        cudaExternalMemoryHandleTypeD3D12Resource;
    external_memory_description.handle.win32.handle = memory_handle;
    external_memory_description.size = allocation.SizeInBytes;
    external_memory_description.flags = cudaExternalMemoryDedicated;
    CUDA_CHECK(cudaImportExternalMemory(&state.external_memory,
                                        &external_memory_description));
    CloseHandle(memory_handle);

    cudaExternalMemoryBufferDesc mapped_buffer_description{};
    mapped_buffer_description.offset = 0;
    mapped_buffer_description.size = kParticleBufferBytes;
    CUDA_CHECK(cudaExternalMemoryGetMappedBuffer(
        reinterpret_cast<void**>(&state.cuda_base), state.external_memory,
        &mapped_buffer_description));
  }

  // 每份 Buffer 需要连续两个 SRV：position、color。heap 中的布局为：
  //   descriptor 0/1 = state 0 的 t0/t1
  //   descriptor 2/3 = state 1 的 t0/t1
  // draw 时根表地址按 render_state_index 偏移两个 descriptor。
  D3D12_DESCRIPTOR_HEAP_DESC srv_heap_description{};
  srv_heap_description.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
  srv_heap_description.NumDescriptors = 2 * kParticleStateCount;
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

  D3D12_CPU_DESCRIPTOR_HANDLE srv =
      renderer.srv_heap->GetCPUDescriptorHandleForHeapStart();
  const UINT srv_increment =
      renderer.device->GetDescriptorHandleIncrementSize(
      D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);

  for (UINT state_index = 0; state_index < kParticleStateCount;
       ++state_index) {
    ID3D12Resource* const resource =
        renderer.particle_states[state_index].resource.Get();
    srv_description.Buffer.FirstElement = 0;
    renderer.device->CreateShaderResourceView(resource, &srv_description, srv);
    srv.ptr += srv_increment;

    srv_description.Buffer.FirstElement =
        static_cast<UINT64>(2) * kParticleCount;
    renderer.device->CreateShaderResourceView(resource, &srv_description, srv);
    srv.ptr += srv_increment;
  }

  std::printf(
      "double-buffered SoA: 2 x %llu useful bytes, "
      "allocation=%llu bytes each\n",
      static_cast<unsigned long long>(kParticleBufferBytes),
      static_cast<unsigned long long>(allocation.SizeInBytes));
}

void create_shared_fence_and_initialize_cuda(Renderer& renderer) {
  // 使用两条单向 timeline，而不是让两个独立队列 signal 同一条 timeline：
  //   cuda_ready_fence：CUDA 是唯一生产者，D3D12 只等待；
  //   d3d_done_fence ：D3D12 是唯一生产者，CUDA 只等待。
  // 这样不同 Buffer 上的 draw/update 可以真正并发，同时每条 timeline 的
  // value 完成顺序仍然严格单调。
  HR_CHECK(renderer.device->CreateFence(
      0, D3D12_FENCE_FLAG_SHARED,
      IID_PPV_ARGS(&renderer.cuda_ready_fence)));
  HR_CHECK(renderer.device->CreateFence(
      0, D3D12_FENCE_FLAG_SHARED,
      IID_PPV_ARGS(&renderer.d3d_done_fence)));

  auto import_fence_into_cuda =
      [&](ID3D12Fence* fence,
          cudaExternalSemaphore_t* external_semaphore) {
        HANDLE fence_handle = nullptr;
        HR_CHECK(renderer.device->CreateSharedHandle(
            fence, nullptr, GENERIC_ALL, nullptr, &fence_handle));
        cudaExternalSemaphoreHandleDesc semaphore_description{};
        semaphore_description.type =
            cudaExternalSemaphoreHandleTypeD3D12Fence;
        semaphore_description.handle.win32.handle = fence_handle;
        CUDA_CHECK(cudaImportExternalSemaphore(
            external_semaphore, &semaphore_description));
        CloseHandle(fence_handle);
      };
  import_fence_into_cuda(renderer.cuda_ready_fence.Get(),
                         &renderer.cuda_ready_semaphore);
  import_fence_into_cuda(renderer.d3d_done_fence.Get(),
                         &renderer.d3d_done_semaphore);

  CUDA_CHECK(cudaStreamCreateWithFlags(&renderer.cuda_stream,
                                       cudaStreamNonBlocking));

  // 两份状态都从相同的 step 0 初始化。CUDA stream 内两个 kernel 串行，
  // 随后的一个 cuda-ready signal=1 同时代表两份初始化均已完成。
  constexpr int threads = 256;
  constexpr int blocks =
      (static_cast<int>(kParticleCount) + threads - 1) / threads;
  for (SharedParticleState& state : renderer.particle_states) {
    initialize_particle_soa<<<blocks, threads, 0, renderer.cuda_stream>>>(
        state.cuda_base, static_cast<int>(kParticleCount),
        static_cast<int>(kParticleGridSide));
  }
  CUDA_CHECK(cudaGetLastError());

  const UINT64 initial_cuda_ready = renderer.next_cuda_ready_value++;
  cudaExternalSemaphoreSignalParams signal_parameters{};
  signal_parameters.params.fence.value = initial_cuda_ready;
  CUDA_CHECK(cudaSignalExternalSemaphoresAsync(
      &renderer.cuda_ready_semaphore, &signal_parameters, 1,
      renderer.cuda_stream));
  for (SharedParticleState& state : renderer.particle_states) {
    state.cuda_ready_value = initial_cuda_ready;
  }
}

void wait_for_d3d_done_value(Renderer& renderer, UINT64 value,
                             const char* context) {
  if (renderer.d3d_done_fence->GetCompletedValue() >= value) {
    return;
  }
  HR_CHECK(renderer.d3d_done_fence->SetEventOnCompletion(
      value, renderer.fence_event));
  const DWORD wait_result =
      WaitForSingleObject(renderer.fence_event, INFINITE);
  if (wait_result != WAIT_OBJECT_0) {
    std::fprintf(stderr, "%s wait failed: %lu\n", context, GetLastError());
    std::exit(EXIT_FAILURE);
  }
}

void wait_until_frame_is_reusable(Renderer& renderer, FrameResources& frame) {
  if (frame.fence_value == 0 ||
      renderer.d3d_done_fence->GetCompletedValue() >= frame.fence_value) {
    return;
  }
  wait_for_d3d_done_value(renderer, frame.fence_value, "frame resource");
  ++renderer.frame_reuse_cpu_waits;
}

void schedule_cuda_update(Renderer& renderer, UINT update_state_index,
                          UINT64 target_simulation_step) {
  // 记录 CUDA stream 上 wait、kernel launch、signal 的主机排队区间；
  // kernel 真正执行的 GPU 时长由 Nsight 的 CUDA activity 单独给出。
  NvtxRange nvtx_range{"P5.2.double.cuda_update_enqueue"};

  SharedParticleState& update_state =
      renderer.particle_states[update_state_index];

  // 只等待“这一个 update Buffer 上一次被 D3D12 读完”的 value。当前 draw
  // 使用另一份 Buffer，因此二者之间没有依赖，可以并行。Buffer 首次更新时
  // d3d_done_value=0，说明它从未被绘制，无需插入 wait。
  if (update_state.d3d_done_value > 0) {
    cudaExternalSemaphoreWaitParams wait_parameters{};
    wait_parameters.params.fence.value = update_state.d3d_done_value;
    CUDA_CHECK(cudaWaitExternalSemaphoresAsync(
        &renderer.d3d_done_semaphore, &wait_parameters, 1,
        renderer.cuda_stream));
  }

  // 两份状态都从 step 0 出发，但轮流更新。比如当前显示 A(step 10)，B 可能
  // 仍停在 step 8；CUDA 对 B 一次执行 target-8 个固定子步，下一帧显示 B。
  // 这不是用大 dt 跳步，而是仍在 kernel 循环中逐个执行 1/120 s 子步。
  const UINT64 catch_up_substeps =
      target_simulation_step - update_state.simulated_step;
  renderer.maximum_catch_up_substeps =
      std::max(renderer.maximum_catch_up_substeps, catch_up_substeps);

  if (catch_up_substeps > 0) {
    constexpr int threads = 256;
    constexpr int blocks =
        (static_cast<int>(kParticleCount) + threads - 1) / threads;
    simulate_particle_soa<<<blocks, threads, 0, renderer.cuda_stream>>>(
        update_state.cuda_base, static_cast<int>(kParticleCount),
        kFixedTimeStep, static_cast<int>(catch_up_substeps));
    CUDA_CHECK(cudaGetLastError());
    renderer.simulated_substeps += catch_up_substeps;
  }

  // cuda_ready_fence 只由这个 CUDA stream signal，因此 value 的完成顺序
  // 必然与提交顺序一致，不会出现跨队列“较大 value 先完成”的歧义。
  const UINT64 cuda_ready_value = renderer.next_cuda_ready_value++;
  cudaExternalSemaphoreSignalParams signal_parameters{};
  signal_parameters.params.fence.value = cuda_ready_value;
  CUDA_CHECK(cudaSignalExternalSemaphoresAsync(
      &renderer.cuda_ready_semaphore, &signal_parameters, 1,
      renderer.cuda_stream));
  update_state.cuda_ready_value = cuda_ready_value;
  update_state.simulated_step = target_simulation_step;
}

void render_and_schedule_next_simulation(Renderer& renderer,
                                         UINT64 target_simulation_step,
                                         UINT present_sync_interval) {
  NvtxRange frame_range{"P5.2.double.frame"};

  // 交换链 Back Buffer index 与粒子状态 index 是两套独立轮换：
  //   frame_index       选择本帧输出到哪张显示图像；
  //   render_state_index 选择本帧读取哪份粒子模拟状态。
  const UINT frame_index = renderer.swap_chain->GetCurrentBackBufferIndex();
  FrameResources& frame = renderer.frames[frame_index];
  const UINT render_state_index = renderer.render_state_index;
  const UINT update_state_index = 1u - render_state_index;
  SharedParticleState& render_state =
      renderer.particle_states[render_state_index];
  wait_until_frame_is_reusable(renderer, frame);

  HR_CHECK(frame.command_allocator->Reset());
  HR_CHECK(renderer.command_list->Reset(frame.command_allocator.Get(),
                                        renderer.pipeline_state.Get()));

  nvtxRangePushA("P5.2.double.d3d12_record_submit");

  // D3D12 只等待即将绘制的 render Buffer；CUDA 同时更新另一份 Buffer，
  // 两者没有资源冲突。Queue::Wait 排入 GPU 队列，不阻塞 CPU。
  HR_CHECK(renderer.command_queue->Wait(
      renderer.cuda_ready_fence.Get(), render_state.cuda_ready_value));

  // External Fence 负责谁先使用；Resource Barrier 负责 D3D12 内部怎样使用。
  // CUDA 获得资源时约定保持 COMMON；等待 CUDA signal 后，D3D12 才把它
  // 转成 Vertex Shader SRV 状态。两套机制都不能互相替代。
  std::array<D3D12_RESOURCE_BARRIER, 2> begin_barriers{};
  begin_barriers[0].Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
  begin_barriers[0].Transition.pResource = render_state.resource.Get();
  begin_barriers[0].Transition.Subresource =
      D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
  begin_barriers[0].Transition.StateBefore = D3D12_RESOURCE_STATE_COMMON;
  begin_barriers[0].Transition.StateAfter =
      D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;

  begin_barriers[1].Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
  begin_barriers[1].Transition.pResource = frame.back_buffer.Get();
  begin_barriers[1].Transition.Subresource =
      D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
  begin_barriers[1].Transition.StateBefore = D3D12_RESOURCE_STATE_PRESENT;
  begin_barriers[1].Transition.StateAfter =
      D3D12_RESOURCE_STATE_RENDER_TARGET;
  renderer.command_list->ResourceBarrier(
      static_cast<UINT>(begin_barriers.size()), begin_barriers.data());

  renderer.command_list->OMSetRenderTargets(1, &frame.rtv, FALSE, nullptr);
  const float clear_color[4] = {0.008f, 0.014f, 0.035f, 1.0f};
  renderer.command_list->ClearRenderTargetView(frame.rtv, clear_color, 0,
                                                nullptr);
  renderer.command_list->RSSetViewports(1, &renderer.viewport);
  renderer.command_list->RSSetScissorRects(1, &renderer.scissor);
  renderer.command_list->SetGraphicsRootSignature(
      renderer.root_signature.Get());
  ID3D12DescriptorHeap* heaps[] = {renderer.srv_heap.Get()};
  renderer.command_list->SetDescriptorHeaps(1, heaps);
  const UINT srv_increment = renderer.device->GetDescriptorHandleIncrementSize(
      D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
  D3D12_GPU_DESCRIPTOR_HANDLE particle_table =
      renderer.srv_heap->GetGPUDescriptorHandleForHeapStart();
  particle_table.ptr +=
      static_cast<UINT64>(render_state_index) * 2 * srv_increment;
  renderer.command_list->SetGraphicsRootDescriptorTable(
      0, particle_table);
  renderer.command_list->IASetPrimitiveTopology(
      D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  renderer.command_list->DrawInstanced(6, kParticleCount, 0, 0);

  std::array<D3D12_RESOURCE_BARRIER, 2> end_barriers{};
  end_barriers[0] = begin_barriers[0];
  end_barriers[0].Transition.StateBefore =
      D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
  end_barriers[0].Transition.StateAfter = D3D12_RESOURCE_STATE_COMMON;
  end_barriers[1] = begin_barriers[1];
  end_barriers[1].Transition.StateBefore =
      D3D12_RESOURCE_STATE_RENDER_TARGET;
  end_barriers[1].Transition.StateAfter = D3D12_RESOURCE_STATE_PRESENT;
  renderer.command_list->ResourceBarrier(
      static_cast<UINT>(end_barriers.size()), end_barriers.data());
  HR_CHECK(renderer.command_list->Close());

  ID3D12CommandList* command_lists[] = {renderer.command_list.Get()};
  renderer.command_queue->ExecuteCommandLists(1, command_lists);

  // d3d_done_fence 只有 D3D12 queue 会 signal，所以值按 queue 顺序完成。
  // 此 value 只归属于刚绘制的 render Buffer；未来 CUDA 要重新写这份 Buffer
  // 时才等待它，当前对另一份 update Buffer 的工作不受影响。
  const UINT64 d3d12_done_value = renderer.next_d3d_done_value++;
  HR_CHECK(renderer.command_queue->Signal(renderer.d3d_done_fence.Get(),
                                           d3d12_done_value));
  frame.fence_value = d3d12_done_value;
  render_state.d3d_done_value = d3d12_done_value;
  ++render_state.rendered_frames;
  nvtxRangePop();

  // 当前 D3D12 draw 读取 render_state；CUDA 推进另一个 update_state。
  // 由于两个 Resource 独立，这两项工作在硬件资源允许时可以重叠。
  nvtxRangePushA("P5.2.double.cuda_schedule");
  schedule_cuda_update(renderer, update_state_index,
                       target_simulation_step);
  nvtxRangePop();

  // CUDA 更新的对象是独立的 shared particle Buffer，不是 Back Buffer，
  // 所以它可以在当前图像进入 Present 阶段时开始。下一帧 draw 仍会先等待
  // cuda_ready_value，不会读到写到一半的数据。
  nvtxRangePushA("P5.2.double.present");
  // 默认 sync interval=1 保持可视化演示的 60 Hz；性能采集时传入 0，
  // 避免 Present 的垂直同步把 CPU 帧时间固定在约 16.7 ms，从而掩盖
  // CUDA/D3D12 实际工作量差异。两种模式都使用同一份 GPU 依赖图。
  HR_CHECK(renderer.swap_chain->Present(present_sync_interval, 0));
  nvtxRangePop();

  // 下一帧角色互换：刚由 CUDA 更新的 Buffer 成为 render Buffer；刚绘制的
  // Buffer 则成为 CUDA 下一次要追赶到未来 target step 的 update Buffer。
  renderer.render_state_index = update_state_index;
}

void shutdown_gpu_and_cuda(Renderer& renderer) {
  // 退出时允许 CPU 同步：先等所有 CUDA update/cuda-ready signal 完成。
  // D3D12 queue 中若正等待其中某个 ready value，也因此能够继续执行完毕。
  CUDA_CHECK(cudaStreamSynchronize(renderer.cuda_stream));

  // d3d_done_fence 只由同一条 D3D12 queue signal，可以继续安全递增并用于
  // shutdown flush。这个 CPU wait 不属于逐帧双缓冲交接。
  const UINT64 shutdown_value = renderer.next_d3d_done_value++;
  HR_CHECK(renderer.command_queue->Signal(renderer.d3d_done_fence.Get(),
                                           shutdown_value));
  wait_for_d3d_done_value(renderer, shutdown_value, "shutdown");
}

void destroy_cuda_interop(Renderer& renderer) {
  if (renderer.cuda_ready_semaphore != nullptr) {
    CUDA_CHECK(cudaDestroyExternalSemaphore(
        renderer.cuda_ready_semaphore));
    renderer.cuda_ready_semaphore = nullptr;
  }
  if (renderer.d3d_done_semaphore != nullptr) {
    CUDA_CHECK(cudaDestroyExternalSemaphore(
        renderer.d3d_done_semaphore));
    renderer.d3d_done_semaphore = nullptr;
  }
  if (renderer.cuda_stream != nullptr) {
    CUDA_CHECK(cudaStreamDestroy(renderer.cuda_stream));
    renderer.cuda_stream = nullptr;
  }

  // 每份 mapped pointer 都必须在其 external memory 对象之前释放。
  for (SharedParticleState& state : renderer.particle_states) {
    if (state.cuda_base != nullptr) {
      CUDA_CHECK(cudaFree(state.cuda_base));
      state.cuda_base = nullptr;
    }
    if (state.external_memory != nullptr) {
      CUDA_CHECK(cudaDestroyExternalMemory(state.external_memory));
      state.external_memory = nullptr;
    }
  }
}

int parse_frame_limit(int argc, char** argv) {
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

UINT parse_present_sync_interval(int argc, char** argv) {
  UINT sync_interval = 1;
  for (int index = 1; index + 1 < argc; ++index) {
    if (std::strcmp(argv[index], "--vsync") == 0) {
      const long parsed = std::strtol(argv[index + 1], nullptr, 10);
      if (parsed == 0 || parsed == 1) {
        sync_interval = static_cast<UINT>(parsed);
      }
    }
  }
  return sync_interval;
}

int parse_fixed_substeps(int argc, char** argv) {
  // -1 表示使用实时 accumulator；非负值用于性能基准，让每帧提交完全
  // 相同的模拟工作量，避免无 VSync 时因墙钟时间不同而无法公平比较。
  int fixed_substeps = -1;
  for (int index = 1; index + 1 < argc; ++index) {
    if (std::strcmp(argv[index], "--fixed-substeps") == 0) {
      const long parsed = std::strtol(argv[index + 1], nullptr, 10);
      if (parsed >= 0 && parsed <= 1000000) {
        fixed_substeps = static_cast<int>(parsed);
      }
    }
  }
  return fixed_substeps;
}

int main(int argc, char** argv) {
  SetProcessDPIAware();
  HINSTANCE instance = GetModuleHandleW(nullptr);
  HWND window = create_window(instance);
  Renderer renderer = create_renderer(window);
  create_root_signature_and_pipeline(renderer);
  create_shared_particle_buffer_and_srvs(renderer);
  create_shared_fence_and_initialize_cuda(renderer);
  const int frame_limit = parse_frame_limit(argc, argv);
  const UINT present_sync_interval =
      parse_present_sync_interval(argc, argv);
  const int fixed_substeps = parse_fixed_substeps(argc, argv);

  using Clock = std::chrono::steady_clock;
  Clock::time_point previous_time = Clock::now();
  double fixed_step_accumulator = 0.0;
  UINT64 target_simulation_step = 0;
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

    int substep_count = 0;
    if (fixed_substeps >= 0) {
      // 基准模式不读取墙钟时间；单/双缓冲每帧获得同一个 N，便于把
      // “双缓冲是否重叠”和“执行了约两倍积分”分别从报告中读出来。
      substep_count = fixed_substeps;
    } else {
      // 渲染帧率可以波动，但模拟只执行整数个 1/120 s 子步。accumulator
      // 上限防止拖动窗口/断点造成“追赶风暴”；超过上限的墙钟时间被丢弃。
      const Clock::time_point current_time = Clock::now();
      const double elapsed_seconds =
          std::chrono::duration<double>(current_time - previous_time).count();
      previous_time = current_time;
      const double maximum_accumulator =
          static_cast<double>(kFixedTimeStep) * kMaxSubstepsPerFrame;
      fixed_step_accumulator = std::min(
          fixed_step_accumulator + std::min(elapsed_seconds, 0.25),
          maximum_accumulator);

      substep_count = std::min(
          static_cast<int>(fixed_step_accumulator /
                           static_cast<double>(kFixedTimeStep)),
          kMaxSubstepsPerFrame);
      fixed_step_accumulator -=
          static_cast<double>(substep_count) * kFixedTimeStep;
    }
    target_simulation_step += static_cast<UINT64>(substep_count);

    render_and_schedule_next_simulation(renderer, target_simulation_step,
                                        present_sync_interval);
    ++rendered_frames;
    if (frame_limit > 0 &&
        rendered_frames >= static_cast<std::uint64_t>(frame_limit)) {
      running = false;
    }
  }

  shutdown_gpu_and_cuda(renderer);
  std::printf("rendered frames: %llu\n",
              static_cast<unsigned long long>(rendered_frames));
  std::printf("target simulation step (dt=1/120 s): %llu\n",
              static_cast<unsigned long long>(target_simulation_step));
  std::printf("executed catch-up substeps across both buffers: %llu\n",
              static_cast<unsigned long long>(
                  renderer.simulated_substeps));
  std::printf("maximum substeps in one buffer catch-up: %llu\n",
              static_cast<unsigned long long>(
                  renderer.maximum_catch_up_substeps));
  for (UINT state_index = 0; state_index < kParticleStateCount;
       ++state_index) {
    const SharedParticleState& state =
        renderer.particle_states[state_index];
    std::printf(
        "particle state %u: rendered=%llu, simulated_step=%llu, "
        "cuda_ready=%llu, d3d_done=%llu\n",
        state_index,
        static_cast<unsigned long long>(state.rendered_frames),
        static_cast<unsigned long long>(state.simulated_step),
        static_cast<unsigned long long>(state.cuda_ready_value),
        static_cast<unsigned long long>(state.d3d_done_value));
  }
  std::printf("completed cuda-ready fence: %llu\n",
              static_cast<unsigned long long>(
                  renderer.cuda_ready_fence->GetCompletedValue()));
  std::printf("completed d3d-done fence: %llu\n",
              static_cast<unsigned long long>(
                  renderer.d3d_done_fence->GetCompletedValue()));
  std::printf("CUDA/D3D12 intermediate CPU waits: %llu\n",
              static_cast<unsigned long long>(renderer.interop_cpu_waits));
  std::printf("frame-resource CPU waits: %llu\n",
              static_cast<unsigned long long>(
                  renderer.frame_reuse_cpu_waits));
  std::printf("CUDA + D3D12 double-buffered particles: PASS\n");

  destroy_cuda_interop(renderer);
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
