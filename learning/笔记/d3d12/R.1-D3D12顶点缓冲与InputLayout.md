# R.1：D3D12 顶点缓冲与 Input Layout

## 一句话目标

把一个真正的 CPU 网格顶点数组上传到 GPU，使用 D3D12 Input Assembler 和 HLSL 顶点输入绘制，而不是在 shader 中用 `SV_VertexID` 手写几何。

示例代码：

- `learning/sandbox/d3d12/r01-r08-mesh/d3d12_mesh_input_layout.cu`
- `learning/sandbox/d3d12/r01-r08-mesh/d3d12_mesh_input_layout.hlsl`

## 1. 和粒子 demo 的区别

粒子 demo 的路线是：

```text
SV_VertexID + SV_InstanceID -> shader 内生成 quad -> StructuredBuffer/SRV 读粒子
```

这是粒子专用的程序生成几何。R.1 的路线是完整网格渲染器的基础：

```text
CPU Vertex 数组
    -> Upload Heap 暂存
    -> CopyBufferRegion
    -> Default Heap Vertex Buffer
    -> D3D12_VERTEX_BUFFER_VIEW
    -> Input Assembler
    -> HLSL VertexInput
    -> Vertex Shader
```

两者都能最终产生三角形，但数据入口不同。`SV_VertexID` 只告诉 shader 当前调用编号；它不会自动提供位置、颜色或网格拓扑。真实网格的顶点属性必须由 Vertex Buffer 和 Input Layout 定义。

## 2. CPU 顶点内存布局

本节使用：

```cpp
struct Vertex {
    float position[3]; // 12 bytes，偏移 0
    float color[4];    // 16 bytes，偏移 12
};                    // stride = 28 bytes
```

三个顶点连续存储时，GPU 看到的字节区间是：

```text
顶点 0: [0, 28)
顶点 1: [28, 56)
顶点 2: [56, 84)
```

`stride` 是“相邻顶点起点之间的距离”，不是单个属性大小。`COLOR` 的 offset 是 12，因为它紧跟在 position 后面。

## 3. Upload Heap 和 Default Heap

### Upload Heap

Upload Heap 通常用于 CPU 写入的 staging 资源。代码 `Map` 它，把 `std::vector<Vertex>` 的字节复制进去。它的优势是 CPU 可见，代价是它不是最适合 GPU 高频读取的最终资源。

### Default Heap

Default Heap 是最终 GPU Vertex Buffer。它创建时状态是 `COPY_DEST`，因为初始化命令首先要写它；复制完成后通过 Resource Barrier 转换到 `VERTEX_AND_CONSTANT_BUFFER`，之后才允许 Input Assembler 读取。

这里的 Resource State 描述“接下来允许的访问方式”，不等同于 CUDA/D3D12 跨 API 的所有权。跨 API 所有权要到后面的 External Fence 课程再处理。

## 4. Input Layout 如何匹配 HLSL

### 4.1 `D3D12_INPUT_ELEMENT_DESC` 的真实声明

Windows SDK 中的结构体是：

```cpp
typedef struct D3D12_INPUT_ELEMENT_DESC {
    LPCSTR SemanticName;
    UINT SemanticIndex;
    DXGI_FORMAT Format;
    UINT InputSlot;
    UINT AlignedByteOffset;
    D3D12_INPUT_CLASSIFICATION InputSlotClass;
    UINT InstanceDataStepRate;
} D3D12_INPUT_ELEMENT_DESC;
```

每个字段的含义：

| 字段 | 本例值 | 准确含义 |
|---|---:|---|
| `SemanticName` | `"POSITION"` | 编译后 Vertex Shader 输入的语义名称；不是 C++ 成员名。字符串必须以 `\\0` 结尾。 |
| `SemanticIndex` | `0` | 同名语义的编号。`SemanticName="COLOR"`、`SemanticIndex=0` 对应 HLSL 的 `COLOR0`。 |
| `Format` | `R32G32B32_FLOAT` | IA 如何把字节解码成 shader 输入；本例读取 3 个 32-bit 浮点。它不是“这个成员占多少字节”的注释，而是实际的读取格式。 |
| `InputSlot` | `0` | 使用哪个顶点输入流。它必须和命令列表绑定的 slot 相同；D3D12 的 IA 顶点输入 slot 数量由 `D3D12_IA_VERTEX_INPUT_RESOURCE_SLOT_COUNT` 定义，本机 SDK 值为 32。 |
| `AlignedByteOffset` | `0` 或 `12` | 属性相对于“当前顶点起点”的字节偏移。也可以使用 `D3D12_APPEND_ALIGNED_ELEMENT` 让运行时按前一个元素自动接续。 |
| `InputSlotClass` | `PER_VERTEX_DATA` | 地址是否随 VertexID 前进，或随 InstanceID 前进。R.1 每个属性都属于每顶点数据。 |
| `InstanceDataStepRate` | `0` | 对实例流表示每多少个实例推进一个元素；对 `PER_VERTEX_DATA` 必须为 0。R.6 实例化时才会用非零值。 |

因此，第一条规则的地址计算可以写成：

```text
POSITION 地址 = VB[slot 0].BufferLocation
               + (StartVertexLocation + VertexID) * StrideInBytes
               + 0
```

第二条规则只把最后的 `+ 0` 换成 `+ 12`，并按照 `R32G32B32A32_FLOAT` 读取 16 字节。

C++：

```cpp
{"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0,
 D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
{"COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 12,
 D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
```

HLSL：

```hlsl
struct VertexInput {
    float3 position : POSITION;
    float4 color    : COLOR0;
};
```

匹配关系不是按 C++ 成员名匹配，而是按语义名和语义索引匹配：

| C++ Input Layout | HLSL 输入 | 含义 |
|---|---|---|
| `POSITION`, index 0 | `POSITION` | 3 个 32-bit float |
| `COLOR`, index 0 | `COLOR0` | 4 个 32-bit float |

`InputSlot = 0` 要和 `IASetVertexBuffers(0, 1, &view)` 的 slot 对应。`PER_VERTEX_DATA` 表示每读取一个 vertex，地址前进一次 `StrideInBytes`；实例化时才会讲 `PER_INSTANCE_DATA`。

### 4.2 `D3D12_INPUT_LAYOUT_DESC`：数组指针和数组长度

PSO 中的字段类型不是一个单独的 `D3D12_INPUT_ELEMENT_DESC`，而是：

```cpp
typedef struct D3D12_INPUT_LAYOUT_DESC {
    const D3D12_INPUT_ELEMENT_DESC* pInputElementDescs;
    UINT NumElements;
} D3D12_INPUT_LAYOUT_DESC;
```

本例：

```cpp
pipeline_description.InputLayout = {input_elements, 2};
```

- `pInputElementDescs`：指向描述数组的首元素。
- `NumElements`：数组中“属性描述”的数量，这里是 2；它不是顶点数量，也不是 buffer 字节数。

这个指针只需在 `CreateGraphicsPipelineState` 调用期间有效；PSO 创建时会读取这些描述。真正的 Vertex Buffer 资源则必须保持存活到 GPU 完成所有引用它的命令。

### 4.3 `IASetVertexBuffers`：绑定顶点流

接口签名是：

```cpp
void IASetVertexBuffers(
    UINT StartSlot,
    UINT NumViews,
    const D3D12_VERTEX_BUFFER_VIEW* pViews);
```

| 参数 | 本例值 | 含义 |
|---|---:|---|
| `StartSlot` | `0` | `pViews[0]` 要写入的第一个 IA slot。 |
| `NumViews` | `1` | 连续绑定多少个 slot；这里因此只读取 `pViews[0]`。 |
| `pViews` | `&view` | 指向 `NumViews` 个 VBV 的数组。若绑定 slot 0 和 1，应传长度为 2 的数组并把 `StartSlot` 设为 0。 |

调用：

```cpp
renderer.command_list->IASetVertexBuffers(0, 1,
                                           &renderer.vertex_buffer_view);
```

这里的 `0` 是 `StartSlot`，不是 VertexID；`1` 是要绑定的 View 数量；`&view` 是描述数组地址。命令列表录制时会读取 View 的三个数值并记录状态，View 这个 C++ 变量本身不需要一直存在，但它指向的 D3D12 Resource 必须活到 GPU 用完。

如果 Input Layout 写 `InputSlot = 1`，而这里只绑定 slot 0，那么该属性没有对应的输入流，Debug Layer 通常会报告 IA 输入配置问题，结果不能当作有效顶点数据使用。

## 5. `D3D12_VERTEX_BUFFER_VIEW` 三个字段

```cpp
view.BufferLocation = resource->GetGPUVirtualAddress();
view.StrideInBytes = sizeof(Vertex);
view.SizeInBytes = vertex_count * sizeof(Vertex);
```

- `BufferLocation`：资源起始 GPU 虚拟地址。
- `StrideInBytes`：相邻顶点起点距离；这里是 28。
- `SizeInBytes`：允许读取的总字节数；这里是 84。

View 是轻量描述，不拥有资源。`ComPtr<ID3D12Resource>` 仍然负责资源生命周期。

### 5.1 和 `DrawInstanced` 的关系

本例的调用是：

```cpp
DrawInstanced(3, 1, 0, 0);
```

四个参数依次是：

```text
VertexCountPerInstance = 3  // 一个实例读取 3 个顶点
InstanceCount           = 1  // 绘制 1 个实例
StartVertexLocation    = 0  // 加到 VertexID 上的起始顶点
StartInstanceLocation  = 0  // 加到 InstanceID 上的起始实例
```

因此当前顶点属性读取的是：

```text
VertexID 0 -> BufferLocation + 0 * 28 + 属性 offset
VertexID 1 -> BufferLocation + 1 * 28 + 属性 offset
VertexID 2 -> BufferLocation + 2 * 28 + 属性 offset
```

`D3D12_VERTEX_BUFFER_VIEW.SizeInBytes` 不会自动决定画几个顶点；真正的读取数量来自 `DrawInstanced`。View 的大小用于描述可访问范围并帮助调试层检查越界配置。

## 6. 本节暂时为什么没有矩阵

三角形的 position 直接写成 Clip/NDC 范围的坐标：`x/y ∈ [-1, 1]`，VS 只把 `float3` 补成 `float4(position, 1)`。这不是推荐的模型渲染架构，而是为了隔离本节的变量：先证明顶点数据真的经过 Vertex Buffer 和 Input Layout 进入 VS。

完整流程会在 R.3 变成：

```text
Local vertex --CPU 上传的 Model/View/Projection--> Clip position
```

矩阵由 CPU/引擎侧构造和上传，shader 只应用矩阵。

## 7. 编译与运行

在 PowerShell 中：

```powershell
Set-Location C:\xf\Cuda\accelerated-computing-hub\learning\sandbox
.\build.ps1 d3d12\r01-r08-mesh\d3d12_mesh_input_layout.cu --NoRun
.\d3d12\r01-r08-mesh\d3d12_mesh_input_layout.exe --frames 180 --no-vsync
```

预期输出包括：

```text
uploaded mesh vertex buffer: 3 vertices, 84 bytes, stride=28
input layout: POSITION offset=0, COLOR offset=12
D3D12 R.1 mesh input layout: PASS
```

窗口中应看到一个由三个不同颜色顶点插值而成的三角形。把 HLSL 的 `COLOR0` 改成错误语义、把 C++ offset 改成错误值，或把 `StrideInBytes` 改错，都是很好的 Debug Layer/Input Layout 实验。

## 小结

R.1 建立了网格渲染器的第一个真实数据闭环：CPU 结构体的字节布局必须和 Input Layout、HLSL 输入结构、Vertex Buffer View 四者一致。D3D12 不会替你推断 stride、offset 或语义；这些信息由引擎明确声明。

## 自测题

1. `Vertex` 的 `COLOR` offset 为什么是 12，`StrideInBytes` 为什么是 28 而不是 16？
2. 为什么 Default Heap 顶点资源初始化后要从 `COPY_DEST` 转到 `VERTEX_AND_CONSTANT_BUFFER`？
3. 如果 `InputSlot=1`，但命令列表仍调用 `IASetVertexBuffers(0, 1, &view)`，GPU 会从哪里读取数据？
