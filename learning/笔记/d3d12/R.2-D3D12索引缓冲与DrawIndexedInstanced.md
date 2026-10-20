# R.2：索引缓冲与 `DrawIndexedInstanced`

## 一句话目标

使用 Index Buffer 描述三角形拓扑，让两个三角形复用四个 Vertex，并理解 `IASetIndexBuffer`、`D3D12_INDEX_BUFFER_VIEW` 和 `DrawIndexedInstanced` 的每个参数。

代码沿用 R.1 的窗口、设备、PSO 和 Input Layout：

- `learning/sandbox/d3d12/r01-r08-mesh/d3d12_mesh_input_layout.cu`
- `learning/sandbox/d3d12/r01-r08-mesh/d3d12_mesh_input_layout.hlsl`

当前源文件是累积式 demo：R.1 的真实 Vertex Buffer 和 Input Layout 保留，绘制路径增加 Index Buffer 后变为 R.2。

## 1. 为什么需要 Index Buffer

一个方形由两个三角形组成：

```text
0 -------- 1
|        / |
|      /   |
|    /     |
3 -------- 2
```

使用 `TRIANGLELIST` 时，每三个索引组成一个三角形：

```text
triangle 0: 0, 1, 2
triangle 1: 0, 2, 3
```

两个三角形共享 Vertex 0 和 Vertex 2，因此：

```text
Vertex Buffer: 4 个 Vertex
Index Buffer : 6 个 index
```

不用索引时必须把共享的顶点复制到 Vertex Buffer，变成 6 个 Vertex。索引并不一定让 GPU 总字节数更小，尤其是顶点很小或索引很大时；它的核心价值是表达拓扑和复用顶点属性，实际收益要看网格和缓存局部性。

## 2. `D3D12_INDEX_BUFFER_VIEW`

Windows SDK 中的结构体是：

```cpp
typedef struct D3D12_INDEX_BUFFER_VIEW {
    D3D12_GPU_VIRTUAL_ADDRESS BufferLocation;
    UINT SizeInBytes;
    DXGI_FORMAT Format;
} D3D12_INDEX_BUFFER_VIEW;
```

### `BufferLocation`

Index Buffer Resource 的 GPU 虚拟地址：

```cpp
index_view.BufferLocation = index_buffer->GetGPUVirtualAddress();
```

它是地址，不是 CPU 指针；View 也不拥有 Resource。

### `SizeInBytes`

Index Buffer View 描述的总字节范围：

```cpp
6 * sizeof(uint16_t) = 12
```

它不是索引数量。索引数量需要用：

```text
SizeInBytes / bytes_per_index
```

### `Format`

格式决定一个 index 占多少字节以及如何解释：

```text
DXGI_FORMAT_R16_UINT -> 16-bit unsigned integer -> 2 bytes/index
DXGI_FORMAT_R32_UINT -> 32-bit unsigned integer -> 4 bytes/index
```

本例的最大索引是 3，所以使用 `uint16_t` 与 `R16_UINT`。这不是按“模型总顶点数”猜，而是由所有可引用顶点编号的最大范围决定：如果任何被引用的顶点编号大于 65535，应使用 `uint32_t`/`R32_UINT`。格式必须和 CPU 实际写入的字节编码一致。

和 Vertex Buffer 不同，`D3D12_INDEX_BUFFER_VIEW` 没有 `StrideInBytes` 字段；索引步长完全由 `Format` 决定。

## 3. `IASetIndexBuffer`

接口签名是：

```cpp
void IASetIndexBuffer(
    const D3D12_INDEX_BUFFER_VIEW* pView);
```

本例：

```cpp
command_list->IASetIndexBuffer(&renderer.index_buffer_view);
```

- `pView`：指向一个 Index Buffer View；传 `nullptr` 表示不绑定索引缓冲。
- Index Buffer 没有 `InputSlot`；它是 IA 的独立绑定点，不属于 Vertex Buffer 的 32 个输入 slot。
- `IASetIndexBuffer` 只绑定 View，不复制或拥有 Resource；Resource 必须活到 GPU 完成绘制。

## 4. `DrawIndexedInstanced` 的真实参数

接口等价于：

```cpp
void DrawIndexedInstanced(
    UINT IndexCountPerInstance,
    UINT InstanceCount,
    UINT StartIndexLocation,
    INT  BaseVertexLocation,
    UINT StartInstanceLocation);
```

本例：

```cpp
command_list->DrawIndexedInstanced(6, 1, 0, 0, 0);
```

| 参数 | 本例值 | 含义 |
|---|---:|---|
| `IndexCountPerInstance` | `6` | 每个实例从 Index Buffer 读取 6 个索引，也就是两个三角形。 |
| `InstanceCount` | `1` | 绘制一个实例。R.6 才会绘制多个实例。 |
| `StartIndexLocation` | `0` | 第一个索引在 Index Buffer 中的元素编号，不是字节偏移；实际字节地址为 `BufferLocation + StartIndexLocation * indexSize`。 |
| `BaseVertexLocation` | `0` | 加到每个索引值上的有符号顶点基址；最终顶点号是 `index + BaseVertexLocation`。可用于把一个大 Vertex Buffer 的子网格放在不同基址。 |
| `StartInstanceLocation` | `0` | 加到 `SV_InstanceID` 的起始值，供实例数据寻址。 |

### 具体索引寻址

对于本例的 `R16_UINT`：

```text
index element 0 -> IB + 0 * 2 -> value 0 -> VB vertex 0
index element 1 -> IB + 1 * 2 -> value 1 -> VB vertex 1
index element 2 -> IB + 2 * 2 -> value 2 -> VB vertex 2
index element 3 -> IB + 3 * 2 -> value 0 -> VB vertex 0
index element 4 -> IB + 4 * 2 -> value 2 -> VB vertex 2
index element 5 -> IB + 5 * 2 -> value 3 -> VB vertex 3
```

如果 `BaseVertexLocation = 10`，同样的索引会读取 Vertex 10、11、12、10、12、13。它不会改写 Index Buffer，也不会改变 Input Layout。

## 5. 资源状态和上传顺序

Vertex Buffer 和 Index Buffer 是两个独立的 Resource：

```text
创建：COPY_DEST
CopyBufferRegion
barrier:
  Vertex -> VERTEX_AND_CONSTANT_BUFFER
  Index  -> INDEX_BUFFER
绘制：IA 读取
```

代码一次录制两条 Copy 和两条 Transition，但这不代表 GPU 自动并行；它们在同一条 DIRECT queue 上按命令顺序执行。初始化 Fence 完成后，临时 Upload Buffer 才能析构。

Resource State 表示 D3D12 对下一种访问用途的要求；它不等于跨 API 的生产者所有权。CUDA 互操作仍需 External Fence/信号等待。

## 6. Input Layout 和 Index Buffer 的职责边界

这两个机制经常被混淆：

```text
Index Buffer
    决定“当前三角形使用哪个 Vertex 编号”

Input Layout
    决定“从被选中的 Vertex 字节中如何取 POSITION/COLOR 等属性”
```

Index Buffer 不知道 `POSITION` 在 offset 0 还是 offset 12；Input Layout 也不关心三角形是 `0,1,2` 还是 `0,2,3`。

## 7. 常见错误

- CPU 用 `uint16_t` 写数据，却把 View.Format 写成 `R32_UINT`：GPU 会按 4 字节跨步读取，索引序列立即错位。
- `SizeInBytes` 写成索引数量 6，而不是字节数 12：View 描述范围错误，Debug Layer 可能报告问题。
- `StartIndexLocation` 当成字节偏移：D3D12 API 这里要求的是索引元素编号。
- `BaseVertexLocation` 使用无符号类型：它在 API 中是 `INT`，允许子网格基址为负值（前提是最终顶点号仍合法）。
- 只修改 Index Buffer 状态，却忘记 Vertex Buffer 仍处于 `COPY_DEST`：IA 读取状态不完整。
- 认为索引一定更快：索引引入额外读取和顶点缓存行为，是否收益要用实际网格和 profiling 验证。

## 8. 编译、运行与验收

```powershell
Set-Location C:\xf\Cuda\accelerated-computing-hub\learning\sandbox
.\build.ps1 d3d12\r01-r08-mesh\d3d12_mesh_input_layout.cu -NoRun
.\d3d12\r01-r08-mesh\d3d12_mesh_input_layout.exe --frames 180 --no-vsync
```

预期关键输出：

```text
uploaded vertex buffer: 4 vertices, 112 bytes, stride=28
uploaded index buffer: 6 indices, 12 bytes, format=R16_UINT
D3D12 R.2 indexed mesh: PASS
```

画面应是一个四边形，四个角的颜色由 Pixel Shader 插值。把索引改成 `{0, 1, 3, 1, 2, 3}` 可以改变三角形绕序；把其中一个索引改成 4 可用 Debug Layer 验证越界输入不会被当成有效模型数据。

## 小结

R.2 的核心是把“顶点属性”和“拓扑编号”分离：Vertex Buffer 存属性，Index Buffer 存编号，Input Assembler 先按索引选择 Vertex，再按 Input Layout 解码属性，最后进入 VS。
