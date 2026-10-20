#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE

// 这些是 Windows 图形/窗口 API 的 import library。把依赖写在源文件里，
// 这样本 demo 可以直接复用 learning/sandbox/build.ps1，而不要求脚本为
// 每个 D3D12 示例维护一份单独的链接参数。
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "d3d12.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "d3dcompiler.lib")
#pragma comment(lib, "dxguid.lib")

#include <windows.h>
#include <d3d12.h>
#include <d3d12sdklayers.h>
#include <d3dcompiler.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <DirectXMath.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

using Microsoft::WRL::ComPtr;
using namespace DirectX;

// D3D12 的大多数创建、录制和提交 API 返回 HRESULT。
// 教学 demo 在失败位置立即终止并打印调用名，避免错误被拖到后面才表现为黑屏。
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
constexpr UINT kTextureWidth = 256;
constexpr UINT kTextureHeight = 256;
constexpr UINT kOpaqueInstanceCount = 3;
constexpr UINT kTotalInstanceCount = 6;
constexpr wchar_t kWindowClassName[] = L"CudaD3D12MeshDepthClass";

// 完整 Mip 链的级数由最大维度决定：每次把宽、高减半，直到两者都为 1。
// 256x256 因此有 9 级：256、128、64、32、16、8、4、2、1。
// 这里用 constexpr 循环让“级数不是拍脑袋常量”成为代码中的可检查事实；
// 如果以后只改纹理尺寸，D3D12 资源、SRV 和 Sampler 会自动使用正确级数。
constexpr UINT calculate_mip_level_count(UINT width, UINT height) {
  UINT levels = 1;
  UINT largest_dimension = width > height ? width : height;
  while (largest_dimension > 1) {
    largest_dimension = (largest_dimension + 1) / 2;
    ++levels;
  }
  return levels;
}

constexpr UINT kTextureMipLevels =
    calculate_mip_level_count(kTextureWidth, kTextureHeight);

// 交换链在 Flip Model 下使用普通 UNORM 格式；真正决定渲染写入时是否执行
// linear -> sRGB 编码的是 RTV 的格式。交换链返回的 UNORM Back Buffer 允许创建
// 同一格式族的 UNORM_SRGB RTV。PSO 的 RTVFormats[0] 必须与实际 RTV 格式一致。
constexpr DXGI_FORMAT kSwapChainFormat = DXGI_FORMAT_R8G8B8A8_UNORM;
constexpr DXGI_FORMAT kBackBufferRtvFormat =
    DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;

// 纹理 Resource 使用 TYPELESS：它拥有原始 RGBA8 存储，但不预先决定 RGB 字节
// 是线性 UNORM 还是 sRGB 编码。SRV 才规定本次读取解释；颜色纹理使用
// UNORM_SRGB，因此采样时 RGB 自动解码到线性空间，Alpha 仍只是线性 UNORM。
constexpr DXGI_FORMAT kColorTextureResourceFormat =
    DXGI_FORMAT_R8G8B8A8_TYPELESS;
constexpr DXGI_FORMAT kColorTextureSrvFormat =
    DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;

// sRGB 不是简单的 pow(x, 2.2)，而是一条分段传递函数。下面两函数只用于 CPU
// 侧教学自检；Shader 不调用它们，GPU 会依据 SRGB SRV/RTV 格式自动转换 RGB。
float srgb_to_linear(float encoded) {
  return encoded <= 0.04045f
             ? encoded / 12.92f
             : std::pow((encoded + 0.055f) / 1.055f, 2.4f);
}

float linear_to_srgb(float linear) {
  return linear <= 0.0031308f
             ? linear * 12.92f
             : 1.055f * std::pow(linear, 1.0f / 2.4f) - 0.055f;
}

void validate_srgb_reference_curve() {
  // 同一个 8-bit 数字 128：若它是 sRGB RGB 通道，采样后约为线性 0.216；
  // 若它是 Alpha，则只是 128/255≈0.502，不经过 sRGB 曲线。
  constexpr float encoded_mid = 128.0f / 255.0f;
  const float linear_mid = srgb_to_linear(encoded_mid);
  const float encoded_round_trip = linear_to_srgb(linear_mid);
  if (std::fabs(encoded_round_trip - encoded_mid) > 1.0e-6f) {
    std::fprintf(stderr, "sRGB reference curve round-trip failed\n");
    std::exit(EXIT_FAILURE);
  }
  std::printf(
      "sRGB reference: RGB8 128 -> linear %.6f; alpha8 128 -> %.6f; "
      "round-trip -> %.6f\n",
      linear_mid, encoded_mid, encoded_round_trip);
}

// 这是“引擎侧 CPU 顶点格式”。内存中每个元素按顺序排列：
//   byte +0  : position.x/y/z，3 个 float，占 12 字节
//   byte +12 : color.r/g/b/a，4 个 float，占 16 字节
//   byte +28 : uv.u/v，2 个 float，占 8 字节
//   stride   : 36 字节
//
// D3D12 不会从 C++ 类型名推断这个布局；Input Layout 会用“语义名 + 格式 +
// byte offset”把这 28 个字节映射成 HLSL 的 POSITION 和 COLOR0。
struct Vertex {
  float position[3];
  float color[4];
  float uv[2];
};

static_assert(sizeof(Vertex) == 36, "Vertex layout must be 36 bytes");
static_assert(offsetof(Vertex, position) == 0, "position must start at byte 0");
static_assert(offsetof(Vertex, color) == 12, "color must start at byte 12");
static_assert(offsetof(Vertex, uv) == 28, "uv must start at byte 28");

// D3D12 Constant Buffer View 要求 BufferLocation 和 SizeInBytes 都满足
// D3D12_CONSTANT_BUFFER_DATA_PLACEMENT_ALIGNMENT（256 字节）对齐。
// XMFLOAT4X4 本身只有 64 字节，所以这里显式补齐到一个 256-byte CBV 单元。
// 未来一个 Upload Resource 可以放多个 ObjectConstants，但每个对象的起始
// GPU 地址仍必须落在 256 字节边界；本节每个 Back Buffer 只放一个对象常量。
struct alignas(256) ObjectConstants {
  XMFLOAT4X4 view_projection;
  std::uint8_t padding[256 - sizeof(XMFLOAT4X4)]{};
};

static_assert(sizeof(XMFLOAT4X4) == 64, "XMFLOAT4X4 must contain 16 floats");
static_assert(sizeof(ObjectConstants) == 256,
              "Constant buffer element must be 256 bytes");

// 每实例数据走 StructuredBuffer，不走 CBV。元素 stride 只需 16 字节对齐，不必 256。
// world 是 4x4 矩阵；color 是线性乘数；instance_id 只用于 CPU 自检和 Shader 对照。
struct InstanceData {
  XMFLOAT4X4 world;
  float color[4];
  std::uint32_t instance_id;
  std::uint32_t padding[3];
};

static_assert(sizeof(InstanceData) == 96, "InstanceData stride must be 96 bytes");
static_assert(offsetof(InstanceData, color) == 64, "color must start at byte 64");
static_assert(offsetof(InstanceData, instance_id) == 80,
              "instance_id must start at byte 80");

// glTF 的 alphaMode 是字符串；这里用整数，方便放进 root constants。
// 三种模式决定的是“这个表面如何处理覆盖度”，不是纹理里有没有 Alpha 通道。
enum class AlphaMode : std::uint32_t {
  Opaque = 0,
  Mask = 1,
  Blend = 2,
};

// 与 HLSL cbuffer MaterialConstants : register(b1) 逐字段对应。
// 32 字节 = 8 个 32-bit 值，正好作为 Root Constants 上传，不必再开一份 CBV。
struct MaterialConstants {
  float base_color_factor[4];
  float metallic_factor;
  float roughness_factor;
  float alpha_cutoff;
  std::uint32_t alpha_mode;
};

static_assert(sizeof(MaterialConstants) == 32,
              "Material root constants must be 8 DWORDs");
constexpr UINT kMaterialRootConstantCount =
    static_cast<UINT>(sizeof(MaterialConstants) / sizeof(UINT));

// Material 是 CPU 侧策略对象：它引用纹理 SRV，但不拥有 Texture Resource。
// metallic/roughness 先作为可绑定字段存在；真正的 BRDF 要到 glTF/PBR 阶段。
struct Material {
  const char* name = "";
  MaterialConstants constants{};
};

// MeshDrawItem 是一次 DrawIndexedInstanced 的 CPU 描述。
// 同一份 VB/IB 可以被多个 Draw 复用；实例化只改 InstanceCount 和起始实例号。
struct MeshDrawItem {
  const char* name = "";
  UINT index_count = 0;
  UINT start_index_location = 0;
  INT base_vertex_location = 0;
  UINT instance_count = 1;
  UINT start_instance_location = 0;
  float sort_depth = 0.0f;
  const Material* material = nullptr;
};

struct RenderQueue {
  std::vector<MeshDrawItem> opaque_items;
  std::vector<MeshDrawItem> mask_items;
  std::vector<MeshDrawItem> blend_items;
};

// CPU 侧网格资产。它不是 D3D12 Resource：替换这份数据不会自动改 GPU 上的 VB/IB。
// 上传器把这里的字节复制到 Default Heap 之后，GPU 才看得到新网格。
struct CpuMesh {
  std::vector<Vertex> vertices;
  std::vector<std::uint16_t> indices;
  const char* name = "";
};

// 共用上传器：网格和纹理走同一条 Copy 路径，避免每次上传临时新建 allocator/list。
// staging 必须活到 GPU Copy 完成；ExecuteCommandLists 返回时 GPU 通常还没读完。
struct GpuUploader {
  ComPtr<ID3D12CommandAllocator> allocator;
  ComPtr<ID3D12GraphicsCommandList> command_list;
  std::vector<ComPtr<ID3D12Resource>> staging_buffers;
  bool is_recording = false;
};

// 每张交换链 Back Buffer 有自己的 Command Allocator。
// 只有该帧对应的 GPU 命令执行完，CPU 才能 Reset 这个 allocator。
struct FrameResources {
  ComPtr<ID3D12CommandAllocator> command_allocator;
  ComPtr<ID3D12Resource> back_buffer;
  D3D12_CPU_DESCRIPTOR_HANDLE rtv{};
  UINT64 fence_value = 0;

  // 每帧独立的 Upload Heap 常量资源和持久映射地址。
  // 只有确认该帧 Fence 完成后，CPU 才能改写它，避免覆盖 GPU 尚未读取的矩阵。
  ComPtr<ID3D12Resource> constant_buffer;
  UINT8* constant_buffer_mapped = nullptr;
  D3D12_GPU_DESCRIPTOR_HANDLE cbv_gpu{};

  // 每帧一份实例 StructuredBuffer。CPU 在 mapped Upload Heap 上改 World/颜色，
  // GPU 通过 Root SRV 的 GPU 虚拟地址读取。Fence 保护这块内存不被过早覆盖。
  ComPtr<ID3D12Resource> instance_buffer;
  UINT8* instance_buffer_mapped = nullptr;
  D3D12_GPU_VIRTUAL_ADDRESS instance_buffer_gpu = 0;
};

struct Renderer {
  // Device 是工厂，不是显存本身。Queue 拥有 GPU 时间线。SwapChain 拥有 Back Buffer。
  // Mesh/Texture 的 Default Heap Resource 由 Renderer 长期持有；每帧 CB/实例缓冲在 frames[]。
  // Material/RenderQueue/CpuMesh 是 CPU 策略数据，GPU 看不到这些容器。
  ComPtr<IDXGIFactory6> factory;
  ComPtr<ID3D12Device> device;
  ComPtr<ID3D12InfoQueue> info_queue;
  bool debug_layer_enabled = false;
  ComPtr<ID3D12CommandQueue> command_queue;
  ComPtr<IDXGISwapChain3> swap_chain;
  ComPtr<ID3D12DescriptorHeap> rtv_heap;
  // DSV heap 只保存 CPU 可见的深度描述符；它不是深度像素存储区，也不需要
  // 通过 SetDescriptorHeaps 绑定给 Shader。Output Merger 使用它保存的描述符。
  ComPtr<ID3D12DescriptorHeap> dsv_heap;
  ComPtr<ID3D12Resource> depth_buffer;
  D3D12_CPU_DESCRIPTOR_HANDLE dsv{};
  ComPtr<ID3D12GraphicsCommandList> command_list;
  ComPtr<ID3D12Fence> fence;
  std::array<FrameResources, kBackBufferCount> frames;

  // R.1/R.2 的图形管线没有资源输入，所以 Root Signature 为空。
  // 真实的顶点数据通过 Input Assembler 的 Vertex Buffer View 进入 VS，
  // 而不是通过 StructuredBuffer/SRV 进入；这是本节和粒子 demo 的关键区别。
  ComPtr<ID3D12RootSignature> root_signature;
  // D3D12 的 BlendState 和 DepthStencilState 都是 PSO 的固定组成部分，不能在
  // Draw 之间修改同一个 PSO 的字段。因此同一套 Shader/Root Signature 也要为
  // 不透明与透明材质各创建一个 PSO，并在命令列表中显式切换。
  ComPtr<ID3D12PipelineState> opaque_pipeline_state;
  ComPtr<ID3D12PipelineState> transparent_pipeline_state;
  // CBV 和纹理 SRV 必须放在同一个 shader-visible CBV_SRV_UAV heap：图形命令
  // 列表同时最多绑定一个这种类型的堆。槽位 0..1 是两个帧的 CBV，槽位 2 是
  // 本节的纹理 SRV。
  ComPtr<ID3D12DescriptorHeap> cbv_srv_uav_heap;
  D3D12_GPU_DESCRIPTOR_HANDLE texture_srv_gpu{};
  // Sampler 是另一种描述符类型，因此使用独立的 shader-visible SAMPLER heap。
  ComPtr<ID3D12DescriptorHeap> sampler_heap;
  D3D12_GPU_DESCRIPTOR_HANDLE sampler_gpu{};

  // 最终的 Default Heap 顶点资源。CPU 不能直接 Map 它；初始化时使用一个
  // 临时 Upload Heap 资源复制进去，GPU 绘制阶段只读取这个资源。
  ComPtr<ID3D12Resource> vertex_buffer;
  D3D12_VERTEX_BUFFER_VIEW vertex_buffer_view{};

  // Index Buffer 保存“顶点编号”，让多个三角形复用同一份 Vertex。
  // 本节的最大顶点编号只有 5，所以使用 uint16_t / R16_UINT；若网格中任何
  // 被引用的顶点编号大于 65535（无法由 uint16_t 表示），应改用 uint32_t /
  // R32_UINT，并同步修改 view.Format。
  ComPtr<ID3D12Resource> index_buffer;
  D3D12_INDEX_BUFFER_VIEW index_buffer_view{};

  // 纹理资源真正保存 RGBA 像素；texture_srv_gpu 只是同一资源的 SRV 描述符
  // 起点，二者必须同时保持存活到 GPU 不再使用它们。
  ComPtr<ID3D12Resource> texture;

  // 材质和队列是 CPU 数据。GPU 看不到这两个容器；每帧录制时 CPU 把它们
  // 翻译成 SetPipelineState / Root Constants / DrawIndexedInstanced。
  std::array<Material, 4> materials{};
  RenderQueue render_queue{};
  std::array<InstanceData, kTotalInstanceCount> cpu_instances{};
  CpuMesh cpu_mesh{};
  GpuUploader uploader{};
  UINT mesh_generation = 0;
  bool mask_material_enabled = true;

  D3D12_VIEWPORT viewport{};
  D3D12_RECT scissor{};

  HANDLE fence_event = nullptr;
  UINT64 next_fence_value = 1;
  UINT64 frame_reuse_cpu_waits = 0;
};

// CPU 侧暂存一张 Mip 的紧密 RGBA8 数据。它不是 D3D12 Resource：
//   width/height       = 这一 Mip 的逻辑像素尺寸
//   rgba8              = 每行紧密排列的 width * 4 个字节，没有 D3D12 RowPitch padding
// 真正写入 Upload Heap 时，必须把每行复制到 GetCopyableFootprints 返回的
// RowPitch 位置；不能把这个 vector 直接当作 GPU subresource 的布局。
struct CpuMipLevel {
  UINT width = 0;
  UINT height = 0;
  std::vector<std::uint8_t> rgba8;
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
  // 固定客户区尺寸，暂时不把 WM_SIZE、ResizeBuffers 和资源重建混入 R.1。
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
      0, kWindowClassName, L"R.7 D3D12 Mesh - Renderer Architecture",
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

ComPtr<IDXGIAdapter1> find_hardware_adapter(IDXGIFactory6* factory) {
  // R.1 只需要一个能创建 D3D12 device 的硬件适配器。
  // CUDA/D3D12 LUID 配对属于后面的 CUDA 互操作阶段；这里不提前引入该约束。
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

    ComPtr<ID3D12Device> probe_device;
    if (SUCCEEDED(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0,
                                    IID_PPV_ARGS(&probe_device)))) {
      std::printf("selected D3D12 adapter: %ls\n", description.Description);
      return adapter;
    }
  }

  std::fprintf(stderr, "No hardware adapter supports D3D12 feature level 11_0.\n");
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

D3D12_RESOURCE_DESC make_buffer_description(UINT64 byte_count) {
  D3D12_RESOURCE_DESC description{};
  description.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
  description.Width = byte_count;
  description.Height = 1;
  description.DepthOrArraySize = 1;
  description.MipLevels = 1;
  description.Format = DXGI_FORMAT_UNKNOWN;
  description.SampleDesc.Count = 1;
  // Buffer 使用 ROW_MAJOR 线性字节布局；纹理的 tiled layout 是另一种资源布局。
  description.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
  description.Flags = D3D12_RESOURCE_FLAG_NONE;
  return description;
}

Renderer create_renderer(HWND window) {
  Renderer renderer{};

  // Debug Layer 必须在 CreateDevice 之前打开。它是进程级开关：晚开则已经创建的
  // Device 不会被完整验证。Graphics Tools 未安装时接口会失败，教学程序继续跑，
  // 但不能把“没崩”说成 Debug Layer 干净。
  ComPtr<ID3D12Debug> debug_controller;
  const HRESULT debug_result =
      D3D12GetDebugInterface(IID_PPV_ARGS(&debug_controller));
  if (SUCCEEDED(debug_result)) {
    debug_controller->EnableDebugLayer();
    renderer.debug_layer_enabled = true;
    std::printf("D3D12 Debug Layer: enabled before CreateDevice\n");
  } else {
    std::printf(
        "D3D12 Debug Layer: unavailable (HRESULT 0x%08lx). "
        "Install Windows Graphics Tools to validate this lesson.\n",
        static_cast<unsigned long>(debug_result));
  }

  const UINT factory_flags =
      renderer.debug_layer_enabled ? DXGI_CREATE_FACTORY_DEBUG : 0;
  HR_CHECK(CreateDXGIFactory2(factory_flags, IID_PPV_ARGS(&renderer.factory)));
  ComPtr<IDXGIAdapter1> adapter = find_hardware_adapter(renderer.factory.Get());
  HR_CHECK(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0,
                             IID_PPV_ARGS(&renderer.device)));

  // InfoQueue 挂在已经创建的 Device 上。它保存 Debug Layer 产生的消息；
  // 本课不 SetBreakOnSeverity，避免无调试器的 --frames 验收被断点打断。
  // 退出时 drain 消息：有 CORRUPTION/ERROR 就失败。
  if (renderer.debug_layer_enabled &&
      SUCCEEDED(renderer.device.As(&renderer.info_queue))) {
    std::printf("D3D12 InfoQueue: attached; messages drained at shutdown\n");
  }

  D3D12_COMMAND_QUEUE_DESC queue_description{};
  queue_description.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
  queue_description.Priority = D3D12_COMMAND_QUEUE_PRIORITY_NORMAL;
  queue_description.Flags = D3D12_COMMAND_QUEUE_FLAG_NONE;
  HR_CHECK(renderer.device->CreateCommandQueue(
      &queue_description, IID_PPV_ARGS(&renderer.command_queue)));

  DXGI_SWAP_CHAIN_DESC1 swap_chain_description{};
  swap_chain_description.Width = kWindowWidth;
  swap_chain_description.Height = kWindowHeight;
  swap_chain_description.Format = kSwapChainFormat;
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
  rtv_heap_description.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_NONE;
  HR_CHECK(renderer.device->CreateDescriptorHeap(
      &rtv_heap_description, IID_PPV_ARGS(&renderer.rtv_heap)));

  const UINT rtv_increment = renderer.device->GetDescriptorHandleIncrementSize(
      D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
  D3D12_CPU_DESCRIPTOR_HANDLE rtv =
      renderer.rtv_heap->GetCPUDescriptorHandleForHeapStart();
  D3D12_RENDER_TARGET_VIEW_DESC back_buffer_rtv_description{};
  back_buffer_rtv_description.Format = kBackBufferRtvFormat;
  back_buffer_rtv_description.ViewDimension = D3D12_RTV_DIMENSION_TEXTURE2D;
  back_buffer_rtv_description.Texture2D.MipSlice = 0;
  back_buffer_rtv_description.Texture2D.PlaneSlice = 0;
  for (UINT frame_index = 0; frame_index < kBackBufferCount; ++frame_index) {
    FrameResources& frame = renderer.frames[frame_index];
    HR_CHECK(renderer.swap_chain->GetBuffer(
        frame_index, IID_PPV_ARGS(&frame.back_buffer)));
    // Resource 本体仍由交换链以 R8G8B8A8_UNORM 创建；显式 SRGB RTV 规定：
    // Pixel Shader 输出按线性 RGB 参与混合，最终写入 8-bit Back Buffer 时编码
    // 为 sRGB。Alpha 通道不会经过 sRGB 传递函数。
    renderer.device->CreateRenderTargetView(
        frame.back_buffer.Get(), &back_buffer_rtv_description, rtv);
    frame.rtv = rtv;
    rtv.ptr += rtv_increment;
    HR_CHECK(renderer.device->CreateCommandAllocator(
        D3D12_COMMAND_LIST_TYPE_DIRECT,
        IID_PPV_ARGS(&frame.command_allocator)));
  }

  // 深度资源是一张与窗口客户区同尺寸的二维纹理；它保存每个像素当前通过
  // 深度测试的 z 值。它和 Back Buffer 一样是真正的 ID3D12Resource，不能把
  // DSV 描述符误认为深度数据本身。
  D3D12_RESOURCE_DESC depth_description{};
  depth_description.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
  depth_description.Width = kWindowWidth;
  depth_description.Height = kWindowHeight;
  depth_description.DepthOrArraySize = 1;
  depth_description.MipLevels = 1;
  depth_description.Format = DXGI_FORMAT_D32_FLOAT;
  depth_description.SampleDesc.Count = 1;
  depth_description.SampleDesc.Quality = 0;
  // 纹理布局交给驱动选择；ROW_MAJOR 只适用于线性 Buffer 的教学描述。
  depth_description.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
  depth_description.Flags = D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL;

  const D3D12_HEAP_PROPERTIES default_heap =
      make_heap_properties(D3D12_HEAP_TYPE_DEFAULT);
  D3D12_CLEAR_VALUE depth_clear_value{};
  depth_clear_value.Format = DXGI_FORMAT_D32_FLOAT;
  // 这只是创建时提供给驱动的优化清除值；每个渲染 Pass 仍会显式记录清除。
  depth_clear_value.DepthStencil.Depth = 1.0f;
  depth_clear_value.DepthStencil.Stencil = 0;
  HR_CHECK(renderer.device->CreateCommittedResource(
      &default_heap, D3D12_HEAP_FLAG_NONE, &depth_description,
      D3D12_RESOURCE_STATE_DEPTH_WRITE, &depth_clear_value,
      IID_PPV_ARGS(&renderer.depth_buffer)));

  // DSV Heap 是 CPU 可见的描述符槽位数组；DSV 不通过 SetDescriptorHeaps
  // 绑定给 Shader，而是把它的 CPU 句柄传给 OMSetRenderTargets/Clear。
  D3D12_DESCRIPTOR_HEAP_DESC dsv_heap_description{};
  dsv_heap_description.Type = D3D12_DESCRIPTOR_HEAP_TYPE_DSV;
  dsv_heap_description.NumDescriptors = 1;
  dsv_heap_description.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_NONE;
  HR_CHECK(renderer.device->CreateDescriptorHeap(
      &dsv_heap_description, IID_PPV_ARGS(&renderer.dsv_heap)));

  renderer.dsv = renderer.dsv_heap->GetCPUDescriptorHandleForHeapStart();
  D3D12_DEPTH_STENCIL_VIEW_DESC dsv_description{};
  dsv_description.Format = DXGI_FORMAT_D32_FLOAT;
  dsv_description.ViewDimension = D3D12_DSV_DIMENSION_TEXTURE2D;
  dsv_description.Flags = D3D12_DSV_FLAG_NONE;
  dsv_description.Texture2D.MipSlice = 0;
  // 这一步把“如何访问 depth_buffer”的深度描述符写进 DSV Heap 的 slot 0。
  // renderer.dsv 只是定位该槽位的 CPU 句柄，不是深度数据地址。
  renderer.device->CreateDepthStencilView(
      renderer.depth_buffer.Get(), &dsv_description, renderer.dsv);

  HR_CHECK(renderer.device->CreateCommandList(
      0, D3D12_COMMAND_LIST_TYPE_DIRECT,
      renderer.frames[0].command_allocator.Get(), nullptr,
      IID_PPV_ARGS(&renderer.command_list)));
  // CreateCommandList 返回 open 状态；逐帧 Reset 前先关闭它。
  HR_CHECK(renderer.command_list->Close());

  HR_CHECK(renderer.device->CreateFence(
      0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&renderer.fence)));
  renderer.fence_event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (renderer.fence_event == nullptr) {
    std::fprintf(stderr, "CreateEventW failed: %lu\n", GetLastError());
    std::exit(EXIT_FAILURE);
  }

  renderer.viewport = {0.0f, 0.0f, static_cast<float>(kWindowWidth),
                       static_cast<float>(kWindowHeight), 0.0f, 1.0f};
  renderer.scissor = {0, 0, static_cast<LONG>(kWindowWidth),
                      static_cast<LONG>(kWindowHeight)};

  // 共用上传器与每帧 command_list 分开：上传走自己的 allocator/list，
  // 避免和正在录制的绘制命令抢同一份 recording 状态。CreateCommandList
  // 返回 open，先 Close，后续 begin_uploader 再 Reset。
  HR_CHECK(renderer.device->CreateCommandAllocator(
      D3D12_COMMAND_LIST_TYPE_DIRECT,
      IID_PPV_ARGS(&renderer.uploader.allocator)));
  HR_CHECK(renderer.device->CreateCommandList(
      0, D3D12_COMMAND_LIST_TYPE_DIRECT, renderer.uploader.allocator.Get(),
      nullptr, IID_PPV_ARGS(&renderer.uploader.command_list)));
  HR_CHECK(renderer.uploader.command_list->Close());
  renderer.uploader.is_recording = false;
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
    std::fprintf(stderr, "shader compile failed for %s (%s)\n", entry_point,
                 target);
    std::exit(EXIT_FAILURE);
  }
  return bytecode;
}

void create_root_signature_and_pipeline_states(Renderer& renderer) {
  // Root Signature 只描述 Shader 可使用的接口，不保存矩阵、材质、实例或纹理像素：
  //   root parameter 0 -> b0：当前帧 CBV，ViewProjection（只给 VS）
  //   root parameter 1 -> b1：材质 Root Constants（只给 PS）
  //   root parameter 2 -> t0：纹理 SRV table（只给 PS）
  //   root parameter 3 -> s0：采样器 table（只给 PS）
  //   root parameter 4 -> t1：实例 StructuredBuffer 的 Root SRV（只给 VS）
  // Root SRV 把 GPU 虚拟地址直接嵌进命令列表，不占用 descriptor heap 槽。
  D3D12_DESCRIPTOR_RANGE descriptor_ranges[3]{};
  descriptor_ranges[0].RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_CBV;
  descriptor_ranges[0].NumDescriptors = 1;
  descriptor_ranges[0].BaseShaderRegister = 0;  // HLSL register(b0)
  descriptor_ranges[0].RegisterSpace = 0;
  descriptor_ranges[0].OffsetInDescriptorsFromTableStart = 0;

  descriptor_ranges[1].RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
  descriptor_ranges[1].NumDescriptors = 1;
  descriptor_ranges[1].BaseShaderRegister = 0;  // HLSL register(t0)
  descriptor_ranges[1].RegisterSpace = 0;
  descriptor_ranges[1].OffsetInDescriptorsFromTableStart = 0;

  descriptor_ranges[2].RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER;
  descriptor_ranges[2].NumDescriptors = 1;
  descriptor_ranges[2].BaseShaderRegister = 0;  // HLSL register(s0)
  descriptor_ranges[2].RegisterSpace = 0;
  descriptor_ranges[2].OffsetInDescriptorsFromTableStart = 0;

  D3D12_ROOT_PARAMETER root_parameters[5]{};
  root_parameters[0].ParameterType =
      D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
  root_parameters[0].DescriptorTable.NumDescriptorRanges = 1;
  root_parameters[0].DescriptorTable.pDescriptorRanges =
      &descriptor_ranges[0];
  root_parameters[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_VERTEX;

  root_parameters[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
  root_parameters[1].Constants.ShaderRegister = 1;  // HLSL register(b1)
  root_parameters[1].Constants.RegisterSpace = 0;
  root_parameters[1].Constants.Num32BitValues = kMaterialRootConstantCount;
  root_parameters[1].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;

  root_parameters[2].ParameterType =
      D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
  root_parameters[2].DescriptorTable.NumDescriptorRanges = 1;
  root_parameters[2].DescriptorTable.pDescriptorRanges =
      &descriptor_ranges[1];
  root_parameters[2].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;

  root_parameters[3].ParameterType =
      D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
  root_parameters[3].DescriptorTable.NumDescriptorRanges = 1;
  root_parameters[3].DescriptorTable.pDescriptorRanges =
      &descriptor_ranges[2];
  root_parameters[3].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;

  root_parameters[4].ParameterType = D3D12_ROOT_PARAMETER_TYPE_SRV;
  root_parameters[4].Descriptor.ShaderRegister = 1;  // HLSL register(t1)
  root_parameters[4].Descriptor.RegisterSpace = 0;
  root_parameters[4].ShaderVisibility = D3D12_SHADER_VISIBILITY_VERTEX;

  D3D12_ROOT_SIGNATURE_DESC root_description{};
  root_description.NumParameters = 5;
  root_description.pParameters = root_parameters;
  root_description.NumStaticSamplers = 0;
  root_description.pStaticSamplers = nullptr;
  root_description.Flags =
      D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;

  ComPtr<ID3DBlob> serialized_signature;
  ComPtr<ID3DBlob> diagnostics;
  HR_CHECK(D3D12SerializeRootSignature(
      &root_description, D3D_ROOT_SIGNATURE_VERSION_1,
      &serialized_signature, &diagnostics));
  HR_CHECK(renderer.device->CreateRootSignature(
      0, serialized_signature->GetBufferPointer(),
      serialized_signature->GetBufferSize(),
      IID_PPV_ARGS(&renderer.root_signature)));

  const std::wstring shader_path =
      executable_directory() + L"\\d3d12_mesh_input_layout.hlsl";
  ComPtr<ID3DBlob> vertex_shader =
      compile_shader(shader_path, "VSMain", "vs_5_1");
  ComPtr<ID3DBlob> pixel_shader =
      compile_shader(shader_path, "PSMain", "ps_5_1");

  // D3D12_INPUT_ELEMENT_DESC 的七个字段组成一条“顶点属性取数规则”：
  //   SemanticName/Index：和编译后 VS 输入的语义匹配，例如 COLOR + 0 = COLOR0；
  //   Format：按 DXGI_FORMAT 解码 buffer 中的字节，例如 R32G32B32_FLOAT=3 个 float；
  //   InputSlot：从哪个 IA 顶点流读取，必须和 IASetVertexBuffers 的 slot 对上；
  //   AlignedByteOffset：属性在一个 Vertex 内的字节偏移；
  //   InputSlotClass：PER_VERTEX_DATA 或 PER_INSTANCE_DATA；
  //   InstanceDataStepRate：实例流每多少个实例才推进一个元素，顶点流必须为 0。
  //
  // 这里使用一个 interleaved stream（position/color/uv 都在 slot 0）。也可以把
  // position 和 color 分到不同 slot，那时每个 slot 都要绑定自己的 VBV。
  static const D3D12_INPUT_ELEMENT_DESC input_elements[] = {
      {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0,
       static_cast<UINT>(offsetof(Vertex, position)),
       D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
      {"COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0,
       static_cast<UINT>(offsetof(Vertex, color)),
       D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
      {"TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT, 0,
       static_cast<UINT>(offsetof(Vertex, uv)),
       D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
  };

  D3D12_RASTERIZER_DESC rasterizer{};
  rasterizer.FillMode = D3D12_FILL_MODE_SOLID;
  // 本节仍关闭剔除，避免 MASK 镂空和透明排序被绕序细节干扰。
  // glTF 的 doubleSided 会映射成 CullMode=NONE；单面材质通常 CULL_BACK。
  // 完整光栅化状态所有权放到 R.7；这里只先留下 doubleSided 的影子。
  rasterizer.CullMode = D3D12_CULL_MODE_NONE;
  rasterizer.FrontCounterClockwise = FALSE;
  rasterizer.DepthBias = D3D12_DEFAULT_DEPTH_BIAS;
  rasterizer.DepthBiasClamp = D3D12_DEFAULT_DEPTH_BIAS_CLAMP;
  rasterizer.SlopeScaledDepthBias = D3D12_DEFAULT_SLOPE_SCALED_DEPTH_BIAS;
  rasterizer.DepthClipEnable = TRUE;

  // 先建立不透明 BlendState。BlendEnable=FALSE 表示 Pixel Shader 输出直接覆盖
  // RTV 的旧颜色；它不会自动把输出 Alpha 强制成 1，当前交换链不消费该 Alpha，
  // 完整材质阶段再让 OPAQUE shader 明确输出 1。此时 SrcBlend/DestBlend 等因子
  // 不参与运算，但仍给出合法默认值，避免依赖零初始化产生的无效枚举值。
  // IndependentBlendEnable=FALSE 表示所有 Render Target 沿用 RenderTarget[0] 的
  // 规则；当前 PSO 实际也只使用 RT0。
  D3D12_BLEND_DESC opaque_blend{};
  opaque_blend.AlphaToCoverageEnable = FALSE;
  opaque_blend.IndependentBlendEnable = FALSE;
  for (D3D12_RENDER_TARGET_BLEND_DESC& target_state :
       opaque_blend.RenderTarget) {
    target_state.BlendEnable = FALSE;
    target_state.LogicOpEnable = FALSE;
    target_state.SrcBlend = D3D12_BLEND_ONE;
    target_state.DestBlend = D3D12_BLEND_ZERO;
    target_state.BlendOp = D3D12_BLEND_OP_ADD;
    target_state.SrcBlendAlpha = D3D12_BLEND_ONE;
    target_state.DestBlendAlpha = D3D12_BLEND_ZERO;
    target_state.BlendOpAlpha = D3D12_BLEND_OP_ADD;
    target_state.LogicOp = D3D12_LOGIC_OP_NOOP;
    target_state.RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
  }

  // 透明 PSO 以不透明默认值为起点，只改需要变化的混合字段。这里使用
  // straight-alpha 的“源覆盖目标”公式：
  //   output.rgb = source.rgb * source.a
  //              + destination.rgb * (1 - source.a)
  // 纹理资源是 RGBA8_UNORM，Shader 采样后得到 0..1 的 float4，因此
  // SrcBlend=SRC_ALPHA 会使用纹理 Alpha（再乘顶点 Alpha）作为源颜色权重。
  D3D12_BLEND_DESC transparent_blend = opaque_blend;
  for (D3D12_RENDER_TARGET_BLEND_DESC& target_state :
       transparent_blend.RenderTarget) {
    target_state.BlendEnable = TRUE;
    target_state.SrcBlend = D3D12_BLEND_SRC_ALPHA;
    target_state.DestBlend = D3D12_BLEND_INV_SRC_ALPHA;
    target_state.SrcBlendAlpha = D3D12_BLEND_ONE;
    target_state.DestBlendAlpha = D3D12_BLEND_INV_SRC_ALPHA;
  }

  D3D12_DEPTH_STENCILOP_DESC disabled_stencil_face{};
  disabled_stencil_face.StencilFailOp = D3D12_STENCIL_OP_KEEP;
  disabled_stencil_face.StencilDepthFailOp = D3D12_STENCIL_OP_KEEP;
  disabled_stencil_face.StencilPassOp = D3D12_STENCIL_OP_KEEP;
  disabled_stencil_face.StencilFunc = D3D12_COMPARISON_FUNC_ALWAYS;

  // 不透明物体既做深度比较也写入深度：先画完后，深度资源就成为后续透明
  // Pass 的遮挡依据。透明物体仍做 LESS 比较，但不能写深度，否则先画到的
  // 透明层会像实心墙一样拒绝后面的透明层。
  D3D12_DEPTH_STENCIL_DESC opaque_depth_stencil{};
  opaque_depth_stencil.DepthEnable = TRUE;
  opaque_depth_stencil.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ALL;
  opaque_depth_stencil.DepthFunc = D3D12_COMPARISON_FUNC_LESS;
  opaque_depth_stencil.StencilEnable = FALSE;
  opaque_depth_stencil.StencilReadMask = D3D12_DEFAULT_STENCIL_READ_MASK;
  opaque_depth_stencil.StencilWriteMask = D3D12_DEFAULT_STENCIL_WRITE_MASK;
  opaque_depth_stencil.FrontFace = disabled_stencil_face;
  opaque_depth_stencil.BackFace = disabled_stencil_face;

  D3D12_DEPTH_STENCIL_DESC transparent_depth_stencil =
      opaque_depth_stencil;
  transparent_depth_stencil.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ZERO;

  D3D12_GRAPHICS_PIPELINE_STATE_DESC pipeline_description{};
  pipeline_description.pRootSignature = renderer.root_signature.Get();
  pipeline_description.VS = {vertex_shader->GetBufferPointer(),
                             vertex_shader->GetBufferSize()};
  pipeline_description.PS = {pixel_shader->GetBufferPointer(),
                             pixel_shader->GetBufferSize()};
  const UINT input_element_count = static_cast<UINT>(
      sizeof(input_elements) / sizeof(input_elements[0]));
  pipeline_description.InputLayout = {input_elements, input_element_count};
  pipeline_description.SampleMask = UINT_MAX;
  pipeline_description.RasterizerState = rasterizer;
  pipeline_description.PrimitiveTopologyType =
      D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
  pipeline_description.NumRenderTargets = 1;
  // 这里必须与 OMSetRenderTargets 实际绑定的 RTV view 格式一致；交换链 Resource
  // 本身仍是 UNORM，不要把 Resource 格式和 RTV 的访问解释混成一个对象。
  pipeline_description.RTVFormats[0] = kBackBufferRtvFormat;
  // PSO 声明它要配合的深度视图格式；它不是 DSV 句柄，也不会创建深度资源。
  pipeline_description.DSVFormat = DXGI_FORMAT_D32_FLOAT;
  pipeline_description.SampleDesc.Count = 1;
  // CreateGraphicsPipelineState 会根据整个 description 创建不可变 PSO。第一次
  // 使用不透明状态；随后只替换 BlendState/DepthStencilState 再创建透明 PSO。
  // 两个对象共享同一份 Shader 字节码与 Root Signature 接口，但固定状态不同。
  pipeline_description.BlendState = opaque_blend;
  pipeline_description.DepthStencilState = opaque_depth_stencil;
  HR_CHECK(renderer.device->CreateGraphicsPipelineState(
      &pipeline_description,
      IID_PPV_ARGS(&renderer.opaque_pipeline_state)));

  pipeline_description.BlendState = transparent_blend;
  pipeline_description.DepthStencilState = transparent_depth_stencil;
  HR_CHECK(renderer.device->CreateGraphicsPipelineState(
      &pipeline_description,
      IID_PPV_ARGS(&renderer.transparent_pipeline_state)));
}

void wait_for_fence_value(Renderer& renderer, UINT64 value,
                          const char* context) {
  // GetCompletedValue 只是读取 Fence 当前已经完成到哪个时间线值，不会让 CPU
  // 或 GPU 等待。如果目标 value 已完成，就走无阻塞快路径。
  if (renderer.fence->GetCompletedValue() >= value) {
    return;
  }

  // SetEventOnCompletion 也不阻塞：它只登记“Fence 达到 value 时设置这个
  // Win32 event”。真正让当前 CPU 线程睡眠的是随后 WaitForSingleObject。
  // Fence 解决 CPU/GPU 生命周期问题；它不是 ResourceBarrier，不能替代资源
  // 状态转换。反过来，ResourceBarrier 也不能证明 CPU 已可 Reset allocator。
  HR_CHECK(renderer.fence->SetEventOnCompletion(value, renderer.fence_event));
  const DWORD wait_result =
      WaitForSingleObject(renderer.fence_event, INFINITE);
  if (wait_result != WAIT_OBJECT_0) {
    std::fprintf(stderr, "%s wait failed: %lu\n", context, GetLastError());
    std::exit(EXIT_FAILURE);
  }
}

void flush_gpu(Renderer& renderer, const char* context) {
  // 退出、替换 Default Heap 网格、释放 staging 之前，都要让 Direct Queue
  // 上已经提交的工作完成。Signal 本身不阻塞；真正等待的是 wait_for_fence_value。
  const UINT64 flush_value = renderer.next_fence_value++;
  HR_CHECK(renderer.command_queue->Signal(renderer.fence.Get(), flush_value));
  wait_for_fence_value(renderer, flush_value, context);
}

ComPtr<ID3D12Resource> create_upload_buffer(Renderer& renderer,
                                            UINT64 byte_count,
                                            const void* source_bytes,
                                            const char* debug_name) {
  // Upload Heap 对 CPU 可写。Map 后 memcpy，再由 GPU Copy 读走。
  // 返回的 Resource 必须活到 Copy 完成；调用方把它放进 uploader.staging_buffers。
  (void)debug_name;
  const D3D12_HEAP_PROPERTIES upload_heap =
      make_heap_properties(D3D12_HEAP_TYPE_UPLOAD);
  const D3D12_RESOURCE_DESC description = make_buffer_description(byte_count);
  ComPtr<ID3D12Resource> upload_buffer;
  HR_CHECK(renderer.device->CreateCommittedResource(
      &upload_heap, D3D12_HEAP_FLAG_NONE, &description,
      D3D12_RESOURCE_STATE_GENERIC_READ, nullptr,
      IID_PPV_ARGS(&upload_buffer)));

  void* mapped = nullptr;
  const D3D12_RANGE no_cpu_reads{0, 0};
  HR_CHECK(upload_buffer->Map(0, &no_cpu_reads, &mapped));
  if (source_bytes != nullptr && byte_count > 0) {
    std::memcpy(mapped, source_bytes, static_cast<size_t>(byte_count));
  }
  const D3D12_RANGE written_range{0, static_cast<SIZE_T>(byte_count)};
  upload_buffer->Unmap(0, &written_range);
  return upload_buffer;
}

void begin_uploader(Renderer& renderer) {
  if (renderer.uploader.is_recording) {
    std::fprintf(stderr, "uploader is already recording\n");
    std::exit(EXIT_FAILURE);
  }
  // Reset 前必须证明上一批 Copy 已经完成。staging_buffers 非空表示还有 GPU
  // 可能在读的 Upload Heap；这里用 flush 简化教学，生产代码会给每批 Copy
  // 单独记 fence 值，不必每次卡住整条 Queue。
  if (!renderer.uploader.staging_buffers.empty()) {
    flush_gpu(renderer, "uploader reuse");
    renderer.uploader.staging_buffers.clear();
  }
  HR_CHECK(renderer.uploader.allocator->Reset());
  HR_CHECK(renderer.uploader.command_list->Reset(
      renderer.uploader.allocator.Get(), nullptr));
  renderer.uploader.is_recording = true;
}

void submit_uploader(Renderer& renderer, const char* context) {
  if (!renderer.uploader.is_recording) {
    std::fprintf(stderr, "%s: uploader is not recording\n", context);
    std::exit(EXIT_FAILURE);
  }
  HR_CHECK(renderer.uploader.command_list->Close());
  renderer.uploader.is_recording = false;
  ID3D12CommandList* lists[] = {renderer.uploader.command_list.Get()};
  renderer.command_queue->ExecuteCommandLists(1, lists);
  // Execute 返回时 GPU 通常还没读完 staging。必须等 Fence，才能释放 Upload Heap。
  flush_gpu(renderer, context);
  renderer.uploader.staging_buffers.clear();
}

void validate_cpu_mesh(const CpuMesh& mesh) {
  // 这些检查发生在任何 D3D12 Copy/Draw 之前。GPU 不会替我们验证索引范围或
  // 顶点 stride；错误网格会在 IA 阶段读到未定义字节。
  if (mesh.vertices.empty() || mesh.indices.empty()) {
    std::fprintf(stderr, "CPU mesh %s is empty\n", mesh.name);
    std::exit(EXIT_FAILURE);
  }
  if (mesh.indices.size() % 3 != 0) {
    std::fprintf(stderr, "CPU mesh %s index count %zu is not a multiple of 3\n",
                 mesh.name, mesh.indices.size());
    std::exit(EXIT_FAILURE);
  }
  for (size_t index = 0; index < mesh.indices.size(); ++index) {
    const std::uint16_t vertex_index = mesh.indices[index];
    if (vertex_index >= mesh.vertices.size()) {
      std::fprintf(stderr,
                   "CPU mesh %s index[%zu]=%u exceeds vertex count %zu\n",
                   mesh.name, index, vertex_index, mesh.vertices.size());
      std::exit(EXIT_FAILURE);
    }
  }
  std::printf("CPU mesh check: %s vertices=%zu indices=%zu triangles=%zu\n",
              mesh.name, mesh.vertices.size(), mesh.indices.size(),
              mesh.indices.size() / 3);
}

void validate_cpu_instances(const std::array<InstanceData, kTotalInstanceCount>&
                                instances) {
  for (UINT index = 0; index < kTotalInstanceCount; ++index) {
    if (instances[index].instance_id != index) {
      std::fprintf(stderr, "instance_id mismatch at %u: stored %u\n", index,
                   instances[index].instance_id);
      std::exit(EXIT_FAILURE);
    }
    const XMFLOAT4X4& world = instances[index].world;
    const float w = world._44;
    if (std::fabs(w - 1.0f) > 1.0e-4f) {
      std::fprintf(stderr, "instance %u world._44=%f, expected 1\n", index, w);
      std::exit(EXIT_FAILURE);
    }
  }
}

CpuMesh make_shared_triangle_mesh() {
  CpuMesh mesh{};
  mesh.name = "shared-triangle";
  mesh.vertices = {
      {{-0.38f, -0.32f, 0.0f}, {1.0f, 1.0f, 1.0f, 1.0f}, {0.0f, 4.0f}},
      {{0.38f, -0.32f, 0.0f}, {1.0f, 1.0f, 1.0f, 1.0f}, {4.0f, 4.0f}},
      {{0.00f, 0.42f, 0.0f}, {1.0f, 1.0f, 1.0f, 1.0f}, {2.0f, 0.0f}},
  };
  mesh.indices = {0, 1, 2};
  return mesh;
}

CpuMesh make_replacement_quad_mesh() {
  // 替换网格仍是一份共享资产：四个顶点、两个三角形。实例 World 不变。
  // 这用来证明“换网格”必须先等旧 VB/IB 的 GPU 读者离开。
  CpuMesh mesh{};
  mesh.name = "replacement-quad";
  mesh.vertices = {
      {{-0.32f, -0.28f, 0.0f}, {1.0f, 1.0f, 1.0f, 1.0f}, {0.0f, 4.0f}},
      {{0.32f, -0.28f, 0.0f}, {1.0f, 1.0f, 1.0f, 1.0f}, {4.0f, 4.0f}},
      {{0.32f, 0.36f, 0.0f}, {1.0f, 1.0f, 1.0f, 1.0f}, {4.0f, 0.0f}},
      {{-0.32f, 0.36f, 0.0f}, {1.0f, 1.0f, 1.0f, 1.0f}, {0.0f, 0.0f}},
  };
  mesh.indices = {0, 1, 2, 0, 2, 3};
  return mesh;
}

void upload_cpu_mesh_to_gpu(Renderer& renderer, CpuMesh mesh) {
  validate_cpu_mesh(mesh);
  renderer.cpu_mesh = std::move(mesh);

  const UINT64 vertex_byte_count =
      static_cast<UINT64>(renderer.cpu_mesh.vertices.size() * sizeof(Vertex));
  const UINT64 index_byte_count = static_cast<UINT64>(
      renderer.cpu_mesh.indices.size() * sizeof(std::uint16_t));

  // 替换网格前必须证明 GPU 不再读取旧 VB/IB。ComPtr Reset 会立刻释放 Resource；
  // 若上一帧 Draw 仍在飞，这里就会破坏 Fence 保护的生命周期。
  if (renderer.vertex_buffer != nullptr || renderer.index_buffer != nullptr) {
    flush_gpu(renderer, "replace mesh");
    renderer.vertex_buffer.Reset();
    renderer.index_buffer.Reset();
  }

  const D3D12_RESOURCE_DESC vertex_buffer_description =
      make_buffer_description(vertex_byte_count);
  const D3D12_RESOURCE_DESC index_buffer_description =
      make_buffer_description(index_byte_count);
  const D3D12_HEAP_PROPERTIES default_heap =
      make_heap_properties(D3D12_HEAP_TYPE_DEFAULT);
  // Buffer 的 InitialState 会被忽略，实际永远从 COMMON 开始。Debug Layer 会警告
  // COPY_DEST。CopyBufferRegion 会把 COMMON promote 成 COPY_DEST，随后的 barrier
  // 再显式转到 IA 可读状态。
  HR_CHECK(renderer.device->CreateCommittedResource(
      &default_heap, D3D12_HEAP_FLAG_NONE, &vertex_buffer_description,
      D3D12_RESOURCE_STATE_COMMON, nullptr,
      IID_PPV_ARGS(&renderer.vertex_buffer)));
  HR_CHECK(renderer.device->CreateCommittedResource(
      &default_heap, D3D12_HEAP_FLAG_NONE, &index_buffer_description,
      D3D12_RESOURCE_STATE_COMMON, nullptr,
      IID_PPV_ARGS(&renderer.index_buffer)));

  begin_uploader(renderer);
  ComPtr<ID3D12Resource> vertex_upload = create_upload_buffer(
      renderer, vertex_byte_count, renderer.cpu_mesh.vertices.data(),
      "vertex staging");
  ComPtr<ID3D12Resource> index_upload = create_upload_buffer(
      renderer, index_byte_count, renderer.cpu_mesh.indices.data(),
      "index staging");
  renderer.uploader.staging_buffers.push_back(vertex_upload);
  renderer.uploader.staging_buffers.push_back(index_upload);
  renderer.uploader.command_list->CopyBufferRegion(
      renderer.vertex_buffer.Get(), 0, vertex_upload.Get(), 0,
      vertex_byte_count);
  renderer.uploader.command_list->CopyBufferRegion(
      renderer.index_buffer.Get(), 0, index_upload.Get(), 0, index_byte_count);

  D3D12_RESOURCE_BARRIER input_barriers[2]{};
  input_barriers[0].Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
  input_barriers[0].Transition.pResource = renderer.vertex_buffer.Get();
  input_barriers[0].Transition.Subresource =
      D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
  input_barriers[0].Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_DEST;
  input_barriers[0].Transition.StateAfter =
      D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER;
  input_barriers[1].Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
  input_barriers[1].Transition.pResource = renderer.index_buffer.Get();
  input_barriers[1].Transition.Subresource =
      D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
  input_barriers[1].Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_DEST;
  input_barriers[1].Transition.StateAfter = D3D12_RESOURCE_STATE_INDEX_BUFFER;
  renderer.uploader.command_list->ResourceBarrier(2, input_barriers);
  submit_uploader(renderer, "mesh upload");

  renderer.vertex_buffer_view.BufferLocation =
      renderer.vertex_buffer->GetGPUVirtualAddress();
  renderer.vertex_buffer_view.StrideInBytes = sizeof(Vertex);
  renderer.vertex_buffer_view.SizeInBytes =
      static_cast<UINT>(vertex_byte_count);
  renderer.index_buffer_view.BufferLocation =
      renderer.index_buffer->GetGPUVirtualAddress();
  renderer.index_buffer_view.SizeInBytes = static_cast<UINT>(index_byte_count);
  renderer.index_buffer_view.Format = DXGI_FORMAT_R16_UINT;
  ++renderer.mesh_generation;

  std::printf(
      "uploaded GPU mesh generation=%u name=%s vertices=%u bytes=%llu "
      "indices=%u bytes=%llu\n",
      renderer.mesh_generation, renderer.cpu_mesh.name,
      static_cast<unsigned>(renderer.cpu_mesh.vertices.size()),
      static_cast<unsigned long long>(vertex_byte_count),
      static_cast<unsigned>(renderer.cpu_mesh.indices.size()),
      static_cast<unsigned long long>(index_byte_count));
}

void create_and_upload_mesh(Renderer& renderer) {
  upload_cpu_mesh_to_gpu(renderer, make_shared_triangle_mesh());
  std::printf(
      "input layout: POSITION offset=%zu, COLOR offset=%zu, TEXCOORD offset=%zu\n",
      offsetof(Vertex, position), offsetof(Vertex, color), offsetof(Vertex, uv));
}

void bind_material_constants(ID3D12GraphicsCommandList* command_list,
                             const Material& material) {
  // Root Constants 把材质 8 个 DWORD 直接写进命令列表。它不是 CBV，也不走
  // descriptor heap；每次 Draw 前覆盖 b1，因为后续 Draw 会换成另一份材质。
  command_list->SetGraphicsRoot32BitConstants(
      1, kMaterialRootConstantCount, &material.constants, 0);
}

void record_queue_draws(ID3D12GraphicsCommandList* command_list,
                        ID3D12PipelineState* pipeline_state,
                        const std::vector<MeshDrawItem>& items,
                        const char* queue_name) {
  if (items.empty()) {
    return;
  }
  command_list->SetPipelineState(pipeline_state);
  for (const MeshDrawItem& item : items) {
    if (item.material == nullptr) {
      std::fprintf(stderr, "draw item %s in %s has no material\n", item.name,
                   queue_name);
      std::exit(EXIT_FAILURE);
    }
    bind_material_constants(command_list, *item.material);
    command_list->DrawIndexedInstanced(
        item.index_count, item.instance_count, item.start_index_location,
        item.base_vertex_location, item.start_instance_location);
  }
}

void create_materials_and_render_queue(Renderer& renderer) {
  // 四份材质共享同一张颜色纹理，但 Alpha Mode 和因子不同。
  // metallic/roughness 先作为可绑定字段存在，用来证明材质数据已经进入 Shader；
  // 它们还不是 glTF metallic-roughness BRDF。
  renderer.materials[0].name = "opaque-wall";
  renderer.materials[0].constants = {
      {1.0f, 1.0f, 1.0f, 1.0f}, 0.05f, 0.85f, 0.5f,
      static_cast<std::uint32_t>(AlphaMode::Opaque)};
  renderer.materials[1].name = "mask-foliage";
  renderer.materials[1].constants = {
      {0.55f, 1.0f, 0.45f, 1.0f}, 0.0f, 0.95f, 0.45f,
      static_cast<std::uint32_t>(AlphaMode::Mask)};
  renderer.materials[2].name = "blend-far-glass";
  renderer.materials[2].constants = {
      {0.55f, 0.82f, 1.0f, 0.42f}, 0.0f, 0.20f, 0.5f,
      static_cast<std::uint32_t>(AlphaMode::Blend)};
  renderer.materials[3].name = "blend-near-glass";
  renderer.materials[3].constants = {
      {1.0f, 0.62f, 0.28f, 0.55f}, 0.15f, 0.35f, 0.5f,
      static_cast<std::uint32_t>(AlphaMode::Blend)};

  const MeshDrawItem source_items[] = {
      // 三个不透明实例共享一次 Draw：同一份 IB、同一套材质，InstanceCount=3。
      {"opaque-walls",
       static_cast<UINT>(renderer.cpu_mesh.indices.size()), 0, 0,
       kOpaqueInstanceCount, 0, 0.90f, &renderer.materials[0]},
      {"mask-foliage",
       static_cast<UINT>(renderer.cpu_mesh.indices.size()), 0, 0, 1, 3, 0.20f,
       &renderer.materials[1]},
      {"blend-far-glass",
       static_cast<UINT>(renderer.cpu_mesh.indices.size()), 0, 0, 1, 4, 0.05f,
       &renderer.materials[2]},
      {"blend-near-glass",
       static_cast<UINT>(renderer.cpu_mesh.indices.size()), 0, 0, 1, 5, -0.35f,
       &renderer.materials[3]},
  };

  renderer.render_queue = {};
  for (const MeshDrawItem& item : source_items) {
    if (item.material == &renderer.materials[1] &&
        !renderer.mask_material_enabled) {
      // 关闭材质只改 CPU 队列。GPU Resource、Fence 时间线和 PSO 都不变。
      continue;
    }
    MeshDrawItem queued = item;
    queued.index_count = static_cast<UINT>(renderer.cpu_mesh.indices.size());
    switch (static_cast<AlphaMode>(item.material->constants.alpha_mode)) {
      case AlphaMode::Opaque:
        renderer.render_queue.opaque_items.push_back(queued);
        break;
      case AlphaMode::Mask:
        renderer.render_queue.mask_items.push_back(queued);
        break;
      case AlphaMode::Blend:
        renderer.render_queue.blend_items.push_back(queued);
        break;
    }
  }

  // 透明混合不是交换律。本课相机在 -Z 看向原点，局部 z 越大越远，因此按
  // sort_depth 从大到小画。真实引擎通常用相机空间距离或包围体深度。
  std::sort(renderer.render_queue.blend_items.begin(),
            renderer.render_queue.blend_items.end(),
            [](const MeshDrawItem& left, const MeshDrawItem& right) {
              return left.sort_depth > right.sort_depth;
            });

  std::printf(
      "materials: opaque=%zu mask=%zu blend=%zu mask_enabled=%s "
      "(blend sorted far-to-near)\n",
      renderer.render_queue.opaque_items.size(),
      renderer.render_queue.mask_items.size(),
      renderer.render_queue.blend_items.size(),
      renderer.mask_material_enabled ? "true" : "false");
  std::printf("instancing: shared mesh=%zu vertices/%zu indices, opaque Draw "
              "InstanceCount=%u, total instances=%u, InstanceData=%zu bytes\n",
              renderer.cpu_mesh.vertices.size(), renderer.cpu_mesh.indices.size(),
              kOpaqueInstanceCount, kTotalInstanceCount, sizeof(InstanceData));
}

std::uint8_t linear_to_unorm8(float value) {
  // Mip 的 RGB 平均在线性空间完成，编码回 8-bit sRGB 前先夹紧到 SDR
  // 可表示的 [0, 1]。本示例没有 HDR 纹理，因此超出范围的值只能饱和。
  const float clamped = value < 0.0f ? 0.0f : (value > 1.0f ? 1.0f : value);
  return static_cast<std::uint8_t>(clamped * 255.0f + 0.5f);
}

std::vector<CpuMipLevel> build_color_texture_mip_chain(UINT width, UINT height,
                                                        UINT tile_size) {
  // 先生成 Mip 0。像素中的 RGB 是 sRGB 编码字节，Alpha 是普通线性 UNORM；
  // 这个区别决定了后续 2x2 过滤必须对 RGB 和 Alpha 走不同的数值路径。
  std::vector<CpuMipLevel> mip_chain;
  CpuMipLevel base_level{};
  base_level.width = width;
  base_level.height = height;
  base_level.rgba8.resize(static_cast<size_t>(width) * height * 4);
  for (UINT y = 0; y < height; ++y) {
    for (UINT x = 0; x < width; ++x) {
      const bool dark = ((x / tile_size) + (y / tile_size)) % 2 == 0;
      const size_t pixel_offset =
          (static_cast<size_t>(y) * width + x) * 4;
      // RGB 保存为 sRGB 编码值；SRGB SRV 采样时才会解码到线性 float。
      base_level.rgba8[pixel_offset + 0] = dark ? 35 : 220;
      base_level.rgba8[pixel_offset + 1] = 80;
      base_level.rgba8[pixel_offset + 2] = dark ? 150 : 245;
      // 左半边接近透明、右半边不透明，让 MASK 出现可见镂空，也让 BLEND
      // 有足够的覆盖度变化。Alpha 不是颜色，不能套 sRGB 曲线。
      const float horizontal_alpha =
          static_cast<float>(x) / static_cast<float>(width - 1);
      const float coverage =
          horizontal_alpha < 0.45f
              ? 0.05f
              : (horizontal_alpha > 0.55f ? 1.0f : 0.55f);
      base_level.rgba8[pixel_offset + 3] =
          static_cast<std::uint8_t>(coverage * 255.0f + 0.5f);
    }
  }
  mip_chain.push_back(std::move(base_level));

  // 逐级生成更小的 Mip。对每个输出像素取源级别的 2x2 邻域；边界使用
  // min 把最后一个源像素复制到不足 2x2 的位置，所以非 2 的幂尺寸也不会越界。
  // 本示例尺寸是 256 的幂，但把边界写出来能明确 Mip 生成器的通用契约。
  while (mip_chain.back().width > 1 || mip_chain.back().height > 1) {
    const CpuMipLevel& source = mip_chain.back();
    CpuMipLevel destination{};
    destination.width = source.width > 1 ? (source.width + 1) / 2 : 1;
    destination.height = source.height > 1 ? (source.height + 1) / 2 : 1;
    destination.rgba8.resize(
        static_cast<size_t>(destination.width) * destination.height * 4);

    for (UINT y = 0; y < destination.height; ++y) {
      for (UINT x = 0; x < destination.width; ++x) {
        const UINT source_x0 = (2 * x < source.width) ? 2 * x
                                                        : source.width - 1;
        const UINT source_y0 = (2 * y < source.height) ? 2 * y
                                                        : source.height - 1;
        const UINT source_x1 = source_x0 + 1 < source.width ? source_x0 + 1
                                                              : source_x0;
        const UINT source_y1 = source_y0 + 1 < source.height ? source_y0 + 1
                                                              : source_y0;

        const UINT sample_x[2] = {source_x0, source_x1};
        const UINT sample_y[2] = {source_y0, source_y1};
        float linear_rgb[3] = {0.0f, 0.0f, 0.0f};
        float weighted_rgb[3] = {0.0f, 0.0f, 0.0f};
        float linear_alpha = 0.0f;
        for (UINT row = 0; row < 2; ++row) {
          for (UINT column = 0; column < 2; ++column) {
            const size_t source_offset =
                (static_cast<size_t>(sample_y[row]) * source.width +
                 sample_x[column]) *
                4;
            const float sample_alpha =
                source.rgba8[source_offset + 3] / 255.0f;
            const float sample_rgb[3] = {
                srgb_to_linear(source.rgba8[source_offset + 0] / 255.0f),
                srgb_to_linear(source.rgba8[source_offset + 1] / 255.0f),
                srgb_to_linear(source.rgba8[source_offset + 2] / 255.0f),
            };
            // 独立平均 RGB 会让完全透明像素里的垃圾颜色污染缩小后的边缘。
            // Alpha-weighted 用覆盖度给 RGB 加权：MASK/BLEND 的镂空边更干净。
            // 这仍是 straight-alpha 存储，不是把纹理改成预乘格式。
            linear_rgb[0] += sample_rgb[0];
            linear_rgb[1] += sample_rgb[1];
            linear_rgb[2] += sample_rgb[2];
            weighted_rgb[0] += sample_rgb[0] * sample_alpha;
            weighted_rgb[1] += sample_rgb[1] * sample_alpha;
            weighted_rgb[2] += sample_rgb[2] * sample_alpha;
            linear_alpha += sample_alpha;
          }
        }

        const size_t destination_offset =
            (static_cast<size_t>(y) * destination.width + x) * 4;
        const float average_alpha = linear_alpha * 0.25f;
        for (UINT channel = 0; channel < 3; ++channel) {
          const float filtered_rgb =
              average_alpha > 1.0e-6f ? weighted_rgb[channel] / linear_alpha
                                      : linear_rgb[channel] * 0.25f;
          destination.rgba8[destination_offset + channel] =
              linear_to_unorm8(linear_to_srgb(filtered_rgb));
        }
        destination.rgba8[destination_offset + 3] =
            linear_to_unorm8(average_alpha);
      }
    }
    mip_chain.push_back(std::move(destination));
  }

  return mip_chain;
}

void create_per_frame_constant_buffers(Renderer& renderer) {
  // CBV 和纹理 SRV 将共用一个 shader-visible CBV/SRV/UAV 描述符堆：图形命令
  // 列表同时只能绑定一个这种类型的堆。槽位 0..kBackBufferCount-1 给每帧 CBV，
  // 最后一个槽位留给纹理 SRV。RTV/DSV 堆不属于这个堆，也不需要 shader-visible。
  D3D12_DESCRIPTOR_HEAP_DESC heap_description{};
  heap_description.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
  heap_description.NumDescriptors = kBackBufferCount + 1;
  heap_description.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
  HR_CHECK(renderer.device->CreateDescriptorHeap(
      &heap_description, IID_PPV_ARGS(&renderer.cbv_srv_uav_heap)));

  const UINT descriptor_increment =
      renderer.device->GetDescriptorHandleIncrementSize(
          D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
  D3D12_CPU_DESCRIPTOR_HANDLE cpu_descriptor =
      renderer.cbv_srv_uav_heap->GetCPUDescriptorHandleForHeapStart();
  D3D12_GPU_DESCRIPTOR_HANDLE gpu_descriptor =
      renderer.cbv_srv_uav_heap->GetGPUDescriptorHandleForHeapStart();

  const D3D12_RESOURCE_DESC constant_buffer_description =
      make_buffer_description(sizeof(ObjectConstants));
  const D3D12_HEAP_PROPERTIES upload_heap =
      make_heap_properties(D3D12_HEAP_TYPE_UPLOAD);

  for (FrameResources& frame : renderer.frames) {
    // 每帧一个资源，而不是所有帧共用同一块 256-byte 内存：
    //   CPU 更新 frame[i] 的矩阵
    //   GPU 仍可能读取 frame[j]（j != i）
    // 两者不会写读同一地址。使用当前 frame 前，allocator fence 已保证其上
    // 一次提交不再引用这块常量内存。
    HR_CHECK(renderer.device->CreateCommittedResource(
        &upload_heap, D3D12_HEAP_FLAG_NONE, &constant_buffer_description,
        D3D12_RESOURCE_STATE_GENERIC_READ, nullptr,
        IID_PPV_ARGS(&frame.constant_buffer)));

    const D3D12_RANGE no_cpu_reads{0, 0};
    void* mapped = nullptr;
    HR_CHECK(frame.constant_buffer->Map(0, &no_cpu_reads, &mapped));
    frame.constant_buffer_mapped = static_cast<UINT8*>(mapped);

    // CBV SizeInBytes 必须是 256 的倍数；这里正好是 sizeof(ObjectConstants)=256。
    // BufferLocation 必须从 Constant Buffer Resource 的 GPU 虚拟地址开始，
    // 不需要额外 byte offset，因为本节每个 resource 只放一个对象常量。
    D3D12_CONSTANT_BUFFER_VIEW_DESC cbv_description{};
    cbv_description.BufferLocation =
        frame.constant_buffer->GetGPUVirtualAddress();
    cbv_description.SizeInBytes = sizeof(ObjectConstants);
    renderer.device->CreateConstantBufferView(&cbv_description,
                                               cpu_descriptor);
    frame.cbv_gpu = gpu_descriptor;

    cpu_descriptor.ptr += descriptor_increment;
    gpu_descriptor.ptr += descriptor_increment;

    const D3D12_RESOURCE_DESC instance_buffer_description =
        make_buffer_description(sizeof(InstanceData) * kTotalInstanceCount);
    HR_CHECK(renderer.device->CreateCommittedResource(
        &upload_heap, D3D12_HEAP_FLAG_NONE, &instance_buffer_description,
        D3D12_RESOURCE_STATE_GENERIC_READ, nullptr,
        IID_PPV_ARGS(&frame.instance_buffer)));
    void* instance_mapped = nullptr;
    HR_CHECK(frame.instance_buffer->Map(0, &no_cpu_reads, &instance_mapped));
    frame.instance_buffer_mapped = static_cast<UINT8*>(instance_mapped);
    frame.instance_buffer_gpu = frame.instance_buffer->GetGPUVirtualAddress();
  }

  std::printf("created %u per-frame CBVs: element size=%zu bytes, alignment=256\n",
              kBackBufferCount, sizeof(ObjectConstants));
  std::printf("created %u per-frame instance StructuredBuffers: count=%u, "
              "stride=%zu, bytes=%zu\n",
              kBackBufferCount, kTotalInstanceCount, sizeof(InstanceData),
              sizeof(InstanceData) * kTotalInstanceCount);
}

void create_and_upload_texture(Renderer& renderer) {
  // 先在 CPU 生成完整的 RGBA8 Mip 链。这里故意不引入 PNG/JPEG 解码器：本节
  // 只学习 Texture2D 的多个 subresource、Upload footprint、SRV 的 Mip 范围和
  // Sampler 的 LOD 选择。每个棋盘格 32 像素，UV 会重复多次以实际触发缩小采样。
  constexpr UINT kTileSize = 32;
  constexpr UINT kBytesPerPixel = 4;
  const std::vector<CpuMipLevel> mip_chain =
      build_color_texture_mip_chain(kTextureWidth, kTextureHeight, kTileSize);
  if (mip_chain.size() != kTextureMipLevels) {
    std::fprintf(stderr, "unexpected CPU Mip chain length\n");
    std::exit(EXIT_FAILURE);
  }

  D3D12_RESOURCE_DESC texture_description{};
  texture_description.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
  texture_description.Width = kTextureWidth;
  texture_description.Height = kTextureHeight;
  texture_description.DepthOrArraySize = 1;
  // 一个 Texture2D subresource 对应一个 Mip（数组纹理还会再乘以 array slice）；
  // MipLevels=9 让 SRV 可以在 0..8 之间选择不同细节级别。
  texture_description.MipLevels = static_cast<UINT16>(kTextureMipLevels);
  // Resource 只提供 RGBA8 typeless 存储。颜色空间语义放在下面的 SRV 中；未来
  // 同一资源也能创建普通 UNORM view 做诊断，但同一次采样必须选定一个解释。
  texture_description.Format = kColorTextureResourceFormat;
  texture_description.SampleDesc.Count = 1;
  texture_description.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
  texture_description.Flags = D3D12_RESOURCE_FLAG_NONE;

  const D3D12_HEAP_PROPERTIES default_heap =
      make_heap_properties(D3D12_HEAP_TYPE_DEFAULT);
  HR_CHECK(renderer.device->CreateCommittedResource(
      &default_heap, D3D12_HEAP_FLAG_NONE, &texture_description,
      D3D12_RESOURCE_STATE_COPY_DEST, nullptr,
      IID_PPV_ARGS(&renderer.texture)));

  // 一次查询所有 Mip 的 footprint。D3D12 会独立返回每级的 Offset、RowPitch、
  // 行数和有效行字节数；Offset 通常按 512B、RowPitch 通常按 256B 对齐。
  // 这些 padding 是上传布局契约，不能把各级紧密拼接后自行猜偏移。
  std::vector<D3D12_PLACED_SUBRESOURCE_FOOTPRINT> footprints(
      kTextureMipLevels);
  std::vector<UINT> row_counts(kTextureMipLevels);
  std::vector<UINT64> row_sizes(kTextureMipLevels);
  UINT64 upload_byte_count = 0;
  renderer.device->GetCopyableFootprints(
      &texture_description, 0, kTextureMipLevels, 0, footprints.data(),
      row_counts.data(), row_sizes.data(), &upload_byte_count);
  for (UINT mip = 0; mip < kTextureMipLevels; ++mip) {
    const CpuMipLevel& level = mip_chain[mip];
    const UINT64 logical_row_bytes =
        static_cast<UINT64>(level.width) * kBytesPerPixel;
    if (row_sizes[mip] < logical_row_bytes ||
        row_counts[mip] != level.height ||
        footprints[mip].Footprint.RowPitch < logical_row_bytes) {
      std::fprintf(stderr, "unexpected texture footprint for Mip %u\n", mip);
      std::exit(EXIT_FAILURE);
    }
  }

  const D3D12_HEAP_PROPERTIES upload_heap =
      make_heap_properties(D3D12_HEAP_TYPE_UPLOAD);
  const D3D12_RESOURCE_DESC upload_description =
      make_buffer_description(upload_byte_count);
  ComPtr<ID3D12Resource> upload_buffer;
  HR_CHECK(renderer.device->CreateCommittedResource(
      &upload_heap, D3D12_HEAP_FLAG_NONE, &upload_description,
      D3D12_RESOURCE_STATE_GENERIC_READ, nullptr,
      IID_PPV_ARGS(&upload_buffer)));

  void* mapped_upload = nullptr;
  const D3D12_RANGE no_cpu_reads{0, 0};
  HR_CHECK(upload_buffer->Map(0, &no_cpu_reads, &mapped_upload));
  auto* upload_bytes = static_cast<std::uint8_t*>(mapped_upload);
  for (UINT mip = 0; mip < kTextureMipLevels; ++mip) {
    const CpuMipLevel& level = mip_chain[mip];
    const UINT logical_row_bytes = level.width * kBytesPerPixel;
    for (UINT y = 0; y < level.height; ++y) {
      // source_row 是 CPU vector 中紧密排列的一行；destination_row 落在 D3D12
      // 指定的 subresource Offset + RowPitch*y。只复制有效像素字节，行尾 padding
      // 不属于纹理内容，GPU copy 会按 footprint 的 RowPitch 跳过它。
      const auto* source_row = level.rgba8.data() +
                                static_cast<size_t>(y) * logical_row_bytes;
      auto* destination_row = upload_bytes +
                              static_cast<size_t>(footprints[mip].Offset) +
                              static_cast<size_t>(y) *
                                  footprints[mip].Footprint.RowPitch;
      std::memcpy(destination_row, source_row, logical_row_bytes);
    }
  }
  const D3D12_RANGE written_range{
      0, static_cast<SIZE_T>(upload_byte_count)};
  upload_buffer->Unmap(0, &written_range);

  begin_uploader(renderer);
  renderer.uploader.staging_buffers.push_back(upload_buffer);

  // 每个 Mip 都是独立 subresource，因此每级分别录制一次 CopyTextureRegion。
  // source 使用“带放置 footprint 的上传 Buffer”，destination 用 subresource index
  // 指向 Default Heap 纹理中的对应 Mip；Copy 只搬运字节，不执行 sRGB 转换。
  for (UINT mip = 0; mip < kTextureMipLevels; ++mip) {
    D3D12_TEXTURE_COPY_LOCATION destination{};
    destination.pResource = renderer.texture.Get();
    destination.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    destination.SubresourceIndex = mip;
    D3D12_TEXTURE_COPY_LOCATION source{};
    source.pResource = upload_buffer.Get();
    source.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    source.PlacedFootprint = footprints[mip];
    renderer.uploader.command_list->CopyTextureRegion(
        &destination, 0, 0, 0, &source, nullptr);
  }

  // 所有 Mip 复制完成后，一次性把整张纹理从 COPY_DEST 转到可被 Pixel Shader
  // 读取的状态。ALL_SUBRESOURCES 覆盖 Mip 0..8；这不是格式转换，也不能替代 SRV。
  D3D12_RESOURCE_BARRIER texture_barrier{};
  texture_barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
  texture_barrier.Transition.pResource = renderer.texture.Get();
  texture_barrier.Transition.Subresource =
      D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
  texture_barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_DEST;
  texture_barrier.Transition.StateAfter =
      D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE;
  renderer.uploader.command_list->ResourceBarrier(1, &texture_barrier);
  submit_uploader(renderer, "texture upload");

  // SRV 描述符写入 CBV/SRV/UAV heap 的最后一个槽位。MostDetailedMip=0 表示
  // 这张 view 从最高分辨率 Mip 开始，MipLevels=9 允许硬件在 0..8 之间按 LOD
  // 选择；SRV 只描述访问规则，不拥有纹理，也不替代资源状态。
  const UINT descriptor_increment =
      renderer.device->GetDescriptorHandleIncrementSize(
          D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
  D3D12_CPU_DESCRIPTOR_HANDLE srv_cpu =
      renderer.cbv_srv_uav_heap->GetCPUDescriptorHandleForHeapStart();
  D3D12_GPU_DESCRIPTOR_HANDLE srv_gpu =
      renderer.cbv_srv_uav_heap->GetGPUDescriptorHandleForHeapStart();
  srv_cpu.ptr += static_cast<SIZE_T>(kBackBufferCount) * descriptor_increment;
  srv_gpu.ptr += static_cast<UINT64>(kBackBufferCount) * descriptor_increment;

  D3D12_SHADER_RESOURCE_VIEW_DESC srv_description{};
  srv_description.Shader4ComponentMapping =
      D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
  // SRGB SRV 的转换只作用于 RGB：采样得到的 RGB 已在线性空间，可直接进行
  // 材质乘法、光照和 Alpha Blend；A 通道保持普通 UNORM 解释。法线、粗糙度、
  // 金属度等数据纹理不能使用这个 SRGB view，应创建普通 UNORM/SNORM/FLOAT view。
  srv_description.Format = kColorTextureSrvFormat;
  srv_description.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
  srv_description.Texture2D.MostDetailedMip = 0;
  srv_description.Texture2D.MipLevels = kTextureMipLevels;
  srv_description.Texture2D.PlaneSlice = 0;
  srv_description.Texture2D.ResourceMinLODClamp = 0.0f;
  renderer.device->CreateShaderResourceView(
      renderer.texture.Get(), &srv_description, srv_cpu);
  renderer.texture_srv_gpu = srv_gpu;

  // Sampler 描述符不能放进 CBV/SRV/UAV heap；它必须写入单独的 SAMPLER heap。
  D3D12_DESCRIPTOR_HEAP_DESC sampler_heap_description{};
  sampler_heap_description.Type = D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER;
  sampler_heap_description.NumDescriptors = 1;
  sampler_heap_description.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
  HR_CHECK(renderer.device->CreateDescriptorHeap(
      &sampler_heap_description, IID_PPV_ARGS(&renderer.sampler_heap)));

  D3D12_SAMPLER_DESC sampler_description{};
  sampler_description.Filter = D3D12_FILTER_MIN_MAG_MIP_LINEAR;
  sampler_description.AddressU = D3D12_TEXTURE_ADDRESS_MODE_WRAP;
  sampler_description.AddressV = D3D12_TEXTURE_ADDRESS_MODE_WRAP;
  sampler_description.AddressW = D3D12_TEXTURE_ADDRESS_MODE_WRAP;
  sampler_description.MipLODBias = 0.0f;
  sampler_description.MaxAnisotropy = 1;
  // 非 comparison 过滤会忽略 ComparisonFunc。写成 NEVER 避免 Debug Layer 警告
  // “ALWAYS + 非 comparison filter 可能不是本意”。
  sampler_description.ComparisonFunc = D3D12_COMPARISON_FUNC_NEVER;
  sampler_description.MinLOD = 0.0f;
  sampler_description.MaxLOD = static_cast<float>(kTextureMipLevels - 1);
  D3D12_CPU_DESCRIPTOR_HANDLE sampler_cpu =
      renderer.sampler_heap->GetCPUDescriptorHandleForHeapStart();
  renderer.device->CreateSampler(&sampler_description, sampler_cpu);
  renderer.sampler_gpu =
      renderer.sampler_heap->GetGPUDescriptorHandleForHeapStart();

  std::printf(
      "uploaded %ux%u RGBA8 color texture: mips=%u, "
      "typeless resource + sRGB SRV, base_row_pitch=%u, upload=%llu bytes\n",
      kTextureWidth, kTextureHeight, kTextureMipLevels,
      footprints[0].Footprint.RowPitch,
      static_cast<unsigned long long>(upload_byte_count));
}

void update_frame_constants(Renderer& renderer, FrameResources& frame,
                            std::uint64_t frame_number) {
  // DirectXMath 的矩阵乘法按“行向量 v * M”来使用；HLSL 端也明确声明
  // row_major 并调用 mul(position, matrix)，因此 CPU 和 shader 的数学方向一致。
  const float angle =
      static_cast<float>(frame_number % 360) * (XM_2PI / 360.0f);

  const XMVECTOR eye = XMVectorSet(0.0f, 0.15f, -3.4f, 1.0f);
  const XMVECTOR target = XMVectorSet(0.0f, 0.0f, 0.0f, 1.0f);
  const XMVECTOR up = XMVectorSet(0.0f, 1.0f, 0.0f, 0.0f);
  const XMMATRIX view = XMMatrixLookAtLH(eye, target, up);
  const XMMATRIX projection = XMMatrixPerspectiveFovLH(
      XM_PIDIV4, static_cast<float>(kWindowWidth) /
                     static_cast<float>(kWindowHeight),
      0.1f, 100.0f);
  const XMMATRIX view_projection = view * projection;

  ObjectConstants constants{};
  XMStoreFloat4x4(&constants.view_projection, view_projection);
  std::memcpy(frame.constant_buffer_mapped, &constants, sizeof(constants));

  // 每实例 World/颜色写进 StructuredBuffer。共享网格的 VB/IB 完全不动。
  const struct InstancePlacement {
    float x;
    float y;
    float z;
    float yaw;
    float color[4];
  } placements[kTotalInstanceCount] = {
      {-0.95f, 0.05f, 0.85f, 0.15f, {0.55f, 0.72f, 1.0f, 1.0f}},
      {0.00f, 0.00f, 0.95f, -0.08f, {0.80f, 0.86f, 1.0f, 1.0f}},
      {0.95f, 0.08f, 0.75f, 0.22f, {0.62f, 0.78f, 1.0f, 1.0f}},
      {0.00f, 0.18f, 0.18f, 0.35f, {0.45f, 1.0f, 0.52f, 1.0f}},
      {-0.55f, -0.05f, 0.02f, -0.18f, {0.55f, 0.88f, 1.0f, 1.0f}},
      {0.58f, -0.02f, -0.38f, 0.28f, {1.0f, 0.70f, 0.38f, 1.0f}},
  };

  for (UINT index = 0; index < kTotalInstanceCount; ++index) {
    const InstancePlacement& placement = placements[index];
    const XMMATRIX world =
        XMMatrixRotationY(placement.yaw + angle * (index % 2 == 0 ? 1.0f : -0.6f)) *
        XMMatrixTranslation(placement.x, placement.y, placement.z);
    InstanceData& instance = renderer.cpu_instances[index];
    XMStoreFloat4x4(&instance.world, world);
    instance.color[0] = placement.color[0];
    instance.color[1] = placement.color[1];
    instance.color[2] = placement.color[2];
    instance.color[3] = placement.color[3];
    instance.instance_id = index;
    instance.padding[0] = 0;
    instance.padding[1] = 0;
    instance.padding[2] = 0;
  }
  std::memcpy(frame.instance_buffer_mapped, renderer.cpu_instances.data(),
              sizeof(InstanceData) * kTotalInstanceCount);
  validate_cpu_instances(renderer.cpu_instances);

  if (frame_number == 0) {
    XMFLOAT4 clip_position{};
    const XMMATRIX first_world_view_projection =
        XMLoadFloat4x4(&renderer.cpu_instances[0].world) * view_projection;
    XMStoreFloat4(&clip_position,
                  XMVector4Transform(XMVectorSet(0, 0, 0, 1),
                                     first_world_view_projection));
    std::printf(
        "CPU instance0 origin clip=(%.4f, %.4f, %.4f, %.4f), "
        "NDC=(%.4f, %.4f, %.4f)\n",
        clip_position.x, clip_position.y, clip_position.z, clip_position.w,
        clip_position.x / clip_position.w, clip_position.y / clip_position.w,
        clip_position.z / clip_position.w);
  }
}

void wait_until_frame_is_reusable(Renderer& renderer, FrameResources& frame) {
  // frame.fence_value 是 CPU 为这套 FrameResources 保存的“最近一次提交票号”。
  // 它保护的不只是 Back Buffer，还保护 command_allocator 和当前帧 CB：GPU
  // 到达该值后，才能证明旧命令不再引用这些对象/内存。
  //
  // fence_value==0 表示这套帧资源从未提交过；GetCompletedValue>=目标值表示
  // GPU 已经过了票号。两种情况都无需让 CPU 休眠。
  if (frame.fence_value == 0 ||
      renderer.fence->GetCompletedValue() >= frame.fence_value) {
    return;
  }

  // 只有 CPU 追上 GPU、即将过早复用同一套帧资源时才真正等待。因此统计值
  // frame_reuse_cpu_waits 不是帧数，也不代表程序“每帧同步”。
  wait_for_fence_value(renderer, frame.fence_value, "frame resource");
  ++renderer.frame_reuse_cpu_waits;
}

void render_mesh_frame(Renderer& renderer, bool vsync,
                       std::uint64_t frame_number) {
  // 阶段 A：选择并取得本轮要复用的 FrameResources。
  // 不能用 frame_number % kBackBufferCount 猜交换链索引；Present 后下一张可写
  // Back Buffer 由 DXGI 决定，GetCurrentBackBufferIndex 才是权威结果。
  const UINT frame_index = renderer.swap_chain->GetCurrentBackBufferIndex();
  FrameResources& frame = renderer.frames[frame_index];

  // 先等 Fence，再写 CB / Reset allocator。顺序不能颠倒：若 GPU 仍在执行这套
  // frame 上一次的命令，它可能还在读取 CB，也仍依赖 allocator 内保存的命令。
  wait_until_frame_is_reusable(renderer, frame);
  update_frame_constants(renderer, frame, frame_number);

  // 阶段 B：重新开始 CPU 侧命令录制。
  // allocator->Reset 回收旧命令的后备存储；command_list->Reset 把已关闭的
  // encoder 重新变成 recording 状态。第二个参数允许提供初始 PSO，这里传
  // nullptr，目的是让两个材质 Pass 都在各自 Draw 前显式 SetPipelineState。
  // Reset 不会执行 GPU 工作，command_list 本身也不拥有 allocator 的内存。
  HR_CHECK(frame.command_allocator->Reset());
  HR_CHECK(renderer.command_list->Reset(frame.command_allocator.Get(),
                                        nullptr));

  // 阶段 C：以下调用大多返回 void，因为它们只向 command list 追加命令。
  // 这些操作不会在当前 CPU 调用点立刻清屏或绘制；GPU 要等到后面的
  // ExecuteCommandLists 后才按记录顺序执行。

  // Back Buffer 在交给 DXGI Present 前后必须处于 PRESENT；作为 RTV 写入前，
  // 显式转换为 RENDER_TARGET。Barrier 描述 GPU 使用方式，不代表 CPU 所有权。
  D3D12_RESOURCE_BARRIER to_render_target{};
  to_render_target.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
  to_render_target.Transition.pResource = frame.back_buffer.Get();
  to_render_target.Transition.Subresource =
      D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
  to_render_target.Transition.StateBefore = D3D12_RESOURCE_STATE_PRESENT;
  to_render_target.Transition.StateAfter = D3D12_RESOURCE_STATE_RENDER_TARGET;
  renderer.command_list->ResourceBarrier(1, &to_render_target);

  // OMSetRenderTargets 同时选择颜色目标和深度目标。RTV/DSV 都是 CPU
  // descriptor handle；它们不属于 SetDescriptorHeaps 绑定的 shader-visible
  // CBV/SRV/UAV heap。这个调用只绑定目标，不会自动清除或改变资源状态。
  renderer.command_list->OMSetRenderTargets(1, &frame.rtv, FALSE,
                                             &renderer.dsv);
  const float clear_color[4] = {0.025f, 0.035f, 0.075f, 1.0f};
  renderer.command_list->ClearRenderTargetView(frame.rtv, clear_color, 0,
                                                nullptr);
  // 常规深度配置是“近处值小 + LESS”。清成 1.0f 相当于把整个屏幕初始化
  // 为最远；每个 pass 都必须清除，否则上一帧的深度样本会影响本帧比较。
  // ClearDepthStencilView 只是记录 GPU 命令，实际执行发生在 Execute 后。
  renderer.command_list->ClearDepthStencilView(
      renderer.dsv, D3D12_CLEAR_FLAG_DEPTH, 1.0f, 0, 0, nullptr);
  renderer.command_list->RSSetViewports(1, &renderer.viewport);
  renderer.command_list->RSSetScissorRects(1, &renderer.scissor);

  // Reset 使用了空初始 PSO；Root Signature、PSO、descriptor heap、root table、
  // IA 拓扑和各 buffer view 都必须在对应 Draw 之前为本次录制明确绑定。
  renderer.command_list->SetGraphicsRootSignature(
      renderer.root_signature.Get());
  ID3D12DescriptorHeap* shader_visible_heaps[] = {
      renderer.cbv_srv_uav_heap.Get(), renderer.sampler_heap.Get()};
  // 当前命令列表必须同时绑定一个 CBV/SRV/UAV heap 和一个 SAMPLER heap。
  // RTV/DSV heap 不属于这个 API 的绑定范围；切换任一 shader-visible heap 后，
  // 依赖它的根描述符表都必须重新设置。
  renderer.command_list->SetDescriptorHeaps(2, shader_visible_heaps);
  // Root parameter 0 是一个 descriptor table，指向当前 frame 的 CBV。GPU 会
  // 在执行 VS 时通过 b0 读取该 CBV；CPU 不直接把矩阵“塞进”命令列表。
  renderer.command_list->SetGraphicsRootDescriptorTable(0,
                                                         frame.cbv_gpu);
  // Root parameter 2 的 t0 指向纹理 SRV，Root parameter 3 的 s0 指向采样器。
  // Root parameter 1 是材质 Root Constants，每个 Draw 前单独覆盖。
  renderer.command_list->SetGraphicsRootDescriptorTable(
      2, renderer.texture_srv_gpu);
  renderer.command_list->SetGraphicsRootDescriptorTable(
      3, renderer.sampler_gpu);
  // Root parameter 4 是 Root SRV：直接写入 StructuredBuffer 的 GPU 地址。
  // 它不走 descriptor heap，也不需要 CreateShaderResourceView。
  renderer.command_list->SetGraphicsRootShaderResourceView(
      4, frame.instance_buffer_gpu);
  renderer.command_list->IASetPrimitiveTopology(
      D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  // IA slot 0 绑定 Vertex Buffer；Index Buffer 不占 vertex input slot，它有独立
  // 的 IASetIndexBuffer 绑定点。随后 DrawIndexedInstanced 先从 IB 读索引值，
  // 再用 finalVertex = index + BaseVertexLocation 定位 VB 中的 Vertex。
  renderer.command_list->IASetVertexBuffers(0, 1,
                                            &renderer.vertex_buffer_view);
  renderer.command_list->IASetIndexBuffer(&renderer.index_buffer_view);
  // 渲染队列由 CPU 按 Alpha Mode 分类。OPAQUE/MASK 都走不透明 PSO：关 Blend、
  // 写深度。MASK 的镂空由 Shader clip 完成，不需要第三套 PSO。BLEND 再切到
  // 透明 PSO，并按 sort_depth 从远到近提交。
  record_queue_draws(renderer.command_list.Get(),
                     renderer.opaque_pipeline_state.Get(),
                     renderer.render_queue.opaque_items, "opaque");
  record_queue_draws(renderer.command_list.Get(),
                     renderer.opaque_pipeline_state.Get(),
                     renderer.render_queue.mask_items, "mask");
  record_queue_draws(renderer.command_list.Get(),
                     renderer.transparent_pipeline_state.Get(),
                     renderer.render_queue.blend_items, "blend");

  // 本帧对 Back Buffer 的最后一次 GPU 使用是 RTV 写入。Present 不会替我们
  // 补状态转换，因此在关闭命令列表前记录 RENDER_TARGET -> PRESENT。
  D3D12_RESOURCE_BARRIER to_present = to_render_target;
  to_present.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET;
  to_present.Transition.StateAfter = D3D12_RESOURCE_STATE_PRESENT;
  renderer.command_list->ResourceBarrier(1, &to_present);

  // Close 只结束录制并做可提交性检查；它既不提交，也不等待 GPU。
  HR_CHECK(renderer.command_list->Close());

  // 阶段 D：ExecuteCommandLists 才把已关闭列表提交到 Direct Queue。调用返回
  // 时 GPU 通常尚未完成。Present 把当前 Back Buffer 交还 DXGI；它既不是
  // Execute 的替代品，也不是 PRESENT ResourceBarrier 的替代品。
  ID3D12CommandList* command_lists[] = {renderer.command_list.Get()};
  renderer.command_queue->ExecuteCommandLists(1, command_lists);
  HR_CHECK(renderer.swap_chain->Present(vsync ? 1 : 0, 0));

  // Queue::Signal 把一个时间线标记排在此前 queue 工作之后。它不会阻塞 CPU；
  // GPU 走到该标记后，Fence completed value 才能达到 submitted_value。
  // 把票号写回“本 frame”后，下次 DXGI 再给出这个索引时便能精确判断：
  // allocator、CB 和相关 GPU 引用是否已允许复用。
  const UINT64 submitted_value = renderer.next_fence_value++;
  HR_CHECK(renderer.command_queue->Signal(renderer.fence.Get(),
                                          submitted_value));
  frame.fence_value = submitted_value;
}

void drain_debug_layer_messages(Renderer& renderer) {
  // InfoQueue 保存 Debug Layer 产生的消息。本课把 CORRUPTION/ERROR 当失败；
  // WARNING 打印但不失败，避免把 DXGI 信息级提示误判成架构错误。
  if (renderer.info_queue == nullptr) {
    std::printf("Debug Layer messages: InfoQueue not attached\n");
    return;
  }

  const UINT64 message_count = renderer.info_queue->GetNumStoredMessages();
  UINT error_count = 0;
  UINT warning_count = 0;
  for (UINT64 index = 0; index < message_count; ++index) {
    SIZE_T byte_count = 0;
    renderer.info_queue->GetMessage(index, nullptr, &byte_count);
    std::vector<std::uint8_t> storage(byte_count);
    auto* message =
        reinterpret_cast<D3D12_MESSAGE*>(storage.data());
    HR_CHECK(renderer.info_queue->GetMessage(index, message, &byte_count));
    const char* severity = "INFO";
    if (message->Severity == D3D12_MESSAGE_SEVERITY_CORRUPTION ||
        message->Severity == D3D12_MESSAGE_SEVERITY_ERROR) {
      severity = "ERROR";
      ++error_count;
    } else if (message->Severity == D3D12_MESSAGE_SEVERITY_WARNING) {
      severity = "WARNING";
      ++warning_count;
    }
    std::fprintf(stderr, "D3D12 %s: %.*s\n", severity,
                 static_cast<int>(message->DescriptionByteLength),
                 message->pDescription);
  }
  std::printf("Debug Layer messages: stored=%llu errors=%u warnings=%u\n",
              static_cast<unsigned long long>(message_count), error_count,
              warning_count);
  if (error_count > 0) {
    std::fprintf(stderr, "Debug Layer reported errors; R.7 architecture check failed\n");
    std::exit(EXIT_FAILURE);
  }
}

void disable_mask_material(Renderer& renderer) {
  // 关闭材质不是释放 PSO 或纹理。下一帧录制时 CPU 队列里不再有 MASK Draw，
  // GPU 上的 Default Heap 网格、Fence 时间线都保持合法。
  renderer.mask_material_enabled = false;
  create_materials_and_render_queue(renderer);
  std::printf("disabled MASK material; remaining draws do not touch Fence ownership\n");
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

bool parse_vsync(int argc, char** argv) {
  for (int index = 1; index < argc; ++index) {
    if (std::strcmp(argv[index], "--no-vsync") == 0) {
      return false;
    }
  }
  return true;
}

int main(int argc, char** argv) {
  SetProcessDPIAware();
  validate_srgb_reference_curve();
  HINSTANCE instance = GetModuleHandleW(nullptr);

  // 启动阶段按“平台 -> GPU 执行 -> 管线 -> 静态资源 -> 每帧资源”的顺序建立
  // 渲染器。这里的顺序不是风格问题：后面的对象会引用前面创建的 Device、Queue、
  // Descriptor Heap 或 Shader/PSO，不能脱离它们单独工作。
  HWND window = create_window(instance);
  Renderer renderer = create_renderer(window);
  create_root_signature_and_pipeline_states(renderer);
  create_and_upload_mesh(renderer);
  create_materials_and_render_queue(renderer);
  create_per_frame_constant_buffers(renderer);
  create_and_upload_texture(renderer);

  const int frame_limit = parse_frame_limit(argc, argv);
  const bool vsync = parse_vsync(argc, argv);
  bool running = true;
  std::uint64_t rendered_frames = 0;
  while (running) {
    // PeekMessageW(..., PM_REMOVE) 是非阻塞消息泵：先把当前排队的窗口消息
    // 全部取出并分发；队列暂时为空时立即返回，然后程序才录制下一帧。
    // ESC -> DestroyWindow -> WM_DESTROY -> PostQuitMessage -> WM_QUIT，最终让
    // running=false。这里不能在收到 WM_QUIT 后仍继续访问交换链窗口。
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

    // 运行阶段把同一批长期资源（PSO、VB、IB、Root Signature）重复使用；只有
    // 当前 frame 的 CB、allocator 和 Back Buffer 会按 Fence 轮换。render_mesh_frame
    // 返回时只是把本帧工作提交并登记票号，GPU 可能仍在执行。
    render_mesh_frame(renderer, vsync, rendered_frames);
    ++rendered_frames;
    if (rendered_frames == 1) {
      // 第一帧提交后 GPU 可能仍在读旧 VB/IB。关闭 MASK 只改 CPU 队列；
      // 替换网格会 flush 再释放旧 Resource。两者都不能把 Fence 时间线打乱。
      disable_mask_material(renderer);
      upload_cpu_mesh_to_gpu(renderer, make_replacement_quad_mesh());
      create_materials_and_render_queue(renderer);
    }
    if (frame_limit > 0 &&
        rendered_frames >= static_cast<std::uint64_t>(frame_limit)) {
      running = false;
    }
  }

  flush_gpu(renderer, "shutdown");
  drain_debug_layer_messages(renderer);
  std::printf("rendered frames: %llu\n",
              static_cast<unsigned long long>(rendered_frames));
  std::printf("frame-resource CPU waits: %llu\n",
              static_cast<unsigned long long>(renderer.frame_reuse_cpu_waits));
  std::printf("mesh generation=%u mask_enabled=%s\n",
              renderer.mesh_generation,
              renderer.mask_material_enabled ? "true" : "false");
  std::printf("D3D12 R.7 renderer architecture and CPU validation: PASS\n");

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
