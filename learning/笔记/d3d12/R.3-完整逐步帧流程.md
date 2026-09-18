# R.3 补课：正确的逐步帧流程

## 1. 这节课的目标

学完这一节，你应该能够回答三个问题，并能在代码中指出证据：

1. 一次 `render_mesh_frame` 调用中，哪些代码只是“录制命令”，哪一行才把命令交给 GPU？
2. 为什么同一套 `FrameResources` 不能在 GPU 未完成时被 CPU 重写或 `Reset`？
3. `ResourceBarrier`、`Present`、`Queue::Signal` 和 CPU 的 `WaitForSingleObject` 各自解决什么问题？

本节对应的真实代码是：

- `learning/sandbox/d3d12/d3d12_mesh_input_layout.cu` 的 `render_mesh_frame`
- 同文件的 `wait_until_frame_is_reusable`、`wait_for_fence_value`、`flush_gpu`

它是 R.1/R.2/R.3 的累积 demo：有 Vertex Buffer、Index Buffer、CPU WVP、每 Back Buffer 一个 CBV，暂时没有深度缓冲和纹理。

---

## 2. 先建立正确的心智模型

### 2.1 四条时间线

D3D12 把“调用 API”与“GPU 执行”分开。下面四条线必须分别看：

```
CPU 线程：
    取当前 Back Buffer -> 必要时等待 Fence -> 写当前 CB
    -> Reset allocator/list -> 录制命令 -> 提交

Command List（CPU 录制的命令包）：
    Barrier -> Clear -> 绑定 RTV/viewport/root/IA -> Draw -> Barrier

Direct Command Queue（GPU 的有序工作队列）：
    Execute 后，GPU 按列表中的顺序执行已经 Close 的命令
    -> Queue::Signal 到达一个时间线值

Fence（GPU 时间线的可观察标记）：
    CPU 读 GetCompletedValue；不够时登记 event，再 WaitForSingleObject
```

关键点：`ResourceBarrier`、`ClearRenderTargetView`、`DrawIndexedInstanced` 等调用发生在 CPU 录制阶段。调用返回并不表示像素已经被 GPU 写入；它们只是把操作写进 command list。`ExecuteCommandLists` 才把已关闭的列表放到 queue 上，GPU 随后异步执行。

### 2.2 三个“状态”不要混成一个词

| 概念 | 它回答的问题 | 本 demo 的例子 |
|---|---|---|
| Resource State | GPU 下一次准备怎样使用资源？ | Back Buffer 是 `PRESENT` 还是 `RENDER_TARGET`？VB 是 `VERTEX_AND_CONSTANT_BUFFER` 还是 `COPY_DEST`？ |
| CPU/GPU 所有权（更准确地说是可安全访问时机） | CPU 此刻能否改这块内存或重置这个命令分配器？ | 当前帧 Fence 未完成时，CPU 不能覆盖该帧 CB，也不能 Reset 其 allocator。 |
| 生命周期 | 对象本身能否释放？ | 退出前必须 `flush_gpu`，否则 COM 资源可能在 GPU 仍引用时析构。 |

Resource State 不是互斥锁，也不是 Fence。`PRESENT -> RENDER_TARGET` 只描述 GPU 使用方式变化；它不会让 CPU 等待。Fence 完成也不会自动把资源改成任何 state。

### 2.3 `FrameResources` 到底保护什么

代码中的结构体把“按 Back Buffer 隔离的对象”放在一起：

```
struct FrameResources {
  ComPtr<ID3D12CommandAllocator> command_allocator;
  ComPtr<ID3D12Resource> back_buffer;
  D3D12_CPU_DESCRIPTOR_HANDLE rtv{};
  UINT64 fence_value = 0;
  ComPtr<ID3D12Resource> constant_buffer;
  UINT8* constant_buffer_mapped = nullptr;
  D3D12_GPU_DESCRIPTOR_HANDLE cbv_gpu{};
};
```

- `command_allocator`：保存 command list 录制时使用的底层命令存储。GPU 尚未执行完旧列表时，不能 Reset 它。
- `back_buffer`：交换链拥有的渲染目标。它在 GPU 使用期间不能被当成另一张目标随意写。
- `rtv`：RTV descriptor 的 CPU 句柄。句柄不是资源所有权，也不替代 `back_buffer` 的 COM 引用。
- `constant_buffer_mapped`：Upload Heap 的 CPU 映射地址。GPU 可能在 VS 中读它，所以 CPU 只能在该 frame Fence 完成后改写。
- `cbv_gpu`：shader-visible heap 中 CBV 的 GPU 句柄。它只描述“从哪个 GPU 地址、读多少字节”，不拥有 Constant Buffer Resource。
- `fence_value`：CPU 保存的票号，表示“这套资源最近一次提交对应的 queue 时间线位置”。

同一个 Fence 可以保护多种资源，因为这些资源都在同一个 Direct Queue 的同一次提交中使用。这里使用两套 allocator 和两套 CB，形成最小双缓冲帧资源。

### 2.4 用两帧具体追踪一次循环

假定上传阶段已经消耗 fence 值 1，交换链有 Back Buffer 0 和 1：

| CPU 迭代 | `GetCurrentBackBufferIndex` | 使用的 allocator/CB | 提交后 `Signal` | 保存到 |
|---:|---:|---|---:|---|
| 0 | 0 | `frames[0]` | 2 | `frames[0].fence_value = 2` |
| 1 | 1 | `frames[1]` | 3 | `frames[1].fence_value = 3` |
| 2 | 0（由 DXGI 返回，不要自己取模猜） | `frames[0]` | 4 | 复用前先检查 Fence 2 |

在第 2 次迭代，如果 GPU 已经完成到 2，CPU 直接复用；如果只完成到 1，CPU 才等待 2。等待只发生在 CPU 赶上 GPU 时，不是每帧强制同步。

---

## 3. 一帧的完整步骤

下面的编号与 `render_mesh_frame` 的真实执行顺序一致。先看“调用发生在哪条时间线”，再看参数和约束。

### 1. 处理窗口消息：`PeekMessageW`

主循环先执行：

```
MSG message{};
while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
  if (message.message == WM_QUIT) {
    running = false;
    break;
  }
  TranslateMessage(&message);
  DispatchMessageW(&message);
}
```

Windows SDK 声明：

```
BOOL PeekMessageW(
    LPMSG lpMsg,
    HWND hWnd,
    UINT wMsgFilterMin,
    UINT wMsgFilterMax,
    UINT wRemoveMsg);
```

- `lpMsg`：输出消息结构体的地址；这里是栈上的 `message`。
- `hWnd`：只取某窗口消息；`nullptr` 表示当前线程队列中的所有窗口消息。
- `wMsgFilterMin/wMsgFilterMax`：消息范围；这里两个都为 0，表示不按消息编号筛选。
- `wRemoveMsg`：`PM_REMOVE` 取出并移除消息；若用 `PM_NOREMOVE`，循环会反复看到同一条消息。

`PeekMessageW` 是非阻塞的。队列为空时立即返回 0，程序继续录制一帧；这适合教学 demo 的“空闲时持续渲染”。生产程序也可以用 `WaitMessage`、DXGI frame-latency waitable object 等方式降低空闲 CPU 占用，本 demo 暂不展开。

`TranslateMessage(const MSG*)` 只把键盘虚拟键消息转换成字符消息（如果适用），`DispatchMessageW(const MSG*)` 把消息调用到窗口过程 `window_procedure`。本例的退出链是：

```
ESC -> DestroyWindow -> WM_DESTROY -> PostQuitMessage(0) -> WM_QUIT
```

收到 `WM_QUIT` 后不能继续访问窗口或交换链，所以主循环先把 `running` 设为 `false`，跳出后再做 GPU flush。

### 2. 获取 DXGI 当前 Back Buffer：`GetCurrentBackBufferIndex`

```
const UINT frame_index = renderer.swap_chain->GetCurrentBackBufferIndex();
FrameResources& frame = renderer.frames[frame_index];
```

声明：

```
UINT GetCurrentBackBufferIndex(void);
```

它没有参数，也不返回 `HRESULT`；返回交换链当前的缓冲区编号，范围是 `[0, BufferCount)`。这个编号决定本轮要绑定哪一个 `back_buffer`、RTV、allocator、CB 和 CBV。

不要写成 `frame_number % kBackBufferCount`：交换链的缓冲区选择受 Present、队列、窗口状态和后续 resize 影响，DXGI 返回值才是权威状态。`frame_number` 只是本 demo 用来生成旋转角度的 CPU 计数器，两者不是同一个概念。

### 3. 读取 Fence 已完成值：`GetCompletedValue`

`wait_until_frame_is_reusable` 首先执行：

```
if (frame.fence_value == 0 ||
    renderer.fence->GetCompletedValue() >= frame.fence_value) {
  return;
}
```

声明：

```
UINT64 GetCompletedValue(void);
```

它是一个非阻塞查询：返回 GPU 已经完成的 Fence 时间线值。本 demo 约定所有 Queue Signal 都使用单调递增值，所以可以用 `>=`：如果已完成值为 7，那么由本 demo 编号的 1 到 7 都已越过对应标记。不要脱离这个编号约定，随意倒退或复用 Fence 值。

`frame.fence_value == 0` 表示这套帧资源从来没有提交过，因此不存在旧 GPU 工作。代码中的快路径不创建 event、不睡眠。

错误边界：官方文档规定设备被移除时可能返回 `UINT64_MAX`。本 demo 没有把它当成独立的 device-removed 诊断路径；生产代码应检查 `GetDeviceRemovedReason`，并结合 DRED 记录原因，不能仅凭“Fence 很大”认为渲染正常。

### 4. 登记完成事件：`SetEventOnCompletion`

如果完成值还不够，`wait_for_fence_value` 调用：

```
HR_CHECK(renderer.fence->SetEventOnCompletion(
    value, renderer.fence_event));
```

声明：

```
HRESULT SetEventOnCompletion(UINT64 Value, HANDLE hEvent);
```

- `Value`：目标 Fence 值；Fence 达到或超过它时触发。
- `hEvent`：已由 `CreateEventW` 创建的 Win32 event；本例是自动复位、初始无信号事件。

这一步只向 D3D12 登记通知，**不阻塞 CPU**。`HR_CHECK` 处理登记失败；失败可能来自无效句柄、设备异常或其他 API 错误。真正阻塞发生在下一步 `WaitForSingleObject`。

### 5. 阻塞 CPU：`WaitForSingleObject`

```
const DWORD wait_result =
    WaitForSingleObject(renderer.fence_event, INFINITE);
```

声明：

```
DWORD WaitForSingleObject(HANDLE hHandle, DWORD dwMilliseconds);
```

- `hHandle`：等待的 event。
- `dwMilliseconds`：超时毫秒数；`INFINITE` 表示一直等到 event 被置为有信号。

GPU 到达 Fence 值后，D3D12 置 event，等待线程醒来。这里 `CreateEventW(nullptr, FALSE, FALSE, nullptr)` 的第二个 `FALSE` 表示自动复位；一次等待消费一次信号，适合反复等待不同帧值。

代码只接受 `WAIT_OBJECT_0`，其他返回（例如 `WAIT_FAILED`）都按失败退出。生产程序通常还会处理窗口关闭、超时、设备移除和可取消等待；本 demo 为了让同步因果清楚使用无限等待。

### 6. 更新当前帧 Constant Buffer

`wait_until_frame_is_reusable` 返回后才执行：

```
update_frame_constants(frame, frame_number);
```

初始化时每个 CB 都被 `Map` 到 Upload Heap，并保持映射。每帧函数通过 `std::memcpy` 把 256 字节 `ObjectConstants` 写到当前帧地址。这里没有 ResourceBarrier，原因是：

- Upload Heap 资源创建为 `D3D12_RESOURCE_STATE_GENERIC_READ`，CPU 写入、GPU 读取是它的典型用途。
- CPU 是否可以改写，取决于 GPU 是否还在读同一地址；这个约束由 Frame Fence 解决。
- ResourceBarrier 只描述 GPU 资源状态转换，不能把“GPU 仍在读取”变成“CPU 可写”。

矩阵内容是 CPU 计算的 `world * view * projection`；CBV 只是后面让 VS 访问这段地址的描述符。CPU 没有把矩阵字节“塞进 command list”。

### 7. 回收命令存储：`ID3D12CommandAllocator::Reset`

```
HR_CHECK(frame.command_allocator->Reset());
```

声明：

```
HRESULT Reset(void);
```

它让 allocator 的命令存储回到可录制状态，旧命令内容将被后续录制覆盖。它**不执行旧命令，也不清空 Back Buffer**。

最重要的前置条件：GPU 必须已经执行完上一次使用该 allocator 的 command list。否则 CPU 可能覆盖 GPU 正在读取的命令存储，Debug Layer 会报告错误，结果可能是设备移除。当前代码把这条约束放在步骤 3–5 的 Fence 等待之前，因此顺序不能换。

`Reset` 失败返回 `HRESULT`，当前 `HR_CHECK` 立即报告调用文本和十六进制错误码。

### 8. 开始录制：`ID3D12GraphicsCommandList::Reset`

```
HR_CHECK(renderer.command_list->Reset(
    frame.command_allocator.Get(), renderer.pipeline_state.Get()));
```

声明：

```
HRESULT Reset(
    ID3D12CommandAllocator* pAllocator,
    ID3D12PipelineState* pInitialState);
```

- `pAllocator`：本次录制写入的 allocator；这里选择与当前 Back Buffer 同属一帧的 allocator。
- `pInitialState`：可选初始 PSO；这里传图形 PSO，所以 Reset 后 PSO 已经设置。若传 `nullptr`，后面必须显式 `SetPipelineState`。

Reset 让已关闭的 command list 重新进入 recording 状态。它只是 CPU 侧的编码操作，GPU 不会因为 Reset 调用而执行任何东西。

一个常见误解是“command list 执行中就绝对不能 Reset”。真正必须等 GPU 完成的是同一个 **allocator**；command list 对象可以在上一次提交后被重新 Reset，但必须给它一个仍可安全复用的 allocator。当前代码每帧等待对应 allocator 的 Fence，因而同时满足两种约束。

### 9. 记录 Back Buffer 状态转换：`ResourceBarrier`

```
D3D12_RESOURCE_BARRIER to_render_target{};
to_render_target.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
to_render_target.Transition.pResource = frame.back_buffer.Get();
to_render_target.Transition.Subresource =
    D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
to_render_target.Transition.StateBefore = D3D12_RESOURCE_STATE_PRESENT;
to_render_target.Transition.StateAfter = D3D12_RESOURCE_STATE_RENDER_TARGET;
renderer.command_list->ResourceBarrier(1, &to_render_target);
```

声明：

```
void ResourceBarrier(
    UINT NumBarriers,
    const D3D12_RESOURCE_BARRIER* pBarriers);
```

- `NumBarriers`：数组中 barrier 数量，本例为 1。
- `pBarriers`：连续的 `D3D12_RESOURCE_BARRIER` 数组；数组只需在调用期间有效。
- `Type = TRANSITION`：本例描述资源状态转换，而不是 aliasing/UAV barrier。
- `pResource`：要转换的 Back Buffer。
- `Subresource`：`ALL_SUBRESOURCES` 表示所有子资源；纹理带 mip/array 时可只转换一个子资源。
- `StateBefore/StateAfter`：必须与 D3D12 对该资源的状态跟踪一致；这里是 `PRESENT -> RENDER_TARGET`。

Barrier 是写进 command list 的 GPU 同步命令，不是 CPU 立即执行的函数。它保证 GPU 在这张 Back Buffer 上开始 RTV 写入前，完成前一种使用方式的排序和状态切换。

### 10. 绑定渲染目标：`OMSetRenderTargets`

```
renderer.command_list->OMSetRenderTargets(
    1, &frame.rtv, FALSE, nullptr);
```

声明：

```
void OMSetRenderTargets(
    UINT NumRenderTargetDescriptors,
    const D3D12_CPU_DESCRIPTOR_HANDLE* pRenderTargetDescriptors,
    BOOL RTsSingleHandleToDescriptorRange,
    const D3D12_CPU_DESCRIPTOR_HANDLE* pDepthStencilDescriptor);
```

- `NumRenderTargetDescriptors`：绑定的 RTV 数量，本例为 1。
- `pRenderTargetDescriptors`：CPU RTV 句柄数组；这里指向当前帧的 `frame.rtv`。
- `RTsSingleHandleToDescriptorRange`：为 `TRUE` 时把 `pRenderTargetDescriptors` 当作连续 descriptor range 的起点；本例为 `FALSE`，按句柄数组读取。数量为 1 时两种写法结果相同，但参数语义仍不能混淆。
- `pDepthStencilDescriptor`：可选 DSV 句柄；本节没有深度资源，所以传 `nullptr`。

RTV heap 是 `D3D12_DESCRIPTOR_HEAP_FLAG_NONE` 的 CPU-only heap；它不需要也不能通过 `SetDescriptorHeaps` 绑定给 shader。这个 API 只把 RTV 作为输出合并阶段的目标记录进命令列表。

### 11. 清除颜色：`ClearRenderTargetView`

```
const float clear_color[4] = {0.025f, 0.035f, 0.075f, 1.0f};
renderer.command_list->ClearRenderTargetView(
    frame.rtv, clear_color, 0, nullptr);
```

声明：

```
void ClearRenderTargetView(
    D3D12_CPU_DESCRIPTOR_HANDLE RenderTargetView,
    const FLOAT ColorRGBA[4],
    UINT NumRects,
    const D3D12_RECT* pRects);
```

- `RenderTargetView`：要清除的 RTV CPU 句柄。
- `ColorRGBA[4]`：四个浮点颜色分量；它们按 RTV 格式转换后写入目标，本例是 `R8G8B8A8_UNORM`。
- `NumRects`：只清除哪些矩形；0 表示整个视图，因而 `pRects` 必须为 `nullptr`。
- `pRects`：矩形数组；只有 `NumRects > 0` 时才提供。

这仍然只是命令录制。资源必须处于 `RENDER_TARGET` 状态；清除直接使用传入的 RTV，并不要求它事先通过 `OMSetRenderTargets` 绑定。本例先绑定再清除只是自然的帧顺序，不是 Clear API 的前置条件。清除也不会自动做状态转换或代替绘制。

### 12. 设置视口：`RSSetViewports`

```
renderer.command_list->RSSetViewports(1, &renderer.viewport);
```

声明：

```
void RSSetViewports(
    UINT NumViewports,
    const D3D12_VIEWPORT* pViewports);
```

- `NumViewports`：视口数量，本例为 1。
- `pViewports`：视口数组；本例为 `{TopLeftX=0, TopLeftY=0, Width=1280, Height=720, MinDepth=0, MaxDepth=1}`。

Vertex Shader 输出的 `SV_Position` 在透视除法后进入 viewport 变换，NDC 的 `x/y` 被映射到这个矩形，深度被映射到 `[MinDepth, MaxDepth]`。viewport 不是窗口尺寸本身；窗口 resize 时需要重算它，本 demo 固定 1280x720。

### 13. 设置裁剪矩形：`RSSetScissorRects`

```
renderer.command_list->RSSetScissorRects(1, &renderer.scissor);
```

声明：

```
void RSSetScissorRects(
    UINT NumRects,
    const D3D12_RECT* pRects);
```

- `NumRects`：裁剪矩形数量，本例为 1。
- `pRects`：整数矩形数组，本例为 `{0, 0, 1280, 720}`。

Scissor 是光栅化阶段的整数裁剪。它与 viewport 独立：viewport 决定坐标映射，scissor 决定哪些像素允许继续。未设置或尺寸不匹配时，几何可能被裁掉；每次 Reset 后都应重新设置需要的管线状态。

### 14. 绑定图形 Root Signature：`SetGraphicsRootSignature`

```
renderer.command_list->SetGraphicsRootSignature(
    renderer.root_signature.Get());
```

声明：

```
void SetGraphicsRootSignature(
    ID3D12RootSignature* pRootSignature);
```

Root Signature 是 shader 资源接口的布局规则。本例的 root parameter 0 是一个 VS 可见的 CBV descriptor table，对应 HLSL `register(b0)`。这个调用只选择“接口规则”，不会自动选择某个 CBV，也不会把矩阵数据复制进命令列表；下一步的 `SetDescriptorHeaps` 和再下一步的 `SetGraphicsRootDescriptorTable` 才提供具体 descriptor。

PSO 中保存的 root-signature 兼容性必须和这里绑定的 Root Signature 一致。当前 demo 通过 Reset 的 `pInitialState` 预设 PSO，但仍显式绑定 Root Signature，使每次录制的接口状态清楚可见。

### 15. 绑定 shader-visible Descriptor Heap：`SetDescriptorHeaps`

```
ID3D12DescriptorHeap* shader_visible_heaps[] = {
    renderer.cbv_heap.Get()};
renderer.command_list->SetDescriptorHeaps(
    1, shader_visible_heaps);
```

声明：

```
void SetDescriptorHeaps(
    UINT NumDescriptorHeaps,
    ID3D12DescriptorHeap* const* ppDescriptorHeaps);
```

- `NumDescriptorHeaps`：数组数量，本例为 1。
- `ppDescriptorHeaps`：descriptor heap 对象指针数组；数组本身是 CPU 临时数组，heap COM 对象必须在 GPU 执行期间继续存活。

本例 heap 类型是 `D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV`，并且创建时使用 `D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE`。创建 heap 只分配并初始化容器，**不等于当前 command list 已绑定它**。Root descriptor table 使用的 GPU handle 必须属于这里绑定的 heap。

图形 command list 同时最多绑定一个 CBV/SRV/UAV heap 和一个 Sampler heap；切换 heap 后，应重新设置依赖旧 heap 的 root descriptor table。RTV/DSV heap 是 CPU handle 绑定，不在此 API 的范围内。

### 16. 选择当前帧 CBV：`SetGraphicsRootDescriptorTable`

```
renderer.command_list->SetGraphicsRootDescriptorTable(
    0, frame.cbv_gpu);
```

声明：

```
void SetGraphicsRootDescriptorTable(
    UINT RootParameterIndex,
    D3D12_GPU_DESCRIPTOR_HANDLE BaseDescriptor);
```

- `RootParameterIndex`：Root Signature 中的参数编号；本例 0 对应 CBV table。
- `BaseDescriptor`：当前已绑定 shader-visible heap 内的 GPU descriptor handle；本例指向 `frames[frame_index]` 的 CBV。

GPU 执行 VS 时根据这个 table 查到 `b0`，再按 CBV 中的 `BufferLocation` 和 `SizeInBytes` 读取矩阵。GPU handle 不是 CPU 指针，不是 Resource 指针，也不会延长 Resource 生命周期；heap、CB Resource 和其 mapped 内存必须由 `Renderer` 保持到 GPU 完成。

### 17. 设置图元拓扑：`IASetPrimitiveTopology`

```
renderer.command_list->IASetPrimitiveTopology(
    D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
```

声明：

```
void IASetPrimitiveTopology(
    D3D12_PRIMITIVE_TOPOLOGY PrimitiveTopology);
```

本例选择 `TRIANGLELIST`：每连续三个索引组成一个独立三角形，6 个索引产生 2 个三角形。它必须与 PSO 的 `PrimitiveTopologyType = TRIANGLE` 兼容。拓扑状态只写入 command list，不会修改 Index Buffer 内容。

### 18. 绑定 Vertex Buffer：`IASetVertexBuffers`

```
renderer.command_list->IASetVertexBuffers(
    0, 1, &renderer.vertex_buffer_view);
```

声明：

```
void IASetVertexBuffers(
    UINT StartSlot,
    UINT NumViews,
    const D3D12_VERTEX_BUFFER_VIEW* pViews);
```

- `StartSlot`：第一个 IA vertex-input slot；本例从 slot 0 开始。
- `NumViews`：连续绑定的 View 数量；本例为 1，所以只覆盖 slot 0。
- `pViews`：`D3D12_VERTEX_BUFFER_VIEW` 数组指针；数组只需在调用期间有效。

本例的 view 是：

```
struct D3D12_VERTEX_BUFFER_VIEW {
  D3D12_GPU_VIRTUAL_ADDRESS BufferLocation;
  UINT SizeInBytes;
  UINT StrideInBytes;
};
```

`BufferLocation` 指向 Default Heap VB 的 GPU 虚拟地址；`StrideInBytes=28` 告诉 IA 从一个顶点跳到下一个顶点要前进 28 字节；`SizeInBytes=112` 限定可读取范围。View 不拥有 `vertex_buffer`，所以 Resource 必须一直存活。资源在上传命令完成后已经转换为 `D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER`，绘制阶段只读。

`StartSlot=0` 必须和 Input Layout 每个元素的 `InputSlot=0` 对上。若 position/color 分成两个 interleaved 或 planar 流，就需要多个 view 和对应 slot。

### 19. 绑定 Index Buffer：`IASetIndexBuffer`

```
renderer.command_list->IASetIndexBuffer(
    &renderer.index_buffer_view);
```

声明：

```
void IASetIndexBuffer(
    const D3D12_INDEX_BUFFER_VIEW* pView);
```

本例 `D3D12_INDEX_BUFFER_VIEW` 为：

```
struct D3D12_INDEX_BUFFER_VIEW {
  D3D12_GPU_VIRTUAL_ADDRESS BufferLocation;
  UINT SizeInBytes;
  DXGI_FORMAT Format;
};
```

`BufferLocation` 和 `SizeInBytes` 的含义与 VB 类似；`Format=DXGI_FORMAT_R16_UINT` 告诉 IA 每个索引占 2 字节并按无符号 16 位解码。索引资源处于 `D3D12_RESOURCE_STATE_INDEX_BUFFER`。传 `nullptr` 可以解绑 IB，但本例要绘制索引网格，所以提供有效 view。

IB 不占用 vertex input slot，它有单独的绑定点。Draw 时 GPU 先从 IB 取索引，再用索引定位 VB。

### 20. 录制绘制命令：`DrawIndexedInstanced`

```
renderer.command_list->DrawIndexedInstanced(
    6, 1, 0, 0, 0);
```

声明：

```
void DrawIndexedInstanced(
    UINT IndexCountPerInstance,
    UINT InstanceCount,
    UINT StartIndexLocation,
    INT  BaseVertexLocation,
    UINT StartInstanceLocation);
```

本例参数逐个解释：

- `IndexCountPerInstance=6`：每个实例从 IB 读取 6 个索引。
- `InstanceCount=1`：只画一个实例。
- `StartIndexLocation=0`：从索引数组第 0 项开始。
- `BaseVertexLocation=0`：读出的索引再加 0；如果一个 mesh 使用 VB 的子范围，可以加一个有符号基址。
- `StartInstanceLocation=0`：实例编号起点；当前只有一个实例，没有偏移。

概念上的顶点编号是：

```
rawIndex = IB[StartIndexLocation + localIndex]
vertexIndex = rawIndex + BaseVertexLocation
vertexBytes = VB.BufferLocation + vertexIndex * StrideInBytes
```

真正执行时，GPU 才会读取 IB、按 Input Layout 从 VB 解码 POSITION/COLOR、执行 VS（读取 b0 CBV）、光栅化并执行 PS。此时仍必须记住：Draw 调用点只是记录，不是立即绘制。

### 21. 记录回到 Present 的状态转换

```
D3D12_RESOURCE_BARRIER to_present = to_render_target;
to_present.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET;
to_present.Transition.StateAfter = D3D12_RESOURCE_STATE_PRESENT;
renderer.command_list->ResourceBarrier(1, &to_present);
```

这里复制了第一条 barrier，再反向修改 `StateBefore/StateAfter`。这样同一张 Back Buffer 在本 command list 中形成闭环：

```
PRESENT -> RENDER_TARGET ->（clear/draw）-> PRESENT
```

`Present` 不会替你补上第二条转换。若省略它，Debug Layer 会指出 Present 前资源状态不符合要求；关闭 Debug Layer 时可能只表现为黑屏、设备移除或未定义结果。

### 22. 结束录制：`Close`

```
HR_CHECK(renderer.command_list->Close());
```

声明：

```
HRESULT Close(void);
```

`Close` 把 command list 从 recording 变为 closed，并进行提交前检查。它不把列表放进 queue，不等待 GPU，不调用 Present。列表只有在 closed 状态下才能传给 `ExecuteCommandLists`。

常见错误包括：忘记 Close、重复 Close、参数状态非法、使用不兼容的资源状态。当前 `HR_CHECK` 会捕获 `Close` 返回的失败；许多录制 API 本身返回 `void`，它们的错误通常由 Debug Layer 在录制/提交时报告，严重错误可能在 GPU 执行后表现为 device removed。

### 23. 提交到 Direct Queue：`ExecuteCommandLists`

```
ID3D12CommandList* command_lists[] = {
    renderer.command_list.Get()};
renderer.command_queue->ExecuteCommandLists(
    1, command_lists);
```

声明：

```
void ExecuteCommandLists(
    UINT NumCommandLists,
    ID3D12CommandList* const* ppCommandLists);
```

- `NumCommandLists=1`：本次提交一个列表。
- `ppCommandLists`：closed command list 指针数组；栈数组只需活到函数调用返回，列表和其 allocator/资源则必须继续存活到 GPU 完成。

这是 CPU 把命令包放到 queue 的边界。API 返回不等于 GPU 已完成；D3D12 的设计就是让 CPU 继续录制/提交后续工作。Queue 内的命令按提交顺序执行，后面的 `Signal` 因而可以作为“此前工作已越过”的时间线标记。

### 24. 交给 DXGI：`Present`

```
HR_CHECK(renderer.swap_chain->Present(
    vsync ? 1 : 0, 0));
```

声明：

```
HRESULT Present(UINT SyncInterval, UINT Flags);
```

- `SyncInterval=1`（默认 vsync）：请求按一个垂直刷新间隔呈现。
- `SyncInterval=0`（`--no-vsync`）：不等待一个完整刷新间隔；是否撕裂还取决于交换链创建时是否允许 tearing 以及 Present flags，本 demo 没有创建 `DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING`，所以不能把它宣传成“保证无撕裂”。
- `Flags=0`：本例没有 `DXGI_PRESENT_ALLOW_TEARING`、`DO_NOT_WAIT` 等标志。

Present 是 DXGI 的呈现请求，不是 command list 提交，也不是 ResourceBarrier。它要求 Back Buffer 在调用前已经由命令列表转换回 `PRESENT`。Present 可能受窗口遮挡、系统合成器或 vsync 节流影响，并返回 `HRESULT`；当前 `HR_CHECK` 只处理 `FAILED`，没有专门的 occlusion/recovery 路径。

### 25. 在 Queue 时间线上打 Fence 标记：`ID3D12CommandQueue::Signal`

```
const UINT64 submitted_value = renderer.next_fence_value++;
HR_CHECK(renderer.command_queue->Signal(
    renderer.fence.Get(), submitted_value));
```

声明：

```
HRESULT Signal(
    ID3D12Fence* pFence,
    UINT64 Value);
```

- `pFence`：要更新的 Fence 对象。
- `Value`：本次 queue 时间线标记；本 demo 用单调递增的 `next_fence_value`，避免把不同提交混成同一个票号。

这是 **Queue 的 Signal**，不是 CPU 直接调用 Fence 的 signal。它把一个“到达此处时把 Fence 推进到 Value”的操作排在该 queue 之前已经提交的工作之后。调用本身不会让 CPU 等待；只有 GPU 执行到标记后，`GetCompletedValue` 才会达到该值。

Fence 完成表示该 queue 已经完成此前的 D3D12 工作（包括 Draw 前后的 resource barrier），足以保护本 demo 中 allocator、CB 和命令引用的生命周期。它不等于显示器已经扫描完像素，也不是跨 queue 的自动同步；若有 copy/compute queue，需要显式 queue wait 或其他跨引擎同步。

### 26. 保存这套 FrameResources 的票号

```
frame.fence_value = submitted_value;
```

这一行没有 D3D12 API，却是帧资源系统的关键 CPU bookkeeping。它把“刚刚提交的工作”与 `frames[frame_index]` 关联起来。下一次 `GetCurrentBackBufferIndex()` 返回这个索引时，步骤 3 会读取同一个票号，只有完成后才允许：

```
改写该帧 Constant Buffer
Reset 该帧 Command Allocator
再次使用该帧 Back Buffer/RTV
```

如果漏掉这行，Fence 仍然会前进，但 CPU 不知道哪个资源由哪个值保护，下一轮只能盲等或错误复用。

### 27. 进入下一轮

`render_mesh_frame` 返回主循环，处理下一批窗口消息，再次调用 `GetCurrentBackBufferIndex`。不要缓存并手动翻转索引；DXGI 可能在 Present 后给出 0、1 或未来更多缓冲区中的任意当前索引。

也不要把 Fence 等待放在每帧固定位置。正确策略是“将要复用哪套资源，就查询那套资源的票号；只有未完成才等待”。这正是 `frame_reuse_cpu_waits` 统计的含义。

### 28. 退出时清空 Queue：`flush_gpu`

```
void flush_gpu(Renderer& renderer) {
  const UINT64 flush_value = renderer.next_fence_value++;
  HR_CHECK(renderer.command_queue->Signal(
      renderer.fence.Get(), flush_value));
  wait_for_fence_value(renderer, flush_value, "shutdown");
}
```

退出循环后没有下一帧来触发普通的 frame-resource wait，但 `Renderer` 的 `ComPtr` 很快会析构，event 也会关闭。因此在同一个 queue 的末尾再排一个 Fence 值并等待，保证它之前已经提交的图形工作完成。

正确的退出顺序是：

```
停止录制新帧
-> Queue::Signal(flush_value)
-> SetEventOnCompletion + WaitForSingleObject
-> 关闭 event、释放 D3D12 COM 资源、销毁窗口类
```

`flush_gpu` 不是每帧都应该调用的函数；把它放进每帧循环会退化成 CPU/GPU 完全串行，失去多帧资源的意义。

---

## 4. 把一帧压缩成一张可检查的图

```
Windows 消息队列
        │ Peek/Translate/Dispatch
        ▼
DXGI 返回 frame_index
        │
        ├─ Fence 未完成 ── SetEventOnCompletion ── WaitForSingleObject
        │                         （只在需要时阻塞 CPU）
        ▼
CPU 写当前 CB
        ▼
Allocator::Reset -> CommandList::Reset(allocator, initial PSO)
        ▼
录制：PRESENT -> RENDER_TARGET
      OMSetRenderTargets / Clear / Viewport / Scissor
      RootSignature / DescriptorHeap / CBV table
      Topology / VBV / IBV / DrawIndexedInstanced
      RENDER_TARGET -> PRESENT
        ▼
Close（仍在 CPU）
        ▼
ExecuteCommandLists（提交到 GPU Queue）
        ▼
Present（DXGI 呈现请求）
        ▼
Queue::Signal(fence, value)（排队的 GPU 时间线标记）
        ▼
frame.fence_value = value（CPU 记录，供未来复用判断）
```

六句必须能脱口而出：

```
Reset 不是执行。
Close 不是提交。
ExecuteCommandLists 才是提交。
Present 不替代资源状态转换。
Queue::Signal 不等于 CPU 等待。
Fence 完成后才允许复用受保护的帧资源。
```

---

## 5. 当前 demo 的边界：哪些事情故意还没做

这份流程是正确的最小 D3D12 帧循环，但不是生产渲染器。必须明确以下简化：

1. **固定窗口尺寸**：没有处理 `WM_SIZE`、`ResizeBuffers`、Back Buffer RTV 重建、projection/viewport/scissor 更新。
2. **没有 DSV/深度测试**：R.4 才创建 Depth-Stencil Resource、DSV、`D3D12_RESOURCE_STATE_DEPTH_WRITE` 和清深度。
3. **只有一个 Direct/Graphics Queue**：上传也暂时使用 Direct Queue；没有 Copy Queue、Compute Queue、queue wait 或跨引擎 Fence。
4. **没有 CUDA**：本节只解释 D3D12 的资源与同步；CUDA external memory/semaphore 属于后面的 R.7/阶段 9.2。
5. **没有 Debug Layer、GPU Validation、DRED 恢复**：`void` 录制 API 的非法状态不能仅靠 `HRESULT` 捕获；生产初始化应开启 Debug Layer，并在设备移除时采集 DRED。
6. **每个 frame 只有一个 CBV**：真实 renderer 通常使用按帧线性分配的常量环形缓冲，并用 256-byte offset 管理多个对象。
7. **一个可复用 command list 对象**：allocator 按帧隔离；更复杂的 renderer 可能有多个列表、bundle 或线程录制。
8. **Present flags 固定为 0**：没有 frame-latency waitable object、tearing 选项、occlusion 重试和 HDR 色彩空间管理。
9. **上传资源的生命周期只为教学服务**：VB/IB 上传完成后同步等待，因此可以安全释放临时 Upload Resource；异步上传系统通常会把它放入延迟释放队列，等 Copy Fence 完成。

“简化”不表示可以省略这些机制；它只表示它们在后续 R.4、R.7、Debug/性能章节中单独展开。

---

## 6. 错误路径与排查顺序

### 6.1 `HRESULT` 与 `void` 的差异

本 demo 用 `HR_CHECK` 包住了 `Reset`、`Close`、`Present`、Queue `Signal`、Fence event 登记等返回 `HRESULT` 的调用。失败时打印调用表达式并退出，避免错误拖到黑屏阶段。

`ResourceBarrier`、`ClearRenderTargetView`、绑定 API、Draw、`ExecuteCommandLists` 在 C++ 接口中返回 `void`。它们不是“永远不会出错”，而是错误通常通过 Debug Layer 输出，严重的 GPU 执行错误可能异步地变成 `DXGI_ERROR_DEVICE_REMOVED`。所以真实项目应：

1. 初始化时启用 D3D12 Debug Layer；开发期按需启用 GPU-based validation。
2. 为每个 queue/list 设置名称和 PIX/NVTX 标记，定位最后一条命令。
3. 在 `Present` 或后续 API 返回 device-removed 时调用 `GetDeviceRemovedReason`，并采集 DRED。
4. 检查所有资源状态、descriptor heap 类型/可见性、Root Signature 与 shader register 是否匹配。

### 6.2 看到黑屏时按这条链查

```
窗口/消息泵是否还在运行？
-> Present 是否失败或设备被移除？
-> command list 是否 Close 且 Execute？
-> 两条 Back Buffer barrier 是否配对？
-> RTV 是否对应当前 frame_index？
-> SetDescriptorHeaps 是否早于 SetGraphicsRootDescriptorTable？
-> VBV/IBV 的地址、大小、stride、format 是否正确？
-> Root Signature 的 b0 与 HLSL 是否匹配？
-> CB 是否在 Fence 完成前被 CPU 覆盖？
```

这比只盯着 shader 更有效，因为很多 D3D12 错误发生在 shader 执行之前的资源状态或提交阶段。

---

## 7. 动手验证

在 PowerShell 中运行：

```powershell
Set-Location C:\xf\Cuda\accelerated-computing-hub\learning\sandbox
.\build.ps1 d3d12\d3d12_mesh_input_layout.cu -NoRun
.\d3d12\d3d12_mesh_input_layout.exe --frames 180 --no-vsync
```

验收重点：

- 输出包含 `selected D3D12 adapter: NVIDIA GeForce RTX 5070`。
- 输出包含 `created 2 per-frame CBVs: element size=256 bytes, alignment=256`。
- 输出包含 `D3D12 R.3 CPU MVP + CBV: PASS`。
- `frame-resource CPU waits` 只统计实际因复用资源而阻塞的次数；它可以是 0，也可以是正数，受 vsync、GPU 负载和系统调度影响，不能预先硬编码。

再运行：

```powershell
.\d3d12\d3d12_mesh_input_layout.exe --frames 2 --no-vsync
```

这会让你把两套 `FrameResources` 各提交一次；第三次复用的逻辑不会发生，因为程序在 2 帧后退出，但退出时 `flush_gpu` 仍会等待队列尾部的工作。将 `--frames` 设为 0 表示持续运行，按 ESC 触发消息泵退出，不要在自动化测试中忘记终止窗口。

### 7.1 建议的观察实验

只在开启 D3D12 Debug Layer 的调试分支中做以下实验，实验后恢复：

- 把 `SetDescriptorHeaps` 暂时移到 `SetGraphicsRootDescriptorTable` 之后，观察 heap 未绑定/descriptor table 无效的诊断。
- 把第一条 barrier 删除，观察 RTV 使用 `PRESENT` 资源的诊断。
- 把 `wait_until_frame_is_reusable` 暂时移到 `command_allocator->Reset` 之后，观察 allocator 仍在 GPU 使用时 Reset 的诊断。

这三个实验分别对应三类不同问题：descriptor 绑定前置条件、GPU Resource State、CPU/GPU 生命周期。不要把“某次运行没有立刻崩”当成它们合法；没有 Debug Layer 时，未定义行为可能只是暂时没有显现。

---

## 8. 小结

本节的主线不是记住 28 个函数，而是知道每个函数把什么东西推进到哪条时间线：

- 消息泵决定窗口是否还活着。
- `GetCurrentBackBufferIndex` 决定本轮资源集合。
- Fence 查询/等待决定 CPU 是否能安全复用 allocator、CB 和 Back Buffer。
- Reset/绑定/Barrier/Draw 只是在 CPU 侧构造 command list。
- Close 结束录制，Execute 才提交到 Queue。
- Present 请求 DXGI 呈现，不能替代 `RENDER_TARGET -> PRESENT`。
- Queue `Signal` 给提交排队一个 GPU 时间线值，CPU 只在未来复用资源或退出时等待。

掌握这条链，后续加入 DSV、Texture/SRV、实例化、Copy/Compute Queue 和 CUDA interop 时，新增的只是资源种类和依赖关系，帧循环的骨架仍然相同。

## 自测题

1. `SetEventOnCompletion` 和 `WaitForSingleObject` 哪一个会阻塞 CPU？为什么两个都需要？
2. `Close` 之后为什么还要 `ExecuteCommandLists`？为什么 `Present` 不能代替 Execute？
3. `ResourceBarrier` 已经把 Back Buffer 转成 `PRESENT`，为什么仍然需要 `Queue::Signal` 和退出时的 `flush_gpu`？

### 答案核对

1. `SetEventOnCompletion` 只登记“Fence 达到值时设置 event”，不阻塞；`WaitForSingleObject` 才让 CPU 睡眠。前者把 GPU 时间线连接到 Win32 event，后者才实际等待，且只有目标值未完成时调用。
2. `Close` 只把列表从 recording 变成 closed；`ExecuteCommandLists` 才把 closed list 放入 queue。`Present` 只向 DXGI 发起呈现请求，不会寻找或提交你的 command list。若跳过 Execute 而直接 Present，本帧的 barrier、clear 和 draw 都没有进入 Direct Queue，因而不能构成当前帧的合法渲染结果。
3. Barrier 只描述 GPU 对 Back Buffer 的使用状态，不表示 GPU 已执行完，也不保护 allocator/CB 的生命周期。Queue `Signal` 在提交尾部建立完成标记，未来复用或退出时通过 Fence 等待，才能知道 GPU 不再引用这些对象。

## 官方资料与本机声明

- [Direct3D 12 编程指南](https://learn.microsoft.com/en-us/windows/win32/direct3d12/directx-12-programming-guide)
- [资源屏障与状态](https://learn.microsoft.com/en-us/windows/win32/direct3d12/using-resource-barriers-to-synchronize-resource-states-in-direct3d-12)
- [命令队列与命令列表](https://learn.microsoft.com/en-us/windows/win32/direct3d12/command-queues-and-command-lists)
- [Fence 与多引擎同步](https://learn.microsoft.com/en-us/windows/win32/direct3d12/user-mode-heap-synchronization)
- [Swap Chain](https://learn.microsoft.com/en-us/windows/win32/direct3d12/swap-chains)
- [描述符和描述符堆](https://learn.microsoft.com/en-us/windows/win32/direct3d12/descriptor-heaps)
- [本机 Windows SDK `d3d12.h`](C:/Program%20Files%20%28x86%29/Windows%20Kits/10/Include/10.0.26100.0/um/d3d12.h)

本机头文件中核对的接口包括 `ID3D12CommandAllocator::Reset`、`ID3D12GraphicsCommandList::Reset/Close/ResourceBarrier/OMSetRenderTargets/ClearRenderTargetView/RSSetViewports/RSSetScissorRects/SetGraphicsRootSignature/SetDescriptorHeaps/SetGraphicsRootDescriptorTable/IASetPrimitiveTopology/IASetVertexBuffers/IASetIndexBuffer/DrawIndexedInstanced`、`ID3D12CommandQueue::ExecuteCommandLists/Signal`、`ID3D12Fence::GetCompletedValue/SetEventOnCompletion`、`IDXGISwapChain::Present` 和 `IDXGISwapChain3::GetCurrentBackBufferIndex`。
