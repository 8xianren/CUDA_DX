# R.3：CPU 侧 Model/View/Projection、CBV 与 256-byte 对齐

## 一句话目标

在真实 Vertex/Index Buffer 基础上加入 CPU 构造的 Model/View/Projection 矩阵，通过每帧 Constant Buffer View 传给 Vertex Shader，让模型从 Local Space 正确变换到 Clip Space。

代码：

- `learning/sandbox/d3d12/d3d12_mesh_input_layout.cu`
- `learning/sandbox/d3d12/d3d12_mesh_input_layout.hlsl`

这仍是累积式 demo：R.1 的 Input Layout 和 R.2 的 Index Buffer 保留；本节把原先“顶点已经在 Clip/NDC”替换为真实的 CPU 矩阵路径。

## 1. 四个对象不要混淆

```text
Constant Buffer Resource
    真正拥有 Upload Heap 内存，CPU 可以 Map，GPU 可以读取

Constant Buffer View (CBV)
    一小段描述：从哪个 GPU 地址读取多少字节

Descriptor Heap
    保存 CBV 描述符的数组；shader-visible heap 允许 GPU 查表

Root Signature
    规定 shader 可以通过哪个 root parameter 访问哪个寄存器/descriptor table
```

Root Signature 不保存矩阵，CBV 也不拥有 Resource，Descriptor Heap 也不是显存数据本身。它们是“接口规则、视图、视图容器、真正资源”四个不同层次。

## 2. `D3D12_DESCRIPTOR_RANGE` 与 b0

本节在 Root Signature 中创建一个 CBV range：

```cpp
D3D12_DESCRIPTOR_RANGE cbv_range{};
cbv_range.RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_CBV;
cbv_range.NumDescriptors = 1;
cbv_range.BaseShaderRegister = 0;
cbv_range.RegisterSpace = 0;
cbv_range.OffsetInDescriptorsFromTableStart = 0;
```

含义：

| 字段 | 本例 | 含义 |
|---|---:|---|
| `RangeType` | `CBV` | 这个 descriptor range 保存 Constant Buffer View，而不是 SRV/UAV。 |
| `NumDescriptors` | `1` | 连续覆盖 1 个 descriptor。 |
| `BaseShaderRegister` | `0` | 对应 HLSL `register(b0)`。它是 shader register 编号，不是 descriptor heap 下标。 |
| `RegisterSpace` | `0` | 对应 HLSL 默认的 `space0`；使用多个资源命名空间时可以区分相同寄存器编号。 |
| `OffsetInDescriptorsFromTableStart` | `0` | 该 range 在 root table 中从第 0 个 descriptor 开始。 |

然后把 range 放进一个 root parameter：

```cpp
root_parameter.ParameterType =
    D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
root_parameter.DescriptorTable.NumDescriptorRanges = 1;
root_parameter.DescriptorTable.pDescriptorRanges = &cbv_range;
root_parameter.ShaderVisibility = D3D12_SHADER_VISIBILITY_VERTEX;
```

这里的 `pDescriptorRanges` 只是序列化 `D3D12_ROOT_SIGNATURE_DESC` 时的 CPU 指针。调用 `D3D12SerializeRootSignature` 后，Root Signature 对象会保存编译后的布局；不能把它误认为运行时指向 `cbv_range` 局部变量。

## 3. `D3D12_DESCRIPTOR_HEAP_DESC` 和 shader-visible heap

CBV 必须存放在可供 GPU 访问的 descriptor heap：

```cpp
D3D12_DESCRIPTOR_HEAP_DESC heap_description{};
heap_description.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
heap_description.NumDescriptors = kBackBufferCount;
heap_description.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
```

字段含义：

- `Type`：CBV、SRV、UAV 共用一种 heap 类型；Sampler 是另一种 heap 类型。
- `NumDescriptors`：本例双缓冲，所以创建 2 个 CBV，分别给 frame 0 和 frame 1。
- `Flags`：`SHADER_VISIBLE` 才能被 `SetGraphicsRootDescriptorTable` 使用。RTV/DSV heap 通常是 `NONE`，因为它们由 CPU 句柄绑定到 OM/DS 阶段。

录制命令时必须先绑定 heap：

```cpp
ID3D12DescriptorHeap* heaps[] = {renderer.cbv_heap.Get()};
command_list->SetDescriptorHeaps(1, heaps);
command_list->SetGraphicsRootDescriptorTable(0, frame.cbv_gpu);
```

`SetGraphicsRootDescriptorTable` 只接受 GPU descriptor handle；它不会自动绑定 heap。漏掉 `SetDescriptorHeaps` 会使 root table 没有合法的当前 shader-visible heap，Debug Layer 应当报告错误；在本机未开启 Debug Layer 的早期 demo 中，这个遗漏曾表现为驱动访问冲突。这个顺序是必须记住的 API 前置条件。

## 4. `D3D12_CONSTANT_BUFFER_VIEW_DESC`

结构体：

```cpp
typedef struct D3D12_CONSTANT_BUFFER_VIEW_DESC {
    D3D12_GPU_VIRTUAL_ADDRESS BufferLocation;
    UINT SizeInBytes;
} D3D12_CONSTANT_BUFFER_VIEW_DESC;
```

本例：

```cpp
cbv_description.BufferLocation =
    frame.constant_buffer->GetGPUVirtualAddress();
cbv_description.SizeInBytes = sizeof(ObjectConstants); // 256
device->CreateConstantBufferView(&cbv_description, cpu_descriptor);
```

- `BufferLocation`：常量数据起始 GPU 虚拟地址，必须满足 CBV 地址对齐要求。
- `SizeInBytes`：shader 可读取的字节数，必须是 256 的倍数；这里一个 CBV 正好包含一个 256-byte 单元。

`CreateConstantBufferView` 的第二个参数是 CPU descriptor handle，表示把这个 CBV 描述写到 heap 的哪个槽位。之后 shader 使用的是 descriptor table 中的 GPU handle，而不是 CPU handle。

## 5. 为什么是 256 字节

D3D12 的常量缓冲数据放置对齐要求是：

```text
D3D12_CONSTANT_BUFFER_DATA_PLACEMENT_ALIGNMENT = 256
```

矩阵本身：

```text
4 x 4 x float = 16 x 4 = 64 bytes
```

但 CBV 单元必须按 256 字节描述，所以代码使用：

```cpp
struct alignas(256) ObjectConstants {
    XMFLOAT4X4 world_view_projection; // 64 bytes
    uint8_t padding[192];             // 补到 256
};
```

如果一个 Upload Resource 放多个对象常量，地址应该是：

```text
object 0: base + 0 * 256
object 1: base + 1 * 256
object 2: base + 2 * 256
```

不能用 64 字节作为下一个对象的起点。当前 demo 为了让同步关系清楚，每个 Back Buffer 单独创建一个 256-byte resource。

## 6. 为什么每个 Back Buffer 都要自己的常量资源

错误方案：

```text
一个 Constant Buffer
CPU 每帧写新矩阵
GPU 可能还在执行上一帧的 VS
```

CPU 覆盖的不是“上一份已经完成的数据”，而可能是 GPU 尚未读取的内存，结果是数据竞争和画面抖动。

本节方案：

```text
frame 0 -> Constant Buffer 0 -> CBV 0
frame 1 -> Constant Buffer 1 -> CBV 1
```

只有当 frame 的 Fence 完成，CPU 才能重写该 frame 的 mapped 地址。这与 Command Allocator 的复用保护使用同一个 frame fence。这里没有把 CPU wait 隐藏掉：确实可能因为 CPU 超过 GPU 而等待，但等待保护的是帧资源生命周期，而不是每帧强行同步 CUDA/D3D12。

Upload Heap 常量资源创建为 `GENERIC_READ`，CPU 持久映射后写入；它不需要因为每次 CPU 写矩阵而做 D3D12 Resource Barrier。CPU/GPU 不能同时读写同一地址的约束仍然必须由 Fence 解决。

## 7. CPU 构造 Model/View/Projection

本节使用行向量约定：

```text
p_clip = p_local * Model * View * Projection
```

代码：

```cpp
XMMATRIX world = XMMatrixRotationY(angle) *
                 XMMatrixRotationX(angle * 0.45f);
XMMATRIX view = XMMatrixLookAtLH(eye, target, up);
XMMATRIX projection = XMMatrixPerspectiveFovLH(
    XM_PIDIV4, aspect, 0.1f, 100.0f);
XMMATRIX wvp = world * view * projection;
```

### Model / World

把网格从 Local Space 变到 World Space。这里用旋转矩阵让方形每帧转动。

### View

`XMMatrixLookAtLH(eye, target, up)` 创建左手坐标系观察矩阵：

- `eye`：相机位置 `(0, 0, -2.8)`。
- `target`：相机看向 `(0, 0, 0)`。
- `up`：相机上方向 `(0, 1, 0)`。

左手约定下，相机朝 +Z 方向看；D3D 的 NDC 深度范围是 `[0, 1]`。

### Projection

`XMMatrixPerspectiveFovLH(fov, aspect, nearZ, farZ)` 参数：

- `fov`：垂直视场角，这里 45 度。
- `aspect`：宽/高，这里 `1280 / 720`。
- `nearZ`：近裁剪面 0.1。
- `farZ`：远裁剪面 100。

透视投影之后，GPU 会进行齐次除法：

```text
NDC.x = Clip.x / Clip.w
NDC.y = Clip.y / Clip.w
NDC.z = Clip.z / Clip.w
```

因此 `w` 不是可随便丢掉的第四个数；它决定透视缩放和裁剪判断。

## 8. CPU 与 HLSL 的矩阵内存约定

HLSL：

```hlsl
cbuffer ObjectConstants : register(b0)
{
    row_major float4x4 gWorldViewProjection;
};

output.clipPosition = mul(
    float4(input.position, 1.0f),
    gWorldViewProjection);
```

本节明确选择：

```text
数学方向：行向量 p * M
CPU 矩阵：DirectXMath 的 world * view * projection
HLSL 存储：row_major
上传：不转置，直接 XMStoreFloat4x4
```

这里必须区分两件事：

1. 乘法方向是数学/约定问题：`p*M` 与 `M*p` 是两套一致但不同的约定。
2. row-major/column-major 是内存布局问题：矩阵元素怎样排列在 Constant Buffer 中。

“看到 `mul` 就无条件转置”是不严谨的做法。只要 CPU 数学约定、HLSL `mul` 方向和 HLSL matrix storage layout 三者一致，就可以不转置；本节用 `row_major` 直接验证这一组合。

## 9. 正确的帧流程

此前这里仅列了 14 行调用顺序，缺少 CPU、Command List、GPU Queue 与 Fence
四条时间线，也没有解释资源状态、资源生命周期和每个参数。这不足以用来学习
D3D12，现已拆成独立补课：

- [`R.3-完整逐步帧流程.md`](R.3-完整逐步帧流程.md)

阅读时先牢牢记住六个边界：

```text
Reset                 不是执行
Close                 不是提交
ExecuteCommandLists   才把命令交给 Queue
Present               不替代 PRESENT 状态转换
Queue::Signal         不会让 CPU 等待
Fence 完成            才允许复用受该 Fence 保护的帧资源
```

另外，本 demo 的 PSO 是通过
`command_list->Reset(frame.command_allocator.Get(), renderer.pipeline_state.Get())`
的第二个参数设置的，并没有在帧内调用 `SetPipelineState`。旧版清单把两种合法
写法混写在一起，这里一并纠正。

## 10. 实测

```powershell
Set-Location C:\xf\Cuda\accelerated-computing-hub\learning\sandbox
.\build.ps1 d3d12\d3d12_mesh_input_layout.cu -NoRun
.\d3d12\d3d12_mesh_input_layout.exe --frames 180 --no-vsync
```

本机 RTX 5070 / `sm_120` 输出：

```text
created 2 per-frame CBVs: element size=256 bytes, alignment=256
CPU origin clip=(0.0000, 0.0000, 2.7027, 2.8000), NDC=(0.0000, 0.0000, 0.9653)
rendered frames: 180
D3D12 R.3 CPU MVP + CBV: PASS
```

原点落在 NDC 中心 `(0,0)`，深度约 `0.9653`，说明 CPU 侧矩阵链和投影除法产生了可复核结果；窗口中的网格同时持续旋转。

## 当前简化与后续位置

- 当前矩阵只包含一个对象常量；相机常量与对象常量拆分会在渲染器架构阶段处理。
- 窗口尺寸仍固定，resize 后重建 projection、viewport、scissor 和深度资源会在 R.4/R.7 处理。
- 当前没有 Depth-Stencil；R.4 加入 DSV 和深度测试。
- 当前仍使用 HLSL `row_major`；后续会对照默认 column-major + CPU transpose，实测两种组合的等价条件。

## 小结

R.3 把网格从“已经写在屏幕坐标中”推进到了真正的引擎式流程：CPU 构造矩阵，上传到按帧隔离的 CBV，命令列表绑定 descriptor heap 和 root table，Vertex Shader 只执行 `Local * Model * View * Projection`。

## 自测题

1. 为什么 `D3D12_CONSTANT_BUFFER_VIEW_DESC::SizeInBytes` 不能填 64，而要填 256？
2. 为什么 `SetGraphicsRootDescriptorTable` 前必须调用 `SetDescriptorHeaps`？
3. 如果使用 `mul(position, matrix)` 和 `row_major`，CPU 为什么可以直接上传 `world * view * projection`，不需要 `XMMatrixTranspose`？
4. 为什么单个全局 Constant Buffer 在多帧渲染中可能产生数据竞争？
