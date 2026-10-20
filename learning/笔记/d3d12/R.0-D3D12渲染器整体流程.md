# R.0 补课：D3D12 渲染器整体流程地图

## 1. 这节课的目标

在继续添加深度、纹理、实例化或 glTF 之前，先建立一张“整台渲染器如何工作”的总图。学完本节，应该能够回答：

1. 程序启动时，哪些对象只创建一次，哪些对象每帧轮换？
2. CPU 准备的顶点、索引、矩阵，怎样变成 GPU 真正执行的 Draw？
3. R.1、R.2、R.3 各自给这台机器增加了哪一个部件？R.4 以后会插在哪里？
4. 哪些对象拥有内存，哪些对象只是描述或引用？
5. 为什么一帧结束时不能马上释放资源？

真实代码：

- learning/sandbox/d3d12/r01-r08-mesh/d3d12_mesh_input_layout.cu
- learning/sandbox/d3d12/r01-r08-mesh/d3d12_mesh_input_layout.hlsl

本节只建立系统地图。帧内 API 的逐个参数解释见 R.3-完整逐步帧流程.md。

---

## 2. 先看最终要造的“机器”

### 2.1 游戏引擎视角

把渲染器想成一个小型游戏引擎的生产线：

```
窗口系统
    -> 选择 GPU 设备
    -> 建立 GPU 工作队列
    -> 准备交换链和 Back Buffer
    -> 编译 Shader，定义管线规则
    -> 把 CPU 网格/纹理上传成 GPU 资源
    -> 每帧准备相机和对象数据
    -> 录制“如何画这一帧”的命令包
    -> 提交给 GPU Queue
    -> GPU 执行 IA -> VS -> Rasterizer -> PS -> OM
    -> 把 Back Buffer Present 到窗口
```

长期能力和每帧工作必须分开：

- 长期对象：Device、Queue、SwapChain、PSO、Root Signature、静态 Mesh Resource。
- 每帧对象：当前 Back Buffer、当前帧 Constant Buffer、Command Allocator、Command List 中的命令。

### 2.2 启动、每帧、退出三段式总图

```
┌──────────────────────────────────────────────────────────────┐
│ 启动一次                                                     │
│ 进程/DPI -> Window -> DXGI Factory -> Adapter -> Device       │
│                              -> Direct Queue                  │
│                              -> SwapChain + Back Buffers      │
│                              -> RTV Heap + 每帧 Allocator      │
│                              -> Command List + Fence/Event    │
│                                                              │
│ Shader 文件 -> 编译 VS/PS -> Root Signature -> Graphics PSO  │
│ CPU Mesh   -> Upload Heap -> Copy -> Default Heap -> VBV/IBV │
│ 每帧常量   -> Upload Heap -> Map -> CBV descriptor            │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 每帧重复                                                     │
│ 消息泵 -> DXGI 当前 Back Buffer -> 等待该帧 Fence（必要时）    │
│ -> 更新当前 CB -> Reset allocator/list -> 录制命令            │
│ -> Close -> ExecuteCommandLists -> Present -> Queue::Signal  │
│ -> 保存 frame.fence_value                                    │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 退出一次                                                     │
│ 停止新帧 -> Queue::Signal(flush) -> 等待 Fence                │
│ -> 关闭 Event -> 释放 COM 资源 -> 销毁窗口                   │
└──────────────────────────────────────────────────────────────┘
```

以后每加一个模块，都先问：它属于启动、每帧还是退出？它生产什么资源？谁消费？需要哪条 Fence？

---

## 3. 模块地图：每个模块负责什么

| 模块 | 负责的问题 | 主要产物 | 当前状态 |
|---|---|---|---|
| Window/Platform | 程序有没有窗口、消息怎样进入程序 | HWND、窗口过程、消息泵 | 已有 |
| DXGI/Device | 使用哪块 GPU、能创建什么能力 | Factory、Adapter、Device | 已有 |
| Execution | GPU 工作放在哪里、怎样提交和等待 | Queue、Allocator、Command List、Fence | 已有 |
| Presentation | 最终像素放在哪、怎样显示 | SwapChain、Back Buffer、RTV | 已有 |
| Resource | CPU 数据怎样变成 GPU 可读资源 | Upload/Default Resource、Resource State | 已有 VB/IB/CB |
| Pipeline | GPU 如何解释并处理顶点 | Shader、Root Signature、PSO、Input Layout | 已有 VS/PS |
| Scene | 要画什么以及它在何处 | Mesh、Material、Camera、Node | 目前只有一个 Mesh 和一个 WVP |
| Depth | 近处遮挡远处、深度裁剪 | Depth Resource、DSV、Depth State | R.4 |
| Texture/Material | UV、采样、颜色和材质 | Texture、SRV、Sampler、Material CB | R.5 |
| Instancing | 一次 Draw 画多个对象 | Instance Buffer、SV_InstanceID | R.6 |
| Import | 磁盘文件如何进入 Scene | glTF/GLB Parser、内部 Mesh/Material | 阶段 C/D |
| CUDA Interop | CUDA 如何生产渲染器消费的数据 | External Memory、External Semaphore/Fence | R.7/阶段 E |

模块是责任边界，不是类名列表：

- Mesh 模块知道 Vertex/Index 的布局，但不决定窗口何时 Present。
- Frame 模块知道当前 Back Buffer 和 Fence，但不解析 glTF JSON。
- Parser 知道 accessor 如何解码，但不直接调用 DrawIndexedInstanced。
- CUDA 模块可以生产实例数据，但不能跳过 D3D12/CUDA 之间的同步。

### 3.1 三种对象：拥有、描述、编排

```
真正拥有内存/资源：
    ID3D12Resource、ID3D12DescriptorHeap、ID3D12CommandAllocator
    ID3D12PipelineState、ID3D12RootSignature、IDXGISwapChain3

描述资源的轻量对象：
    D3D12_VERTEX_BUFFER_VIEW
    D3D12_INDEX_BUFFER_VIEW
    D3D12_CONSTANT_BUFFER_VIEW_DESC
    D3D12_CPU_DESCRIPTOR_HANDLE
    D3D12_GPU_DESCRIPTOR_HANDLE

编排 GPU 工作的对象：
    ID3D12GraphicsCommandList
    ID3D12CommandQueue
    ID3D12Fence
```

必须避免这些错误理解：

```
VBV 不是 Vertex Buffer。
CBV 不是 Constant Buffer。
GPU descriptor handle 不是 GPU 指针。
Root Signature 不是资源内存。
Fence 不是 Resource Barrier。
```

View/descriptor 描述从哪里读、读多大、如何解释；Resource 才真正拥有字节。Root Signature 规定 shader 可以通过什么接口访问；Command List 规定这次绘制何时使用它们；Queue 决定 GPU 按什么顺序执行。

### 3.1.1 两个容易都被叫作“堆/分配器”的对象

当前代码里有两个完全不同的概念，不能把它们合称为“RTV allocator”：

| 对象 | 保存什么 | 创建/复用方式 | 是否调用 `Reset` |
|---|---|---|---|
| RTV Descriptor Heap | 一组 RTV 描述符槽位；描述如何把 Back Buffer 当作 Render Target | 启动时创建一次；每个 Back Buffer 写一个 RTV；保存 `frame.rtv` CPU handle | 否 |
| Command Allocator | Command List 的底层命令存储 | 每个 Back Buffer 一份；对应 Fence 完成后重新使用 | 是，调用 `ID3D12CommandAllocator::Reset` |

因此帧函数开头的真实顺序是：

```text
GetCurrentBackBufferIndex
    -> 等待该 frame 的 Fence（必要时）
    -> Reset Command Allocator
    -> Reset Graphics Command List
```

RTV Heap 在启动阶段就已经准备好，不会在每帧 Reset；Command Allocator 才是每帧回收的“录制空间”。它们只是因为都放进 `FrameResources` 而被同一个 frame index 选中。

### 3.1.2 VBV/IBV 是 View，但不是 Descriptor Heap 中的 Descriptor

D3D12 中“View”这个词有两种常见使用方式：

```text
IA 直接接收的 View：
    D3D12_VERTEX_BUFFER_VIEW
    D3D12_INDEX_BUFFER_VIEW
    通过 IASetVertexBuffers / IASetIndexBuffer 传给命令列表
    不占 CBV/SRV/UAV Descriptor Heap 槽位

Descriptor Heap 中的 View：
    CBV、SRV、UAV（以及 CPU RTV/DSV descriptor）
    通过 Create*View 写入 descriptor 槽位
    Shader-visible 的 CBV/SRV/UAV 才能再通过 Root Descriptor Table 查表
```

`CreateCommittedResource` 或 placed resource 创建时才决定 Resource 的内存大小；VBV/IBV 只描述 GPU 地址、字节范围、stride/format，不负责“分配多少显存”。当前 R.1/R.2 的 VB/IB 因而不需要建立 descriptor table。

### 3.2 每个模块都要交接四件事

```
输入：谁生产了什么数据？
布局：CPU 和 GPU 按什么字节/语义解释？
状态：GPU 使用前后 Resource State 是什么？
同步：谁必须等谁，哪一个 Fence 表示可以复用？
```

当前 Vertex Buffer 的交接：

```
输入：CPU std::vector<Vertex>
布局：position[3] + color[4]，stride=28
状态：COPY_DEST -> VERTEX_AND_CONSTANT_BUFFER
同步：Copy 命令提交后等待 upload fence，之后才使用 Default Buffer
消费：Input Assembler 根据 VBV + Input Layout 读取
```

---

## 4. 当前程序的启动生命周期

启动阶段通常只执行一次。main 的真实顺序是：

```
SetProcessDPIAware
    -> create_window
    -> create_renderer
    -> create_root_signature_and_pipeline
    -> create_and_upload_mesh
    -> create_per_frame_constant_buffers
    -> 进入 while (running)
```

### 4.1 进程和窗口

SetProcessDPIAware 让窗口尺寸和像素尺寸的关系不被系统 DPI 虚拟化干扰。create_window 注册窗口类、创建 HWND、调整客户区到 1280x720，然后显示窗口。

窗口只负责：

```
产生 WM_* 消息
提供 HWND 给 CreateSwapChainForHwnd
```

窗口不是 GPU 资源，也不负责录制 Draw。按 ESC 时，窗口过程调用 DestroyWindow，Windows 产生 WM_DESTROY，代码再 PostQuitMessage(0)，主循环收到 WM_QUIT 后停止新帧。

### 4.2 DXGI Factory、Adapter、Device

create_renderer 先创建 DXGI Factory，再枚举高性能 Adapter，最后调用 D3D12CreateDevice 创建 Device。

```
Factory：发现和创建 DXGI 对象
Adapter：一块物理/逻辑 GPU
Device：对该 Adapter 的 D3D12 编程接口入口
```

Device 不是“显存本身”，而是创建 Resource、Heap、View、Queue、PSO 等对象的工厂和能力边界。当前代码只排除软件适配器并检查 D3D_FEATURE_LEVEL_11_0；还没有做 CUDA LUID 配对、详细 Feature Options 和 Debug Layer。

### 4.3 Direct Command Queue

代码创建 D3D12_COMMAND_LIST_TYPE_DIRECT Queue。它能执行图形 Draw，也能执行普通 Copy 命令，所以当前初始化上传暂时复用这条 Queue。

```
CPU 调用创建 Queue
    不等于 GPU 已经执行任何 Draw

Queue 只是接受命令的有序通道
    GPU 什么时候执行，由硬件和驱动调度
```

后续如果拆出 Copy Queue 或 Compute Queue，就必须新增跨 Queue 依赖；当前只有一条 Queue，所以提交顺序天然给了一个简单的全局顺序。

### 4.4 SwapChain、Back Buffer、RTV

CreateSwapChainForHwnd 把 Direct Queue 和窗口连接起来，创建双缓冲 Flip Model SwapChain。随后对每个 buffer：

```
swap_chain->GetBuffer(index)
    -> frame.back_buffer
device->CreateRenderTargetView(back_buffer, ...)
    -> frame.rtv
device->CreateCommandAllocator(DIRECT)
    -> frame.command_allocator
```

对象关系：

```
Back Buffer Resource：真正的纹理/画布字节
RTV Descriptor：告诉 OM 如何把这张 Resource 当渲染目标
CPU RTV Handle：定位 descriptor 的 CPU 句柄
FrameResources：把对应 buffer、RTV、allocator、Fence 票号放在一起
```

RTV Heap 是 CPU-only descriptor heap。它不需要 shader-visible，也不通过 SetDescriptorHeaps 绑定；OMSetRenderTargets 直接接收 CPU RTV handle。

### 4.5 Command List、Fence、Event

代码创建一个 graphics command list，并先 Close 一次，因为 CreateCommandList 返回时它处于 open/recording 状态；主循环每帧再 Reset。

同时创建：

```
ID3D12Fence：GPU 时间线对象
CreateEventW：CPU 等待用的 Win32 Event
next_fence_value：本程序分配的单调票号
```

Fence 不会自动保护任何资源。只有把 Queue::Signal(fence, value) 排在提交之后，再把 value 保存到具体 FrameResources，CPU 才知道何时可以复用 allocator 和 CB。

### 4.6 Shader、Root Signature、PSO

create_root_signature_and_pipeline 完成三层工作：

```
HLSL 文件
    -> 编译 VSMain/PSMain 得到 shader bytecode

Root Signature
    -> 规定 shader 可访问的 b0 CBV descriptor table

Graphics PSO
    -> 固定 VS/PS、Input Layout、Rasterizer、Blend、RTV format、
       Primitive Topology Type 等状态
```

这些是“如何画”的规则，不是“这一帧画哪个对象”的数据。当前对象的 WVP 会在每帧写入 CB；Root Signature 和 PSO 不会因为矩阵变化而重建。

当前代码把 PSO 作为 GraphicsCommandList::Reset 的 pInitialState 传入，所以帧函数没有另写 SetPipelineState。如果 Reset 传 nullptr，就必须在录制阶段显式设置 PSO。

### 4.7 Mesh 上传

create_and_upload_mesh 的数据路径：

```
CPU std::vector<Vertex>/std::vector<uint16_t>
    -> Upload Heap Resource（CPU Map 并写入）
    -> CopyBufferRegion
    -> Default Heap Vertex/Index Resource
    -> ResourceBarrier(COPY_DEST -> VERTEX_AND_CONSTANT_BUFFER/INDEX_BUFFER)
    -> 等待 upload Fence
    -> 创建 VBV/IBV
```

Upload Heap 便于 CPU 写入，Default Heap 适合 GPU 长期读取。Copy 命令异步执行，所以临时 Upload Resource 必须活到 copy 完成；当前函数等待 upload Fence 后才让临时 ComPtr 释放。

静态 VB/IB 在所有帧之间共享；它们不应该因为每帧矩阵变化而重复复制。

### 4.8 每帧 Constant Buffer

create_per_frame_constant_buffers 对每个 Back Buffer 创建一份 Upload Heap CB，并创建一个 CBV：

```
frame 0 -> constant_buffer 0 -> cbv 0
frame 1 -> constant_buffer 1 -> cbv 1
```

每帧 CPU 只写当前 frame 的映射地址。GPU 还在读取 frame 0 时，CPU 可以准备 frame 1；复用 frame 0 前用其 Fence 确认 GPU 已完成。

CB 的 256-byte 对齐是 descriptor/地址布局约束；矩阵的数学大小仍是 64 字节。不要把两者混为一谈。

---

## 5. 当前程序的一帧：从数据到像素

### 5.1 一帧的高层步骤

```
1. 处理窗口消息，判断程序是否仍在运行
2. 询问 DXGI：当前可以使用哪一个 Back Buffer
3. 等待该 FrameResources 上一次提交完成（必要时）
4. CPU 更新当前帧 WVP Constant Buffer
5. 回收当前帧 Command Allocator，重新打开 Command List
6. 录制状态转换、清屏、输出目标、管线和 IA 绑定
7. 录制 DrawIndexedInstanced
8. 录制回 PRESENT 的状态转换
9. Close 命令列表
10. ExecuteCommandLists 提交到 Queue
11. Present 请求 DXGI 呈现
12. Queue::Signal 设置 GPU 时间线标记
13. 把票号存回当前 FrameResources
```

三个边界：

```
Reset / Close：CPU 侧准备命令
ExecuteCommandLists：把 closed list 放入 GPU Queue
Present：请求 DXGI 呈现，不提交 command list
```

### 5.2 CPU、Command List、GPU 的分工

```
CPU：
    决定画什么，写数据，构造命令包

Command List：
    保存“GPU 将按什么顺序做什么”的记录

GPU Queue：
    接收 closed list，并按提交顺序执行

GPU Pipeline：
    IA 取 VB/IB
    -> VS 应用 WVP
    -> 裁剪/透视除法/viewport
    -> Rasterizer 产生片段
    -> PS 输出颜色
    -> OM 写 RTV
```

DrawIndexedInstanced 这一行的含义是“把 Draw 操作写入命令包”，不是“CPU 此刻已经画完”。GPU 以后执行这个命令时才读取 IB、VB、CB 并产生像素。

### 5.3 两个独立的同步问题

```
GPU 资源状态顺序：
    PRESENT -> RENDER_TARGET -> 写 RTV -> PRESENT
    使用 ResourceBarrier

CPU/GPU 生命周期：
    GPU 仍使用 allocator/CB -> CPU 不能复用
    使用 Queue::Signal + Fence 查询/等待
```

ResourceBarrier 不是等待 CPU；Fence 也不会自动改变资源状态。后续 CUDA/D3D12 互操作还会增加第三种问题：不同 API 的生产者/消费者交接，需要 External Semaphore/Fence。

---

## 6. 把 R.1、R.2、R.3 放回整体演进

### 6.1 R.1：正确解释一个顶点

```
CPU Vertex struct
    -> Vertex Buffer Resource
    -> D3D12_VERTEX_BUFFER_VIEW
    -> Input Layout
    -> VS 输入 POSITION/COLOR
```

R.1 解决“一个顶点的 28 个字节怎样拆成两个 HLSL 输入属性”。它还没有索引复用，也没有真实相机矩阵。

### 6.2 R.2：多个三角形复用顶点

```
IB[0..5] = {0,1,2, 0,2,3}
    -> IA 读取索引
    -> 每个索引定位 VB 中的 Vertex
    -> DrawIndexedInstanced
```

R.2 解决“图元怎样引用顶点”。它没有改变 Frame Fence 或 Shader 资源接口。

### 6.3 R.3：坐标变换和动态帧数据

```
CPU Model/View/Projection
    -> 每帧 ObjectConstants
    -> 256-byte CBV
    -> Root Descriptor Table -> HLSL b0
    -> VS: mul(localPosition, WVP)
```

R.3 的核心不是矩阵乘法本身，而是动态数据怎样在不覆盖 GPU 未完成读取的前提下进入一帧。

### 6.4 R.4 以后怎样插入

| 下一模块 | 加入的位置 | 不改变的骨架 |
|---|---|---|
| R.4 深度 | 启动创建 Depth Resource/DSV；每帧转换、清深度、OM 绑定 DSV；PSO 开启 Depth | 消息泵、Fence、Reset、Execute、Present 仍在原位置 |
| R.5 纹理 | 启动上传 Texture/SRV/Sampler；Root Signature 增加表；PSO/PS 读取 UV | VB/IB/CB 和帧同步仍保留 |
| R.6 实例 | 静态 VB/IB 继续共享；增加 Instance Buffer 和 shader instance ID | Draw 仍在 command list，Fence 仍保护动态数据 |
| C/D glTF | 文件加载阶段解析，生成 Mesh/Material/Node | Parser 不直接替换帧循环，只提供 Scene 数据 |
| R.7/CUDA | CUDA 写 Instance/Vertex Resource，External Fence 交接给 D3D12 | 两个 API 的生产/消费顺序叠加到现有同步上 |

---

## 7. 当前 demo 和目标渲染器的差距

当前程序已经是正确的 D3D12 最小网格渲染器，但不是完整引擎：

```
当前：
    一个窗口
    一个 Device/Direct Queue
    双缓冲 Back Buffer
    一个 Mesh + 顶点颜色
    一个 WVP CBV
    无 DSV、无 Texture、无 glTF、无 CUDA

目标：
    Window/Resize/Present 管理
    Device/Queue/Allocator/CommandList/Fence 层
    Upload/Default/Readback 资源系统
    Mesh/Material/Camera/Node/Scene
    Depth/Stencil、Texture/SRV/Sampler、Alpha/PBR
    glTF/GLB Parser 与资源工厂
    多实例和动态数据
    CUDA 生产数据与 D3D12 External Fence 交接
    Debug Layer、GPU Validation、DRED、性能标记和测试
```

“当前没有”不等于“不重要”。每个缺失模块会在后续单独加入，并用读回、截图或 Debug Layer 验收。

---

## 8. 如何阅读当前代码

永远先按调用图阅读：

```
main
  -> create_window
  -> create_renderer
      -> Device/Queue/SwapChain/BackBuffer/RTV/Allocator/Fence
  -> create_root_signature_and_pipeline
      -> Shader/Root Signature/PSO/Input Layout
  -> create_and_upload_mesh
      -> Upload/Copy/Default/VBV/IBV
  -> create_per_frame_constant_buffers
      -> Upload CB/Map/CBV
  -> while (running)
      -> PeekMessageW
      -> render_mesh_frame
          -> frame index/Fence wait
          -> update constants
          -> Reset allocator/list
          -> record commands
          -> Close/Execute/Present/Signal
  -> flush_gpu
  -> release/destroy
```

读每个函数时问：

1. 它创建、修改还是消费哪个对象？
2. 这段代码是 CPU 现在做的，还是 GPU 以后做的？
3. 它改变了 Resource State，还是只改变命令、descriptor 或 CPU 元数据？
4. 之后哪个 Fence 或生命周期规则允许对象被复用/释放？

---

## 9. 动手：不加新模块也能验证总图

在 PowerShell 运行：

```powershell
Set-Location C:\xf\Cuda\accelerated-computing-hub\learning\sandbox
.\build.ps1 d3d12\r01-r08-mesh\d3d12_mesh_input_layout.cu -NoRun
.\d3d12\r01-r08-mesh\d3d12_mesh_input_layout.exe --frames 2 --no-vsync
```

对照终端输出：

```
selected adapter
    对应 Device/Adapter 阶段

uploaded vertex/index buffer
    对应 Upload -> Copy -> Default 阶段

created 2 per-frame CBVs
    对应 FrameResources 动态数据阶段

rendered frames: 2
    对应主循环两次提交

D3D12 R.3 CPU MVP + CBV: PASS
    对应 WVP + CBV + Present/flush 验收
```

不要先改代码。先在纸上画出两条数据链：

```
ObjectConstants
    -> constant_buffer_mapped
    -> CBV descriptor
    -> GPU descriptor handle
    -> Root parameter 0
    -> HLSL register(b0)
    -> VS WVP
```

```
back_buffer
    -> RTV descriptor
    -> OMSetRenderTargets
    -> Clear/Draw
    -> PRESENT barrier
    -> Present
```

两条链都能独立画出来，才说明 R.3 的整体位置真正清楚。

---

## 10. 小结

当前渲染器由六个生命周期阶段组成：

```
启动资源
    -> 编译管线
    -> 上传静态数据
    -> 创建动态帧槽位
    -> 每帧录制并提交
    -> GPU 执行并 Present
    -> Fence 保护复用
    -> 退出 flush 后释放
```

R.1 解决顶点解释，R.2 解决索引复用，R.3 解决坐标变换和动态帧数据。R.4 只是在这个骨架中加入深度资源、DSV 和深度状态，不会另起一套流程。

## 自测题

1. 为什么 Shader/PSO 属于“如何画”的长期规则，而 WVP Constant Buffer 属于“这一帧画在哪里”的动态数据？
2. 当前 Vertex Buffer 上传完成后，为什么后续每帧不需要重新 Upload？如果要更新它，应该新增哪些同步/状态步骤？
3. R.4 增加深度缓冲时，哪些启动对象、每帧命令和 PSO 状态会变化？哪些帧流程骨架保持不变？

### 答案核对

1. Shader/PSO 描述输入格式、着色器和固定功能状态，所有帧可以复用；WVP 随相机、对象和时间变化，必须写入当前帧 CB。
2. 当前 VB 是静态 Default Heap 资源，所有帧都只读同一份字节，因此只需初始化上传一次。若更新它，需要让生产者写入资源，在 GPU 使用方式之间加入正确的 Copy/ResourceBarrier，并用 Fence 保证 GPU 不再读取旧内容后才复用写入区域。
3. 启动阶段新增 Depth Resource 和 DSV，PSO 开启深度状态；每帧在绘制前清深度，并在 OMSetRenderTargets 中提供 DSV，必要时记录 DEPTH_WRITE 状态转换。消息泵、Back Buffer 索引、Fence 等待、allocator/list Reset、Close、Execute、Present、Signal 和退出 flush 的骨架不变。

## 官方参考

- Direct3D 12 编程指南
- 命令队列与命令列表
- 资源屏障与状态
- Fence 与多引擎同步
