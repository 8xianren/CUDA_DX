# R.5.3 D3D12 不透明与透明双 PSO

## 1. 本节目标

把场景绘制拆成正确的两个阶段：

```text
不透明 Pass
    -> 关闭 Alpha Blend
    -> 开启深度测试并写入深度

透明 Pass
    -> 开启 Alpha Blend
    -> 保留深度测试但关闭深度写入
```

本节学完后，应能解释为什么这两类材质需要不同的 PSO、为什么必须先画不透明
物体，以及 `SetPipelineState` 切换了什么、没有切换什么。

## 2. 直觉：两类演员使用两套入场规则

可以把深度资源看成一张“离相机最近的实心表面记录”：

- 不透明物体是实心墙。它画完后必须把自己的深度写进去，后面的物体才能知道
  哪些像素被墙挡住。
- 透明物体像有色玻璃。它需要读取这张深度记录，避免穿透实心墙显示；但它不能
  把自己也登记成实心墙，否则后画的透明层会被错误拒绝。

颜色规则也不同：不透明物体直接写入自己的颜色；透明物体需要读取 RTV 已有颜色，
再执行 Alpha Blend。因此这不是同一个 PSO 改一个临时开关，而是两套固定管线状态。

## 3. PSO 到底保存什么

`ID3D12PipelineState` 是由 `D3D12_GRAPHICS_PIPELINE_STATE_DESC` 创建的不可变图形
管线对象。当前示例的 PSO 包含：

```text
Root Signature
Vertex Shader / Pixel Shader 字节码
Input Layout
RasterizerState
BlendState
DepthStencilState
PrimitiveTopologyType
RTV/DSV 格式
MSAA SampleDesc
```

PSO 不保存下面这些运行时对象：

```text
实际 Vertex/Index Buffer
实际 Texture/Depth/Back Buffer Resource
当前 CBV/SRV/Sampler 描述符表起点
当前 RTV/DSV 句柄
某个 Draw 的索引数量
```

也就是说，PSO 规定“流水线如何解释和处理数据”，具体处理哪份资源仍由命令列表的
IA、根参数和 OM 绑定决定。

## 4. 两个 PSO 的精确差异

| 状态 | 不透明 PSO | 透明 PSO | 原因 |
|---|---|---|---|
| `BlendEnable` | `FALSE` | `TRUE` | 不透明颜色直接覆盖；透明颜色与 RTV 旧值混合 |
| `SrcBlend` | `ONE`，关闭混合时不参与 | `SRC_ALPHA` | straight-alpha 的源颜色权重 |
| `DestBlend` | `ZERO`，关闭混合时不参与 | `INV_SRC_ALPHA` | straight-alpha 的目标颜色权重 |
| `DepthEnable` | `TRUE` | `TRUE` | 两类几何体都要接受已有深度遮挡 |
| `DepthFunc` | `LESS` | `LESS` | 当前课程使用常规 Z，较小深度更近 |
| `DepthWriteMask` | `ALL` | `ZERO` | 只有不透明表面写入最近实心深度 |

两者其余字段相同，所以共享同一套 Shader、Root Signature、Input Layout、纹理和
采样器。共享这些内容不等于能共享一个 PSO，因为 BlendState 和 DepthStencilState
本身就是 PSO 的组成部分。

## 5. 创建 API 与参数

Windows SDK 中设备方法的核心签名是：

```cpp
HRESULT ID3D12Device::CreateGraphicsPipelineState(
    const D3D12_GRAPHICS_PIPELINE_STATE_DESC* pDesc,
    REFIID riid,
    void** ppPipelineState);
```

- `pDesc`：完整图形 PSO 描述。D3D12 会一起验证 Shader、Root Signature、
  Input Layout、RTV/DSV 格式、混合、深度和采样数是否兼容。
- `riid`：请求返回的 COM 接口 ID。`IID_PPV_ARGS` 会由目标指针类型生成它。
- `ppPipelineState`：接收创建出的 `ID3D12PipelineState*`。
- 返回 `HRESULT`：Shader/Root Signature 不匹配、格式组合非法或参数无效时会失败；
  当前代码使用 `HR_CHECK` 立即报告，而不是带着空 PSO 继续录制。

当前代码先填公共 `pipeline_description`，然后创建两次：

```cpp
pipeline_description.BlendState = opaque_blend;
pipeline_description.DepthStencilState = opaque_depth_stencil;
device->CreateGraphicsPipelineState(
    &pipeline_description,
    IID_PPV_ARGS(&renderer.opaque_pipeline_state));

pipeline_description.BlendState = transparent_blend;
pipeline_description.DepthStencilState = transparent_depth_stencil;
device->CreateGraphicsPipelineState(
    &pipeline_description,
    IID_PPV_ARGS(&renderer.transparent_pipeline_state));
```

第二次赋值不会修改第一个 PSO。`CreateGraphicsPipelineState` 已经依据当时的完整
description 创建了独立且不可变的对象；栈上的 description 只是创建输入。

## 6. 为什么不透明状态也填写 Blend 因子

当 `BlendEnable=FALSE` 时，颜色直接写入 RTV，`SrcBlend`、`DestBlend` 和
`BlendOp` 不参与混合。但 `D3D12_BLEND` 枚举的合法值并不是从 0 开始，不能认为
结构体清零后每个枚举字段都自然成为合法默认值。因此示例仍明确填写：

```cpp
target_state.SrcBlend = D3D12_BLEND_ONE;
target_state.DestBlend = D3D12_BLEND_ZERO;
target_state.BlendOp = D3D12_BLEND_OP_ADD;
```

这组值也直观对应 `source * 1 + destination * 0`，但本节不依赖硬件在关闭混合时
真的执行这次运算。

## 7. 命令录制与 PSO 切换

命令列表重置时使用：

```cpp
HRESULT ID3D12GraphicsCommandList::Reset(
    ID3D12CommandAllocator* pAllocator,
    ID3D12PipelineState* pInitialState);
```

- `pAllocator`：本轮录制使用的命令内存。Reset 前必须确认 GPU 已不再执行依赖
  该 allocator 的旧命令。
- `pInitialState`：可选的初始 PSO；允许传 `nullptr`。

当前示例传 `nullptr`，然后在每个 Pass 前显式记录：

```cpp
command_list->SetPipelineState(renderer.opaque_pipeline_state.Get());
command_list->DrawIndexedInstanced(3, 1, 0, 0, 0);

command_list->SetPipelineState(renderer.transparent_pipeline_state.Get());
command_list->DrawIndexedInstanced(3, 1, 3, 0, 0);
```

`SetPipelineState` 的核心签名是：

```cpp
void ID3D12GraphicsCommandList::SetPipelineState(
    ID3D12PipelineState* pPipelineState);
```

它只向命令列表记录“后续 Draw/Dispatch 使用哪个 PSO”，不会在 CPU 调用点立即
执行 GPU 工作。状态会保持到下一次 `SetPipelineState` 或命令列表结束。

切换 PSO不会自动更换或清除：

```text
Root Signature 和根参数
shader-visible Descriptor Heap
VBV / IBV / Primitive Topology
RTV / DSV
Viewport / Scissor
```

本例两个 PSO 的 Root Signature 相同，所以原有根描述符表仍能继续使用。如果切换
到接口不同的 Root Signature，就必须调用 `SetGraphicsRootSignature`，并重新设置
与新根签名匹配的根参数。

## 8. 单像素深度时间线

假设某像素清深度为 `1.0`，不透明三角形深度为 `0.8`，透明三角形深度为 `0.3`：

```text
清除后：Depth = 1.0

不透明 Pass：
    0.8 < 1.0，通过 LESS
    写颜色
    DepthWriteMask=ALL，因此 Depth = 0.8

透明 Pass：
    0.3 < 0.8，通过 LESS
    与 RTV 已有不透明颜色混合
    DepthWriteMask=ZERO，因此 Depth 仍为 0.8
```

如果另一个透明层位于 `0.9`，它会因为 `0.9 < 0.8` 为假而被不透明表面挡住。
如果另一个透明层位于 `0.6`，它可以通过不透明深度测试；多个可见透明层之间仍需
从远到近排序，因为 straight-alpha 颜色合成通常不满足交换律。

## 9. 为什么切 PSO 不需要 ResourceBarrier

`ResourceBarrier` 描述资源访问用途和依赖，例如 Back Buffer 从 `PRESENT` 转到
`RENDER_TARGET`。本节切换前后：

```text
Back Buffer：始终作为 RENDER_TARGET
Depth Resource：始终作为 DEPTH_WRITE 状态下的 DSV
Texture：始终作为 PIXEL_SHADER_RESOURCE
```

改变的是固定管线如何写颜色、是否更新深度值，并没有把资源改成复制源、UAV 或
Shader Resource 等另一种用途，所以两个 Draw 之间不需要状态转换屏障。

需要注意，`DepthWriteMask=ZERO` 是深度测试配置，不等于把深度资源转换成
`D3D12_RESOURCE_STATE_DEPTH_READ`。当前透明 Pass 仍绑定普通 DSV，整个阶段保持
`DEPTH_WRITE` 状态；以后若创建只读 DSV，并让 Shader 同时采样深度，才会单独处理
只读视图、资源状态和屏障。

## 10. CPU/GPU 所有权与生命周期

- CPU 在初始化阶段创建两个 PSO；它们不拥有网格或纹理像素。
- CPU 在每帧命令列表里记录 PSO 指针和 Draw 命令。
- Direct Queue 执行命令时，GPU 按当时记录的 PSO 顺序处理图元。
- `Renderer` 让两个 PSO 存活到最终 `flush_gpu` 完成，避免 GPU 尚未执行完就释放。
- Frame Fence 保护 Command Allocator、Back Buffer 和每帧常量缓冲的复用；切换
  PSO 本身不产生新的 CPU/GPU 同步点。

## 11. 本节场景与当前简化边界

当前网格数据包含：

```text
index 0..2：远处、不透明、偏蓝色三角形
index 3..5：近处、透明、偏暖色三角形
```

两者复用同一张带 Alpha 渐变的纹理。不透明 PSO 忽略 Alpha 对 RGB 混合的影响；
透明 PSO 使用纹理 Alpha 执行 straight-alpha 混合。

这里的“忽略”只针对混合公式。`BlendEnable=FALSE` 时，Pixel Shader 输出的四个
通道会直接写入允许写入的 RTV 通道，硬件不会把源 Alpha 自动改成 1。当前交换链
不使用该 Alpha，所以不影响显示；将来用于离屏合成时，`OPAQUE` 材质应在 Shader
中明确输出 `alpha=1`，或者按目标缓冲的真实用途设计 Alpha 通道和写掩码。

当前仍是教学边界：

- 材质类别由两条手写 Draw 决定，还没有 `Material` 数据结构和渲染队列。
- 只有一个透明对象，所以本节不重新验证多个透明对象的排序；R.5.2 已验证顺序依赖。
- 没有 alpha test/mask、双面材质、预乘 Alpha 或 OIT。
- 仍使用 `R8G8B8A8_UNORM`，尚未处理 sRGB 到线性空间的正确混合。

下一小节会讲 sRGB 与线性颜色：为什么纹理存储的 0.5 灰并不等于线性能量 0.5，
以及为什么 Alpha Blend 必须在线性空间进行。

## 12. 动手验证

在 PowerShell 中运行：

```powershell
cd C:\xf\Cuda\accelerated-computing-hub\learning\sandbox
.\build.ps1 d3d12\r01-r08-mesh\d3d12_mesh_input_layout.cu -NoRun
.\d3d12\r01-r08-mesh\d3d12_mesh_input_layout.exe --frames 180 --no-vsync
```

应看到先由不透明 PSO 写入的偏蓝三角形，以及叠在其上的偏暖透明三角形；程序
结束时应输出：

```text
D3D12 R.5.3 opaque/transparent dual PSO: PASS
```

RTX 5070 / `sm_120` 真机验证结果：

```text
编译：通过
2 帧运行：通过，frame-resource CPU waits: 0
180 帧运行：通过，frame-resource CPU waits: 51
D3D12 R.5.3 opaque/transparent dual PSO: PASS
```

`frame-resource CPU waits` 会受 VSync、提交速度和 GPU 调度影响，不是固定性能
常数。本次 `--no-vsync` 下 CPU 很快追上 GPU，需要等待某套双缓冲帧资源的旧
Fence 完成后才能 Reset 对应 Command Allocator 和改写常量缓冲；这与两个 PSO
之间的 GPU 状态切换不是同一种等待。

## 13. 小结与自测

核心链条：

```text
按材质分类 Draw
    -> 先绑定 opaque PSO
    -> 不透明物体写颜色 + 写深度
    -> 再绑定 transparent PSO
    -> 透明物体读不透明深度 + 混合颜色 + 不写深度
```

自测题：

1. 为什么不能在同一个已经创建的 PSO 上临时把 `BlendEnable` 从 `FALSE` 改成
   `TRUE`？
2. 为什么透明 Pass 要读取不透明 Pass 留下的深度，却通常不写入自己的深度？
3. `SetPipelineState` 以后，为什么本例不需要重新绑定纹理描述符表和 VBV？
4. `DepthWriteMask=ZERO` 是否等同于资源状态 `DEPTH_READ`？为什么？
