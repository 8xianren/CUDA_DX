#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE

#include <cuda_runtime.h>

#include <windows.h>
#include <d3d12.h>
#include <dxgi1_6.h>
#include <wrl/client.h>

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

using Microsoft::WRL::ComPtr;

// CUDA 和 D3D12 都采用“函数返回错误码”的风格。
// 教学 demo 不做复杂的异常恢复：一旦失败就打印具体调用与错误并终止，
// 避免错误被拖到后面，最终只表现成黑屏或设备移除而难以定位。
#define CUDA_CHECK(call)                                                        \
  do {                                                                          \
    const cudaError_t error = (call);                                            \
    if (error != cudaSuccess) {                                                  \
      std::fprintf(stderr, "%s failed: %s\n", #call,                          \
                   cudaGetErrorString(error));                                   \
      std::exit(EXIT_FAILURE);                                                   \
    }                                                                            \
  } while (0)

#define HR_CHECK(call)                                                          \
  do {                                                                          \
    const HRESULT hr_check_result = (call);                                      \
    if (FAILED(hr_check_result)) {                                               \
      std::fprintf(stderr, "%s failed: HRESULT 0x%08lx\n", #call,             \
                   static_cast<unsigned long>(hr_check_result));                 \
      std::exit(EXIT_FAILURE);                                                   \
    }                                                                            \
  } while (0)

constexpr UINT kWindowWidth = 1280;
constexpr UINT kWindowHeight = 720;
constexpr UINT kBackBufferCount = 2;
constexpr wchar_t kWindowClassName[] = L"CudaD3D12WindowClass";

// 一个 Back Buffer 对应一套可独立复用的帧资源。
//
// Command Allocator 保存 command list 录制所需的底层内存。GPU 还在执行从它
// 生成的命令时，CPU 不能 Reset 它。因此每个交换链图像各持有一个 allocator，
// 并用 fence_value 记录“这个 allocator 上一次提交何时才算执行完成”。
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

  HANDLE fence_event = nullptr;
  UINT64 next_fence_value = 1;
  UINT64 frame_reuse_cpu_waits = 0;
};

// Win32 把窗口事件（关闭、按键等）投递给这个回调。
// 本节固定窗口尺寸，暂不处理 WM_SIZE；这样不会在同一小节引入交换链重建。
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
  // 固定尺寸窗口避免本节处理 ResizeBuffers。AdjustWindowRect 根据标题栏和
  // 边框反推外部尺寸，保证真正的客户区仍是 1280x720。
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
      0, kWindowClassName, L"CUDA + D3D12 Particle Project - Clear Window",
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

// 不能按名称“RTX 5070”猜测 CUDA 与 D3D12 是否选中了同一块设备。
// Windows LUID 是适配器身份键：CUDA device property 和 DXGI adapter
// 的 8-byte LUID 完全一致，才允许后续安全导入 external memory/fence。
ComPtr<IDXGIAdapter1> find_cuda_adapter(IDXGIFactory6* factory,
                                        const cudaDeviceProp& cuda_properties) {
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

    if (std::memcmp(cuda_properties.luid, &description.AdapterLuid,
                    sizeof(cuda_properties.luid)) == 0) {
      std::printf("matched CUDA/D3D12 adapter: %ls\n",
                  description.Description);
      return adapter;
    }
  }

  std::fprintf(stderr, "No DXGI adapter matches CUDA device 0 LUID.\n");
  std::exit(EXIT_FAILURE);
}

Renderer create_renderer(HWND window) {
  Renderer renderer{};

  // 本项目以 CUDA device 0 为计算设备；随后必须让 D3D12 使用其 LUID
  // 对应的 DXGI adapter，否则两个 API 无法共享同一块物理显存。
  CUDA_CHECK(cudaSetDevice(0));
  cudaDeviceProp cuda_properties{};
  CUDA_CHECK(cudaGetDeviceProperties(&cuda_properties, 0));

  HR_CHECK(CreateDXGIFactory2(0, IID_PPV_ARGS(&renderer.factory)));
  ComPtr<IDXGIAdapter1> adapter =
      find_cuda_adapter(renderer.factory.Get(), cuda_properties);

  HR_CHECK(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0,
                             IID_PPV_ARGS(&renderer.device)));

  // DIRECT queue 能执行绘制、复制和资源屏障。后续 CUDA 不会把 kernel
  // 提交到这条队列，而是通过 external fence 与这条 D3D12 queue 排序。
  D3D12_COMMAND_QUEUE_DESC queue_description{};
  queue_description.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
  queue_description.Priority = D3D12_COMMAND_QUEUE_PRIORITY_NORMAL;
  queue_description.Flags = D3D12_COMMAND_QUEUE_FLAG_NONE;
  HR_CHECK(renderer.device->CreateCommandQueue(
      &queue_description, IID_PPV_ARGS(&renderer.command_queue)));

  // Flip model 是现代 D3D12 推荐的交换链模型。双缓冲意味着：显示系统读取
  // 一张图像时，应用可以准备另一张图像；Present 后两者角色轮换。
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

  // 禁止 DXGI 默认的 Alt+Enter 全屏切换。本教学 demo 没有实现全屏资源重建，
  // 因此显式禁用可避免窗口状态与交换链尺寸失配。
  HR_CHECK(renderer.factory->MakeWindowAssociation(
      window, DXGI_MWA_NO_ALT_ENTER));

  // RTV descriptor heap 只保存描述符，不保存图像数据。每个描述符告诉 D3D12：
  // “把对应交换链 Resource 当作 Render Target View 使用”。
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

  // Command List 是命令录制器，可以在不同帧 Reset 后反复使用；
  // Command Allocator 才是不能在 GPU 执行完之前重置的底层存储。
  HR_CHECK(renderer.device->CreateCommandList(
      0, D3D12_COMMAND_LIST_TYPE_DIRECT,
      renderer.frames[0].command_allocator.Get(), nullptr,
      IID_PPV_ARGS(&renderer.command_list)));
  HR_CHECK(renderer.command_list->Close());

  // Fence 是单调递增的时间线。这里用于保护帧资源复用；后续还会额外创建
  // 可共享 Fence，作为 CUDA external semaphore 与 D3D12 queue 的交接棒。
  HR_CHECK(renderer.device->CreateFence(
      0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&renderer.fence)));
  renderer.fence_event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (renderer.fence_event == nullptr) {
    std::fprintf(stderr, "CreateEventW failed: %lu\n", GetLastError());
    std::exit(EXIT_FAILURE);
  }

  return renderer;
}

// 仅在 CPU 即将重用仍被 GPU 使用的 FrameResources 时等待。
// queue->Signal 本身不会阻塞 CPU；SetEventOnCompletion + WaitForSingleObject
// 才是明确的 CPU 阻塞点。
void wait_until_frame_is_reusable(Renderer& renderer, FrameResources& frame) {
  if (frame.fence_value == 0 ||
      renderer.fence->GetCompletedValue() >= frame.fence_value) {
    return;
  }

  HR_CHECK(renderer.fence->SetEventOnCompletion(frame.fence_value,
                                                 renderer.fence_event));
  const DWORD wait_result =
      WaitForSingleObject(renderer.fence_event, INFINITE);
  if (wait_result != WAIT_OBJECT_0) {
    std::fprintf(stderr, "WaitForSingleObject failed: %lu\n",
                 GetLastError());
    std::exit(EXIT_FAILURE);
  }
  ++renderer.frame_reuse_cpu_waits;
}

void render_clear_frame(Renderer& renderer, std::uint64_t frame_number) {
  const UINT frame_index = renderer.swap_chain->GetCurrentBackBufferIndex();
  FrameResources& frame = renderer.frames[frame_index];

  // 只有确认 GPU 已执行完该 allocator 上一次生成的命令，才能安全 Reset。
  wait_until_frame_is_reusable(renderer, frame);
  HR_CHECK(frame.command_allocator->Reset());
  HR_CHECK(renderer.command_list->Reset(frame.command_allocator.Get(),
                                        nullptr));

  // SwapChain Back Buffer 在 Present 状态交给显示系统。
  // ClearRenderTargetView 前必须转换为 RENDER_TARGET；清完后再转回 PRESENT。
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

  // 缓慢变化的颜色比固定黑屏更容易证明消息循环、录制、执行和 Present
  // 确实连续工作，而不是只显示了创建窗口时留下的一帧。
  const float phase =
      static_cast<float>(frame_number % 240) / 239.0f;
  const float clear_color[4] = {
      0.04f + 0.20f * phase,
      0.08f + 0.08f * (1.0f - phase),
      0.24f + 0.28f * (1.0f - phase),
      1.0f,
  };
  renderer.command_list->ClearRenderTargetView(frame.rtv, clear_color, 0,
                                                nullptr);

  D3D12_RESOURCE_BARRIER to_present = to_render_target;
  to_present.Transition.StateBefore =
      D3D12_RESOURCE_STATE_RENDER_TARGET;
  to_present.Transition.StateAfter = D3D12_RESOURCE_STATE_PRESENT;
  renderer.command_list->ResourceBarrier(1, &to_present);
  HR_CHECK(renderer.command_list->Close());

  ID3D12CommandList* command_lists[] = {renderer.command_list.Get()};
  renderer.command_queue->ExecuteCommandLists(1, command_lists);

  // sync interval=1 请求与垂直刷新同步。Present 负责让 DXGI 轮换当前
  // Back Buffer；下一帧必须重新调用 GetCurrentBackBufferIndex。
  HR_CHECK(renderer.swap_chain->Present(1, 0));

  // 记录“本次使用该 frame allocator 的命令”对应的 fence 值。
  // 下次交换链回到同一个 frame_index 时，先检查这个值是否完成。
  const UINT64 submitted_value = renderer.next_fence_value++;
  HR_CHECK(renderer.command_queue->Signal(renderer.fence.Get(),
                                           submitted_value));
  frame.fence_value = submitted_value;
}

// 程序退出前等待整条 D3D12 queue 清空，确保 COM Resource 不会在 GPU 仍引用
// 它们时析构。这个等待只发生在 shutdown，不属于逐帧渲染路径。
void flush_gpu(Renderer& renderer) {
  const UINT64 flush_value = renderer.next_fence_value++;
  HR_CHECK(renderer.command_queue->Signal(renderer.fence.Get(), flush_value));
  if (renderer.fence->GetCompletedValue() < flush_value) {
    HR_CHECK(renderer.fence->SetEventOnCompletion(flush_value,
                                                   renderer.fence_event));
    const DWORD wait_result =
        WaitForSingleObject(renderer.fence_event, INFINITE);
    if (wait_result != WAIT_OBJECT_0) {
      std::fprintf(stderr, "shutdown wait failed: %lu\n", GetLastError());
      std::exit(EXIT_FAILURE);
    }
  }
}

int parse_frame_limit(int argc, char** argv) {
  // 默认自动渲染 180 帧后退出，便于 build.ps1 和自动验证不会永久挂起。
  // 手动观察时运行 `d3d12_window_clear.exe --frames 0`，0 表示直到关闭窗口。
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
  // 避免 Windows DPI 虚拟化把客户区尺寸和交换链像素尺寸悄悄缩放成两套数值。
  // 本 demo 不依赖返回值：若进程清单已设置 DPI awareness，调用可能返回 FALSE。
  SetProcessDPIAware();

  HINSTANCE instance = GetModuleHandleW(nullptr);
  HWND window = create_window(instance);
  Renderer renderer = create_renderer(window);
  const int frame_limit = parse_frame_limit(argc, argv);

  bool running = true;
  std::uint64_t rendered_frames = 0;
  while (running) {
    // PeekMessage 使用非阻塞消息泵：没有窗口消息时继续提交渲染帧。
    // 收到 WM_QUIT 后停止产生新命令，再统一 flush GPU。
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

    render_clear_frame(renderer, rendered_frames);
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
  std::printf("D3D12 window clear: PASS\n");

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
