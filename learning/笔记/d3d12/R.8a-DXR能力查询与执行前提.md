# R.8a DXR 能力查询与执行前提

## 1. 本节结论

本节只做 DXR 能力查询，不构建 BLAS/TLAS，也不调用 `DispatchRays`。这样刻意把三个问题分开：

```text
设备是否支持 DXR？        R.8a：查询 RaytracingTier
几何是否已经可被追踪？    R.9/R.10：BLAS/TLAS
DXR shader 是否真正执行？  R.11：State Object/Shader Table/DispatchRays
```

程序：`learning/sandbox/d3d12/r08a-capability/dxr_capability_probe.cu`

运行：

```powershell
cd C:\xf\Cuda\accelerated-computing-hub\learning\sandbox
.\build.ps1 d3d12\r08a-capability\dxr_capability_probe.cu
```

本机 Windows + RTX 5070 + CUDA Toolkit 13.3/Windows SDK 10.0.26100.0 结果：

```text
adapter: NVIDIA GeForce RTX 5070
vendor_id: 0x10de  device_id: 0x2f04
dedicated_video_memory: 11943 MiB
shader_model: 0x0067
raytracing_tier: TIER_1_1 (11)
resource_binding_tier: 3
DXR result: SUPPORTED
```

`sm_120` 是 CUDA 编译目标；DXR 的 Tier 是 D3D12 图形 API 能力，二者是不同能力标识，不能混写。

## 2. 三层概念先分开

### 光线追踪算法

描述如何使用射线生成、几何求交、可见性和着色构造图像。CPU PT.2 的 Sphere/Triangle/AABB 就是软件光线追踪的一部分。

### 路径追踪

在光线追踪框架中使用随机路径和 Monte Carlo 估计渲染方程。PT.1–PT.5 讲的是辐射度量学、采样、Lambert、NEE；它们不是 DXR API。

### DXR

DirectX Raytracing，是 D3D12 的硬件光追接口：它规定加速结构资源、射线调度、shader table、hit group 和 `TraceRay` 的执行模型。DXR 不替你决定使用 Lambert、MIS、俄罗斯轮盘赌或 ReSTIR。

因此本项目的分层是：

```text
PT 数学/积分器       决定“这条路径的贡献是多少”
DXR                  决定“射线如何高效找到命中/执行命中 shader”
glTF                 决定“场景的网格、节点、材质从哪里来”
D3D12                提供设备、资源、队列、状态和呈现
```

## 3. 设备选择与 `D3D12CreateDevice`

程序先创建 DXGI Factory：

```cpp
HRESULT CreateDXGIFactory2(
    UINT Flags,
    REFIID riid,
    void** ppFactory);
```

参数：

```text
Flags       工厂行为标志；Debug 构建可带 DXGI_CREATE_FACTORY_DEBUG
riid        请求的接口 IID，例如 IID_PPV_ARGS(&factory)
ppFactory   返回 IDXGIFactory 接口指针
```

随后通过 `IDXGIFactory6::EnumAdapterByGpuPreference` 枚举高性能适配器，跳过软件适配器，并先测试能否创建设备：

```cpp
HRESULT D3D12CreateDevice(
    IUnknown* pAdapter,
    D3D_FEATURE_LEVEL MinimumFeatureLevel,
    REFIID riid,
    void** ppDevice);
```

参数：

```text
pAdapter              要使用的 DXGI Adapter
MinimumFeatureLevel   设备至少支持的 D3D Feature Level
riid                  请求的设备接口 IID
ppDevice              返回 ID3D12Device* 或 ID3D12Device5*
```

这里请求 `ID3D12Device5`。这不是说“接口编号越大 GPU 越快”，而是 D3D12 用接口版本暴露光追相关方法；底层设备仍由 adapter 决定。

代码中的设备探测：

```cpp
D3D12CreateDevice(
    adapter.Get(),
    D3D_FEATURE_LEVEL_12_0,
    IID_PPV_ARGS(&device5));
```

如果失败：

```text
不能继续假设支持 DXR
应输出 HRESULT 和上下文
可以选择回退到光栅化或明确退出
不能静默当作 DXR 可用
```

## 4. `CheckFeatureSupport` 与 `OPTIONS5`

设备能力不是从 adapter 名字猜的，而是通过：

```cpp
HRESULT ID3D12Device::CheckFeatureSupport(
    D3D12_FEATURE Feature,
    void* pFeatureSupportData,
    UINT FeatureSupportDataSize);
```

三个参数：

```text
Feature                 要查询的能力类别
pFeatureSupportData     调用方提供、驱动填充的结构体地址
FeatureSupportDataSize  结构体字节大小，必须和查询类别匹配
```

DXR Tier 查询使用：

```cpp
D3D12_FEATURE_DATA_D3D12_OPTIONS5 options5{};
device5->CheckFeatureSupport(
    D3D12_FEATURE_D3D12_OPTIONS5,
    &options5,
    sizeof(options5));
```

读取：

```cpp
options5.RaytracingTier
```

可能的值：

```text
D3D12_RAYTRACING_TIER_NOT_SUPPORTED
D3D12_RAYTRACING_TIER_1_0
D3D12_RAYTRACING_TIER_1_1
```

本机结果是 `TIER_1_1`。这意味着设备暴露 DXR 1.1 能力，但不能因此跳过 API 的资源状态、对齐、shader model 和 shader table 约束。

程序还查询：

```cpp
D3D12_FEATURE_DATA_D3D12_OPTIONS options{};
device5->CheckFeatureSupport(
    D3D12_FEATURE_D3D12_OPTIONS,
    &options,
    sizeof(options));
```

本机 `ResourceBindingTier=3`。它是资源绑定能力，不是 Raytracing Tier；两者必须分别记录。

## 5. Shader Model 不是 Raytracing Tier

程序请求并查询：

```cpp
D3D12_FEATURE_DATA_SHADER_MODEL shader_model{
    D3D_SHADER_MODEL_6_7
};

device5->CheckFeatureSupport(
    D3D12_FEATURE_SHADER_MODEL,
    &shader_model,
    sizeof(shader_model));
```

本机打印：

```text
shader_model: 0x0067
```

这表示最高 shader model 为 6.7。它和 DXR Tier 是正交信息：

```text
Shader Model     HLSL/DXIL shader 能使用的语言/模型能力
Raytracing Tier  D3D12 光追 API/硬件功能能力
```

后续编译 RayGen/Miss/ClosestHit 时还要使用 DXC 的 raytracing target，并在 State Object 创建时处理 shader library、hit group 和 root signature；不能看到 SM 6.7 就宣称完整光追管线可运行。

## 6. 为什么 R.8 不能直接做 `ClosestHit`

一个 `ClosestHit` shader 只有在射线命中三角形后才会被调用。最小依赖链是：

```text
顶点/索引 Buffer
    -> BLAS
BLAS + 实例变换
    -> TLAS
DXIL Library + Hit Group + Root Signatures
    -> State Object
Shader Identifier + Local Root Arguments
    -> Shader Table
RayGen 调用 TraceRay(TLAS,...)
    -> Miss 或 ClosestHit
```

如果没有 BLAS/TLAS：

```text
TraceRay 没有 Scene acceleration structure 参数
没有三角形可遍历
ClosestHit 没有触发条件
```

因此课程顺序改成：

```text
R.8a  查询 DXR 能力                 本节
R.9   构建三角形 BLAS
R.10  构建 TLAS 与实例
R.11  State Object + Shader Table + DispatchRays
R.12  DXR 阴影射线
R.13  主射线 + 最小 Path Tracer
```

## 7. Tier 1.0/1.1 在本课程中的处理

本课程先按 DXR 1.0 的核心对象建立最小管线，再在实际代码需要时对照 DXR 1.1 的能力。这样做不是忽略 1.1，而是避免把“高级入口/扩展能力”与 BLAS/TLAS/TraceRay 基础混成一节。

后续需要明确记录：

```text
代码使用了哪些 DXR 1.0 核心结构
代码使用了哪些 DXR 1.1 能力
没有支持的 Tier 时如何失败或回退
```

本机 RTX 5070 的 `TIER_1_1` 只说明硬件能力存在；本课程仍必须用 Debug Layer、HRESULT 和 GPU 输出验证每一步。

## 8. 本节验收与边界

已验证：

```text
硬件适配器枚举成功
D3D12 device5 创建成功
OPTIONS5 查询成功
RaytracingTier = TIER_1_1
Shader Model = 6.7
Resource Binding Tier = 3
```

尚未验证：

```text
BLAS/TLAS 构建
DXIL RayGen/Miss/ClosestHit
State Object
Shader Table
DispatchRays
实际命中颜色
```

所以本节的准确结论是：

> 本机 RTX 5070 + 当前 Windows SDK/驱动具备启动 DXR 主线的能力；DXR 实际执行从 R.9/R.10/R.11 才开始逐步验证。

下一节：**R.9 BLAS：三角形几何、Prebuild Info、Scratch Buffer 与 Result Buffer**。
