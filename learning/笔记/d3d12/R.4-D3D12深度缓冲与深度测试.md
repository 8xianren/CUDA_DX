# R.4 D3D12 深度缓冲与深度测试

## 1. 本节目标

在 R.3 的网格渲染器上加入一张深度纹理，让重叠的 3D 三角形按照前后距离遮挡。本节最重要的是区分五个对象：

1. `ID3D12Resource`：真正保存深度样本的资源本体。
2. `D3D12_DEPTH_STENCIL_VIEW_DESC`：创建深度视图时传给设备的描述结构体。
3. 深度描述符：设备根据资源和描述结构体写入 DSV Heap 槽位的一份访问记录。
4. DSV CPU 句柄：定位 DSV Heap 中那份深度描述符的句柄。
5. `D3D12_DEPTH_STENCIL_DESC`：PSO 中规定深度如何比较、是否写回的固定管线状态。

这五者不是同一个东西。本节使用 `DXGI_FORMAT_D32_FLOAT`，只启用深度、不启用模板；窗口尺寸仍固定为 1280x720。窗口重建、MSAA、模板、只读深度和反向 Z 留到后续小节。

## 2. 先固定术语

### 2.1 资源本体

`ID3D12Resource` 是 GPU 资源对象。深度资源是一张二维纹理，每个像素保存一个深度样本。它才真正拥有这些数据；视图、描述结构体、描述符和句柄都不拥有像素。

### 2.2 视图、描述结构体、描述符

“视图”表示把一份资源按哪种方式交给某个管线单元使用。对于深度资源，这类视图叫 DSV（Depth-Stencil View，深度模板视图）。

`D3D12_DEPTH_STENCIL_VIEW_DESC` 是 CPU 侧 C++ 结构体，告诉设备格式、视图维度、数组切片和 mip 等信息：

```cpp
device->CreateDepthStencilView(
    depthResource,
    &viewDescription,
    dsvCpuHandle);
```

设备把一份内部的“深度访问记录”写入 DSV Heap 的某个槽位。这份写入 Heap 的记录叫深度描述符；`dsvCpuHandle` 只是定位该槽位的 CPU 句柄。

关系是：

```text
资源本体 + 视图描述结构体 + Heap 槽位
    -> 设备写入深度描述符
    -> CPU 句柄定位这份深度描述符
```

DSV 不是深度资源，DSV 不复制深度数据。为避免歧义，本课程后面说“DSV”时指深度模板视图；说“深度描述符”时指 Heap 槽位里的实际记录。

### 2.3 DSV Heap

DSV Heap 是实际保存深度描述符的槽位数组：

```text
DSV Heap（CPU 可见）
┌──────────────┬──────────────┐
│ slot 0       │ slot 1       │
│ 深度描述符    │ 另一个深度视图 │
└──────────────┴──────────────┘
```

DSV Heap 不需要 `SHADER_VISIBLE`，也不传给 `SetDescriptorHeaps`。本节的深度目标由 Output Merger 使用，不是 Shader 通过根签名读取的资源。

## 3. 深度测试发生在哪里

顶点着色器输出的是裁剪空间位置：

```hlsl
output.position = mul(input.position, gWorldViewProjection);
```

这还不是最终屏幕深度。后续过程是：

```text
裁剪
    -> 透视除法：x/w、y/w、z/w
    -> Viewport 把 NDC 深度映射到 MinDepth..MaxDepth
    -> 光栅化产生 fragment
    -> Output Merger 对 fragment 做深度比较
```

D3D12 常规投影的 NDC 深度是 `[0, 1]`。当前 Viewport 也是 `[0, 1]`，所以 fragment 的 `SV_Position.z` 可以作为比较值。

常规 `LESS` 配置下：

```text
新的深度 < 深度资源已有值
    -> 通过；写颜色；允许写入时更新深度

新的深度 >= 深度资源已有值
    -> 失败；丢弃 fragment，不写颜色
```

注意三个独立概念：

```text
DepthClipEnable  几何体是否在裁剪阶段被裁掉
深度测试         fragment 是否与已有样本比较并通过
深度写入         通过后是否更新深度资源
```

## 4. 启动阶段创建资源和深度描述符

### 4.1 创建深度资源

```cpp
D3D12_RESOURCE_DESC resourceDescription{};
resourceDescription.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
resourceDescription.Width = kWindowWidth;
resourceDescription.Height = kWindowHeight;
resourceDescription.DepthOrArraySize = 1;
resourceDescription.MipLevels = 1;
resourceDescription.Format = DXGI_FORMAT_D32_FLOAT;
resourceDescription.SampleDesc.Count = 1;
resourceDescription.SampleDesc.Quality = 0;
resourceDescription.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
resourceDescription.Flags = D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL;
```

关键字段：`TEXTURE2D` 表示二维样本，`Width/Height` 是深度目标尺寸，`D32_FLOAT` 是每样本 32 位浮点深度，`SampleDesc.Count=1` 表示没有 MSAA，`ALLOW_DEPTH_STENCIL` 允许深度单元使用它，`UNKNOWN` 把纹理布局交给驱动。

用 Default Heap 创建，并让初始状态直接适合深度写入：

```cpp
D3D12_HEAP_PROPERTIES heapProperties =
    make_heap_properties(D3D12_HEAP_TYPE_DEFAULT);

D3D12_CLEAR_VALUE clearValue{};
clearValue.Format = DXGI_FORMAT_D32_FLOAT;
clearValue.DepthStencil.Depth = 1.0f;
clearValue.DepthStencil.Stencil = 0;

HR_CHECK(device->CreateCommittedResource(
    &heapProperties,
    D3D12_HEAP_FLAG_NONE,
    &resourceDescription,
    D3D12_RESOURCE_STATE_DEPTH_WRITE,
    &clearValue,
    IID_PPV_ARGS(&renderer.depthResource)));
```

`clearValue` 只是创建资源时给驱动的优化清除值，不代表已经执行了清除。每个渲染 Pass 仍需记录清除命令。

### 4.2 创建 DSV Heap 和深度描述符

```cpp
D3D12_DESCRIPTOR_HEAP_DESC heapDescription{};
heapDescription.Type = D3D12_DESCRIPTOR_HEAP_TYPE_DSV;
heapDescription.NumDescriptors = 1;
heapDescription.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_NONE;

HR_CHECK(device->CreateDescriptorHeap(
    &heapDescription,
    IID_PPV_ARGS(&renderer.dsvHeap)));

const D3D12_CPU_DESCRIPTOR_HANDLE dsvCpuHandle =
    renderer.dsvHeap->GetCPUDescriptorHandleForHeapStart();
```

填写视图描述结构体，再让设备把深度描述符写入 Heap 槽位：

```cpp
D3D12_DEPTH_STENCIL_VIEW_DESC viewDescription{};
viewDescription.Format = DXGI_FORMAT_D32_FLOAT;
viewDescription.ViewDimension = D3D12_DSV_DIMENSION_TEXTURE2D;
viewDescription.Flags = D3D12_DSV_FLAG_NONE;
viewDescription.Texture2D.MipSlice = 0;

device->CreateDepthStencilView(
    renderer.depthResource.Get(),
    &viewDescription,
    dsvCpuHandle);

renderer.dsvCpuHandle = dsvCpuHandle;
```

完成后，`renderer.depthResource` 是实际深度纹理，`renderer.dsvHeap` 的 slot 0 保存访问它的深度描述符，`renderer.dsvCpuHandle` 定位该槽位。

## 5. PSO 中的深度状态

PSO 不保存深度样本，它只保存固定管线的比较规则：

```cpp
D3D12_DEPTH_STENCIL_DESC depthState{};
depthState.DepthEnable = TRUE;
depthState.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ALL;
depthState.DepthFunc = D3D12_COMPARISON_FUNC_LESS;
depthState.StencilEnable = FALSE;
depthState.StencilReadMask = D3D12_DEFAULT_STENCIL_READ_MASK;
depthState.StencilWriteMask = D3D12_DEFAULT_STENCIL_WRITE_MASK;

pipelineDescription.DepthStencilState = depthState;
pipelineDescription.DSVFormat = DXGI_FORMAT_D32_FLOAT;
```

字段职责：`DepthEnable` 决定是否比较；`DepthWriteMask` 决定通过后是否写回；`DepthFunc=LESS` 决定新深度必须小于旧深度；`DSVFormat` 是 PSO 预期绑定的深度视图格式，不是句柄，也不是资源转换。

## 6. 每帧绑定和清除

R.3 只绑定颜色目标：

```cpp
commandList->OMSetRenderTargets(
    1, &frame.rtv, FALSE, nullptr);
```

R.4 同时绑定颜色和深度目标：

```cpp
commandList->OMSetRenderTargets(
    1,
    &frame.rtv,
    FALSE,
    &renderer.dsvCpuHandle);
```

这个调用只选择本次 Output Merger 的输出目标，不清除，也不自动转换资源状态。接着记录清除：

```cpp
commandList->ClearRenderTargetView(
    frame.rtv, clearColor, 0, nullptr);

commandList->ClearDepthStencilView(
    renderer.dsvCpuHandle,
    D3D12_CLEAR_FLAG_DEPTH,
    1.0f,
    0,
    0,
    nullptr);
```

第一个参数定位深度描述符；`D3D12_CLEAR_FLAG_DEPTH` 表示只清深度；`1.0f` 是常规 `LESS` 方案的最远初始值；`0` 是本节未使用的模板清除值；最后的 `0/nullptr` 表示清除整个视图。清除仍只是写进命令列表，GPU 在 Execute 后按顺序执行。

## 7. 三个 API 的严格边界

```text
ResourceBarrier
    说明资源在 GPU 上从一种使用状态切到另一种使用状态，并建立访问顺序。

OMSetRenderTargets
    选择当前 Output Merger 要使用的颜色视图和深度视图。

ClearDepthStencilView
    记录一次把深度样本清成指定值的 GPU 命令。
```

所以：绑定深度视图不等于清除深度，清除深度不等于改变资源状态，资源状态也不等于 PSO 的比较规则。

本节深度资源创建时就是 `D3D12_RESOURCE_STATE_DEPTH_WRITE`，绘制后仍用于深度写入，所以单一深度 Pass 不需要每帧额外插入深度状态转换。以后把它作为 Shader 只读输入时，必须在深度写入和 Shader 读取之间记录相应转换。

## 8. 为什么每个 Pass 都清除

常规配置是：近处深度小、远处深度大、比较函数 `LESS`、初始深度 `1.0`。如果上一帧深度不清除，本帧会拿新物体和上一帧留下的几何深度比较；颜色即使清成新颜色，旧深度仍可能拒绝新 fragment，于是出现错误遮挡或物体消失。

深度清除不是 CPU 填数组，而是一条必须排在本 Pass Draw 之前的 GPU 命令。反向 Z 必须同时改变投影矩阵、比较函数和清除值，不能只把 `LESS` 改成 `GREATER`；本节不采用反向 Z。

## 9. 完整帧内位置

```text
等待当前帧 Fence
    -> 更新当前帧常量资源
    -> Reset Command Allocator / Command List
    -> Back Buffer: PRESENT -> RENDER_TARGET
    -> 绑定 RTV + 深度视图
    -> 清除颜色
    -> 清除深度为 1.0
    -> 设置 Viewport / Scissor
    -> 绑定根签名、资源表、VBV、IBV
    -> DrawIndexedInstanced
    -> Back Buffer: RENDER_TARGET -> PRESENT
    -> Close / Execute / Present / Signal
```

深度资源不是交换链 Back Buffer，不需要随 Back Buffer 索引轮换；本节只有一张与窗口尺寸匹配的深度资源。resize 时必须等待 GPU 完成，再销毁并重建它和对应的深度描述符。

## 10. 验收实验

画两个重叠三角形：A 在 `z=0.6`、红色，B 在 `z=0.2`、绿色。分别执行 `Draw A -> Draw B` 和 `Draw B -> Draw A`。开启深度、清除为 1.0、比较函数为 `LESS` 时，两种顺序的重叠区域都应显示 B。关闭深度测试后，重叠区域由后绘制的三角形覆盖。

## 11. 小结

```text
资源本体
    保存每个屏幕位置的深度样本

视图描述结构体
    描述如何把资源交给深度单元

深度描述符
    由设备写入 DSV Heap 槽位的访问记录

DSV CPU 句柄
    定位这个描述符，供清除和 Output Merger 绑定使用

PSO 深度状态
    决定是否比较、如何比较、是否写回
```

必须记住：资源本体不等于深度描述符；视图描述结构体不等于深度资源；DSV CPU 句柄不等于 GPU 深度数据地址；绑定 DSV 不等于清除 DSV；深度资源状态不等于 PSO 深度比较规则。

## 自测题

1. `ID3D12Resource`、`D3D12_DEPTH_STENCIL_VIEW_DESC`、DSV Heap 槽位中的深度描述符、DSV CPU 句柄分别是什么？
2. 为什么 `OMSetRenderTargets` 传入深度 CPU 句柄后，仍必须单独调用 `ClearDepthStencilView`？
3. `D3D12_RESOURCE_STATE_DEPTH_WRITE` 和 `DepthFunc=LESS` 分别解决什么问题？
4. 为什么常规 `LESS` 方案将每个 Pass 的初始深度清为 `1.0f`？

## 官方参考

- [Depth and stencil testing](https://learn.microsoft.com/windows/win32/direct3d12/depth-stencil)
- [CreateDepthStencilView](https://learn.microsoft.com/windows/win32/api/d3d12/nf-d3d12-id3d12device-createdepthstencilview)
- [ClearDepthStencilView](https://learn.microsoft.com/windows/win32/api/d3d12/nf-d3d12-id3d12graphicscommandlist-cleardepthstencilview)
- [OMSetRenderTargets](https://learn.microsoft.com/windows/win32/api/d3d12/nf-d3d12-id3d12graphicscommandlist-omsetrendertargets)
- [D3D12 resource states](https://learn.microsoft.com/windows/win32/api/d3d12/ne-d3d12-d3d12_resource_states)
