# R.7 D3D12 渲染器最小架构、上传器与 CPU 校验

## 1. 本节目标

R.1–R.6 已经能画出共享网格、材质队列和实例。本节不再加新画面效果，而是把已经堆在 `Renderer` 里的对象拆成**所有权边界**，并证明三件事：

1. 渲染器可以不依赖 CUDA 运行。
2. 关闭某个材质或替换网格，不会破坏 frame fence。
3. Debug Layer 运行干净：0 error、0 warning。

学完应能回答：

1. Device、Queue、SwapChain、Mesh、Material、FrameResources 各自拥有什么？谁只是描述？
2. 为什么 Debug Layer 必须在 `CreateDevice` 之前打开？
3. 共用上传器为什么要单独的 allocator/list？staging 什么时候才能释放？
4. 关闭 MASK 和替换 VB/IB 对 Fence 的要求为什么不同？

可运行代码：

- `learning/sandbox/d3d12/d3d12_mesh_input_layout.cu`
- `learning/sandbox/d3d12/d3d12_mesh_input_layout.hlsl`

官方资料：

- [Using the debug layer](https://learn.microsoft.com/en-us/windows/win32/direct3d12/using-the-debug-layer-to-debug-apps)
- [ID3D12Debug::EnableDebugLayer](https://learn.microsoft.com/en-us/windows/win32/api/d3d12sdklayers/nf-d3d12sdklayers-id3d12debug-enabledebuglayer)
- [ID3D12InfoQueue](https://learn.microsoft.com/en-us/windows/win32/api/d3d12sdklayers/nn-d3d12sdklayers-id3d12infoqueue)
- [ID3D12CommandQueue::Signal](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12commandqueue-signal)

## 2. 游戏开发类比

把渲染器想成剧组，不要把所有道具都塞进一个“导演”口袋：

```text
Device          道具工厂。它能造 Resource / Queue / PSO，但不保存像素。
Queue           拍摄时间线。命令按提交顺序执行。
SwapChain       两块轮换的幕布。Present 把当前幕布交给显示器。
Mesh Resource   长期布景。Default Heap 上的 VB/IB，多帧共享只读。
Material        拍摄说明书。CPU 策略：Alpha Mode、颜色因子。GPU 看不到这个容器。
FrameResources  当天的场记板：allocator、CB、实例缓冲、Back Buffer。
GpuUploader     搬运组。CPU 写 staging，GPU Copy 进 Default Heap。
Fence           场记时间戳。它不搬东西，只证明“这条时间线已经走到哪一票”。
```

引擎里的 `UWorld` / `Scene` 也是这样：Actor 不拥有 GPU 顶点字节；Mesh 资产拥有。换材质通常只改 Draw 列表；换网格才需要等 GPU 不再读旧 VB。

## 3. 所有权地图

当前 `Renderer` 不是“一个大类等于一台引擎”，而是把不同寿命的对象放在一起方便教学。真正要记住的是三类对象：

```text
拥有 GPU 内存 / COM 对象
    ID3D12Device
    ID3D12CommandQueue
    IDXGISwapChain3 及其 Back Buffer
    Default Heap：vertex_buffer / index_buffer / texture / depth_buffer
    每帧 Upload Heap：constant_buffer / instance_buffer
    Command Allocator / Command List
    PSO / Root Signature / Descriptor Heap
    Fence

只描述，不拥有字节
    D3D12_VERTEX_BUFFER_VIEW / INDEX_BUFFER_VIEW
    CBV / SRV / RTV / DSV / Sampler 描述符
    Root Signature 槽位
    Viewport / Scissor

CPU 策略，GPU 看不见
    CpuMesh
    Material / RenderQueue
    cpu_instances[]
    mask_material_enabled
```

因此：

- 改 `cpu_instances[i].color` 不必重建 VB。
- 关 MASK 不必释放 PSO 或纹理。
- 替换网格必须先证明 GPU 不再读旧 `vertex_buffer`，才能 `ComPtr::Reset()`。

`VBV` 不是 Vertex Buffer。`Material` 不是 Texture。`Fence` 不是 ResourceBarrier。

## 4. Debug Layer：必须在 CreateDevice 之前

真实原型：

```cpp
HRESULT D3D12GetDebugInterface(
    REFIID riid,
    void** ppvDebug);

void ID3D12Debug::EnableDebugLayer();
```

当前代码在 `create_renderer` 里：

```text
D3D12GetDebugInterface
    成功 -> EnableDebugLayer，再 CreateDXGIFactory2(DXGI_CREATE_FACTORY_DEBUG)
            再 D3D12CreateDevice
            再 device.As(&info_queue)
    失败 -> 继续跑，但打印“unavailable”
            不能把“没崩”说成 Debug Layer 干净
```

关键约束：

1. **进程级开关**。`EnableDebugLayer` 必须发生在该进程第一次 `D3D12CreateDevice` 之前。晚开，已经创建的 Device 不会被完整验证。
2. **需要 Windows Graphics Tools**。本机已安装，实测 `enabled before CreateDevice`。
3. **InfoQueue 挂在 Device 上**，不是挂在 Debug 接口上。它保存消息；本课不 `SetBreakOnSeverity`，避免无调试器的 `--frames` 验收被断点打断。
4. **HRESULT 管不了 void 录制 API**。`DrawIndexedInstanced`、`ResourceBarrier`、`SetDescriptorHeaps` 返回 void。非法状态通常由 Debug Layer 报告，严重时异步变成 `DXGI_ERROR_DEVICE_REMOVED`。

退出时 `drain_debug_layer_messages`：

```text
GetNumStoredMessages
for each:
    GetMessage(index, nullptr, &byte_count)   // 先问长度
    GetMessage(index, buffer, &byte_count)    // 再取正文
CORRUPTION / ERROR -> 程序失败
WARNING            -> 打印，本课验收也要求清到 0
```

本课清掉的两类 WARNING：

| 警告 | 原因 | 处理 |
|---|---|---|
| Buffer `InitialState=COPY_DEST` 被忽略 | Buffer 实际从 `COMMON` 创建，Copy 会 promote | 创建时写 `COMMON` |
| `CreateSampler2`：ALWAYS + 非 comparison filter | ComparisonFunc 会被忽略 | 改成 `NEVER` |

GPU-based Validation 和 DRED 仍放到 P.5.3。它们更慢、更专门，不和最小架构混在一次验收里。

## 5. 共用上传器

网格和纹理以前各自临时 `CreateCommandAllocator` + `CreateCommandList`，Copy 完就扔。本节收成 `GpuUploader`：

```text
GpuUploader
    allocator        上传命令的后备存储
    command_list     只录 Copy / Barrier，不录 Draw
    staging_buffers  必须活到 GPU Copy 完成的 Upload Heap
    is_recording     防止 begin 两次或未 begin 就 submit
```

它和每帧绘制 list **分开**。原因不是风格：一份 command list 同时只能处于 open 或 closed。绘制帧正在 `Reset` 录制时，不能把 Copy 插进同一份 recording 状态里凑合。

路径：

```text
begin_uploader
    若 staging 还在 -> flush_gpu("uploader reuse") 再 clear
    allocator->Reset
    command_list->Reset(allocator, nullptr)

create_upload_buffer
    CreateCommittedResource(UPLOAD, GENERIC_READ)
    Map / memcpy / Unmap
    调用方 push 进 staging_buffers

录制 CopyBufferRegion 或 CopyTextureRegion
录制 ResourceBarrier

submit_uploader
    Close
    ExecuteCommandLists
    flush_gpu(context)     // Signal + 等待
    staging_buffers.clear  // 现在才能释放 Upload Heap
```

`ExecuteCommandLists` 返回时 GPU 通常还没读完 staging。如果在返回后立刻让 `ComPtr` 析构，GPU 可能读到已释放内存。Fence 证明的是 **Queue 时间线已经走过这次 Copy**，不是“显示器已经画出这一帧”。

本课每次 submit 都 `flush_gpu`，是教学简化。生产上传器会给每批 Copy 单独记 fence 值，CPU 继续干别的，只在需要复用那块 staging 时等待。

Buffer 创建状态：

```text
CreateCommittedResource(..., COMMON)
CopyBufferRegion      COMMON 可被 promote 成 COPY_DEST
ResourceBarrier       COPY_DEST -> VERTEX_AND_CONSTANT_BUFFER / INDEX_BUFFER
```

纹理仍以 `COPY_DEST` 创建，因为它是 Texture2D，不是 Buffer；Debug Layer 不会发那条 Buffer 专用警告。

## 6. CPU 单元校验

GPU 不会替我们检查“索引 4 是否超过 3 个顶点”。错误网格会在 IA 读到未定义字节，画面可能只是花一下。所以校验发生在任何 Copy/Draw 之前。

`validate_cpu_mesh`：

- 顶点和索引都不能空。
- 索引数量必须是 3 的倍数（本课只画三角形列表）。
- 每个索引 `< vertices.size()`。

`validate_cpu_instances`：

- `instance_id == 数组下标`。
- `world._44 ≈ 1`，防止仿射矩阵被写成投影矩阵或未初始化内存。

这些检查不替代 Debug Layer。Debug Layer 抓 API 误用；CPU 校验抓资产契约。

## 7. 关闭材质 vs 替换网格

验收要求：关闭某个材质或替换网格，都不得破坏 frame fence。两件事对 GPU 生命周期的要求不同。

### 7.1 关闭 MASK

```text
mask_material_enabled = false
重建 CPU RenderQueue
MASK 那次 Draw 不再被录制
```

不释放：

- 纹理 Resource / SRV / Sampler
- 不透明 / 透明 PSO
- 共享 VB/IB
- Fence 时间线

GPU 上可能仍在执行上一帧已经提交的 MASK Draw。那是合法的：旧命令列表仍引用当时还活着的资源。新帧只是不再追加这次 Draw。

### 7.2 替换网格

```text
flush_gpu("replace mesh")     // 证明旧 VB/IB 的 GPU 读者已离开
vertex_buffer.Reset()
index_buffer.Reset()
创建新的 Default Heap Buffer
共用上传器 Copy + Barrier
更新 VBV/IBV
mesh_generation++
按新的 index_count 重建队列
```

`ComPtr::Reset()` 会立刻释放 COM 对象。若上一帧 Draw 仍在飞，这就是典型的 use-after-free，Debug Layer 会报，严重时 Device Removed。所以替换网格**必须**先等 Fence；关闭材质不必。

运行时序（`--frames 2`）：

```text
启动  上传三角形 generation=1，MASK 开
帧 0  画三角形，6 个实例，含 MASK
帧 0  提交后
        关 MASK  -> 队列 mask=0
        替换四边形 generation=2，先 flush 再释放旧 VB/IB
帧 1  画四边形，仍 6 个实例，无 MASK
退出  flush + drain InfoQueue
```

## 8. 每帧资源没有被这次重构打乱

`FrameResources` 仍然是：

```text
command_allocator
back_buffer + rtv
constant_buffer (256-byte CBV)
instance_buffer (6 * 96 bytes Root SRV)
fence_value
```

`wait_until_frame_is_reusable` 仍然在写 CB / Reset allocator 之前。替换网格的 `flush_gpu` 等的是**整条 Direct Queue**，比“等当前 Back Buffer 那一票”更粗。这保证旧 VB 安全，但会让 CPU 暂时追上 GPU。本课只在替换网格和退出时这样做，不在每帧 flush。

## 9. 商业引擎对照

| 引擎说法 | 底层更像什么 | 本课 |
|---|---|---|
| UE `FRenderResource` / Unity `Mesh` GPU 副本 | Default Heap VB/IB，CPU 网格是另一份 | `CpuMesh` vs `vertex_buffer` |
| 关 Renderer / 关材质球 | 从 Draw 列表拿掉，资源可仍 resident | `mask_material_enabled` |
| 热更新网格 / `CreateMesh` | 等 GPU fence 或延迟释放队列 | `flush_gpu` 再 `Reset` |
| 上传环（Upload heap ring） | 大块 staging + 每批 fence | 本课每次 Copy 都 flush |
| PIX / Debug Layer 开着进编辑器 | 开发机默认开 | 本课启动时开，退出 drain |
| GPU Validation / DRED | 更重的正确性/崩溃诊断 | P.5.3 |

相同机制：CPU 资产 ≠ GPU Resource；释放 GPU 对象前必须证明没有 in-flight 命令。

## 10. 当前简化边界

- 仍是单一 Direct Queue。没有 COPY queue、没有异步上传。
- 上传每次 flush，不是 ring buffer。
- 没有窗口 resize / `ResizeBuffers`。
- 没有 GPU-based Validation、DRED、Device Removed 恢复。
- 没有把 `Renderer` 拆成多个 .cpp；边界在结构体和函数上，不在工程文件上。
- 渲染器不依赖 CUDA，但粒子项目的 Debug Layer 收尾仍在 P.5.3。

## 11. 本机实测

PowerShell：

```powershell
cd C:\xf\Cuda\accelerated-computing-hub\learning\sandbox
.\build.ps1 d3d12\d3d12_mesh_input_layout.cu -NoRun
.\d3d12\d3d12_mesh_input_layout.exe --frames 2 --no-vsync
```

RTX 5070 / `sm_120`：

```text
D3D12 Debug Layer: enabled before CreateDevice
selected D3D12 adapter: NVIDIA GeForce RTX 5070
D3D12 InfoQueue: attached; messages drained at shutdown
CPU mesh check: shared-triangle vertices=3 indices=3 triangles=1
uploaded GPU mesh generation=1 name=shared-triangle ...
disabled MASK material; remaining draws do not touch Fence ownership
CPU mesh check: replacement-quad vertices=4 indices=6 triangles=2
uploaded GPU mesh generation=2 name=replacement-quad ...
Debug Layer messages: stored=0 errors=0 warnings=0
rendered frames: 2
frame-resource CPU waits: 0
mesh generation=2 mask_enabled=false
D3D12 R.7 renderer architecture and CPU validation: PASS
```

## 12. 小结

```text
Device 造对象，Queue 拥有时间线，SwapChain 拥有幕布
Mesh Resource 长期只读；Material / CpuMesh 是 CPU 策略
Debug Layer 必须在 CreateDevice 之前打开
上传器单独 list；staging 活到 Copy 的 Fence 完成
关材质 = 改 Draw 列表；换网格 = 先 flush 再释放旧 VB/IB
CPU 校验抓资产契约；Debug Layer 抓 API 误用
```

## 13. 自测题

1. 为什么 `EnableDebugLayer` 写在 `CreateDevice` 后面就等于没开？
2. 关闭 MASK 为什么不必 `flush_gpu`，替换四边形网格为什么必须？
3. `ExecuteCommandLists` 返回后立刻析构 staging Upload Buffer，错在哪一层：Resource State，还是 CPU/GPU 生命周期？
4. `validate_cpu_mesh` 能替代 Debug Layer 吗？反过来呢？
