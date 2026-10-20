# R.6 D3D12 实例化网格、SV_InstanceID 与 StructuredBuffer

## 1. 本节目标

把 R.5.6 的“每个物体一份网格、一次 Draw”收成：**同一份 Vertex/Index Buffer，一次 Draw 画出多个不同变换**。学完应能回答：

1. `DrawIndexedInstanced` 的 `InstanceCount` 和 `StartInstanceLocation` 到底改了什么？
2. `SV_InstanceID` 从哪来？它是不是 Vertex Buffer 里的属性？
3. 每实例 World/颜色为什么走 `StructuredBuffer`，而不是再开一份 256-byte CBV？
4. 更新实例数据时，为什么静态网格资源必须保持不动？

可运行代码：

- `learning/sandbox/d3d12/r01-r08-mesh/d3d12_mesh_input_layout.cu`
- `learning/sandbox/d3d12/r01-r08-mesh/d3d12_mesh_input_layout.hlsl`

官方资料：

- [DrawIndexedInstanced](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12graphicscommandlist-drawindexedinstanced)
- [Input Assembler](https://learn.microsoft.com/en-us/windows/win32/direct3d12/input-assembler-stage-d3d10-graphics)
- [SV_InstanceID](https://learn.microsoft.com/en-us/windows/win32/direct3dhlsl/dx-graphics-hlsl-semantics)
- [SetGraphicsRootShaderResourceView](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12graphicscommandlist-setgraphicsrootshaderresourceview)

## 2. 直觉：一份模具，多份摆放

游戏类比：

```text
Vertex/Index Buffer   = 一座房子的模具（墙角、三角形、UV）
InstanceData          = 这栋房子摆在哪、刷什么颜色
DrawIndexedInstanced  = 用同一份模具连盖 N 栋
材质 / PSO            = 这批房子用实心墙还是玻璃
```

R.5.6 为了讲 Alpha Mode，把四个物体的顶点都写进同一份 VB，每个物体一次 `DrawIndexedInstanced(..., 1, ...)`。
那不是实例化：网格数据被复制了四份，位置差写在顶点里。

本节把网格收成 **3 个顶点 / 3 个索引**。六个物体的位置、朝向、颜色全部进 `InstanceData`。
三个不透明墙还进一步合成 **一次 Draw、InstanceCount=3**。

## 3. 实例化改的是 Draw 循环，不是网格

`DrawIndexedInstanced` 五个参数现在都有意义：

```cpp
void DrawIndexedInstanced(
    UINT IndexCountPerInstance,
    UINT InstanceCount,
    UINT StartIndexLocation,
    INT  BaseVertexLocation,
    UINT StartInstanceLocation);
```

本课不透明墙：

```text
IndexCountPerInstance = 3     每个实例读 3 个索引，一个三角形
InstanceCount         = 3     连续画 3 个实例
StartIndexLocation    = 0     从 IB 第 0 个索引开始
BaseVertexLocation    = 0     索引值直接当顶点号
StartInstanceLocation = 0     第一个实例的 SV_InstanceID = 0
```

MASK 叶片是另一次 Draw：`InstanceCount=1, StartInstanceLocation=3`。
远/近玻璃分别从实例 4、5 开始。它们仍共享同一份 VB/IB，只是这次 Draw 只取其中一个实例。

硬件对每个实例重复同一套索引循环：

```text
for instance = StartInstanceLocation .. StartInstanceLocation+InstanceCount-1:
    for i in 0 .. IndexCountPerInstance-1:
        vertexIndex = IB[StartIndexLocation + i] + BaseVertexLocation
        SV_VertexID   = 这个顶点在本次 Draw 里的序号
        SV_InstanceID = instance
        从 VB 取 Vertex[vertexIndex]
```

网格字节一次都没复制。六个物体读的是同一份 108 字节 VB。

## 4. `SV_InstanceID` 不是顶点属性

`POSITION` / `COLOR0` / `TEXCOORD0` 来自 Input Layout + Vertex Buffer。
`SV_InstanceID` 由 Input Assembler **生成**，不占 VB 的任何字节，也不需要 Input Layout 条目。

```hlsl
uint instanceId : SV_InstanceID;
InstanceData inst = gInstances[input.instanceId];
```

它等于：

```text
SV_InstanceID = StartInstanceLocation + 当前是这次 Draw 的第几个实例
```

所以：

- 不透明墙那一次 Draw：ID = 0, 1, 2
- MASK Draw：`StartInstanceLocation=3`，ID = 3
- 近玻璃 Draw：`StartInstanceLocation=5`，ID = 5

把 `StartInstanceLocation` 设错，Shader 就会读到别人的 World。这和把 CBV 槽绑错是同一类错误：接口对上了，数据窗口偏了。

`SV_VertexID` 是另一套系统值：它随顶点推进，不随实例推进。不要用 `SV_VertexID` 去索引实例数组。

### 4.1 IA 并不读取 `t1` 里的矩阵

本课有两条独立的数据路，它们**不在 IA 里会合**，而在 Vertex Shader 里会合：

```text
IA 负责重复网格、生成 ID
    IASetVertexBuffers(slot 0)  -> 共享 VB：POSITION / COLOR0 / TEXCOORD0
    IASetIndexBuffer            -> 共享 IB：三个索引 0,1,2
    DrawIndexedInstanced(..., InstanceCount, ..., StartInstanceLocation)
        对每个实例把同一套索引再跑一遍
        生成 SV_InstanceID = StartInstanceLocation + 局部实例号
        IA 到此结束。它没有 Input Layout 条目指向矩阵，也不会去读 t1。

Root SRV 负责提供每实例 World
    SetGraphicsRootShaderResourceView(4, instance_buffer_gpu)
        把 StructuredBuffer 的 GPU 地址交给 VS 的 register(t1)

VS 负责用 ID 取矩阵
    InstanceData inst = gInstances[input.instanceId];
    local * inst.world * gViewProjection
```

不透明墙那一次 Draw 的一次 VS 调用，概念上是：

```text
DrawIndexedInstanced(3, 3, 0, 0, 0)
  实例局部号 0，索引 0 -> VB 顶点 0，SV_InstanceID=0 -> t1[0].world
  实例局部号 0，索引 1 -> VB 顶点 1，SV_InstanceID=0 -> t1[0].world
  实例局部号 0，索引 2 -> VB 顶点 2，SV_InstanceID=0 -> t1[0].world
  实例局部号 1，索引 0 -> VB 顶点 0，SV_InstanceID=1 -> t1[1].world
  ...
```

同一份 108 字节 VB 被读了 9 次（3 顶点 × 3 实例），但字节没有复制。
矩阵每次都来自 `gInstances[SV_InstanceID]`，不是来自 IA 的第二个 vertex slot。

另一条路才是 IA 直接喂实例数据：`PER_INSTANCE_DATA` + 第二个 VBV。
那时候矩阵会拆成 4 个 `float4` 语义，由 IA 按 InstanceID 推进 stride。
本课不走它。当前 Input Layout 三个元素全是 `PER_VERTEX_DATA`，`IASetVertexBuffers` 只绑了 slot 0。

## 5. 两条喂实例数据的路

### 5.1 IA 实例流（本节对照，不作为主路径）

Input Layout 可以再开一个 slot：

```text
slot 0  PER_VERTEX_DATA     网格 VB
slot 1  PER_INSTANCE_DATA   实例 VB，StepRate=1
```

`IASetVertexBuffers(0, 2, views)` 一次绑两条流。硬件按 InstanceID 前进 slot 1 的 stride。
这是 D3D11 时代最常见的路。矩阵要拆成 4 个 `float4` 语义，因为 Input Layout 没有 `float4x4` 格式。

### 5.2 StructuredBuffer + SV_InstanceID（本节主路径）

```text
网格仍走 IA slot 0
每实例 World/颜色走 t1 StructuredBuffer
VS 用 SV_InstanceID 自己取 gInstances[id]
```

选择这条路的原因：

| | IA 实例流 | StructuredBuffer |
|---|---|---|
| 矩阵 | 拆成 4 个 `TEXCOORD`/`WORLD` | 一个 `float4x4` 成员 |
| 绑定 | 多一个 VBV / Input Layout 条目 | Root SRV 一个 GPU 地址 |
| 谁能写 | 通常是 CPU 上传的 VB | CPU 或 Compute/CUDA 都能写同一份 Buffer |
| 元素对齐 | stride 任意，但语义要拆 | 16 字节对齐即可，不必 256 |

商业引擎两种都用：植被/碎片常用 IA 或 GPU instancing；粒子、GPU culling 后的可见列表更常走 StructuredBuffer。
本课选 StructuredBuffer，是因为它和后续 CUDA 写实例、R.7 的资源所有权、G 路线的高斯实例是同一类 Buffer，不是因为 IA 实例流“过时”。

相同的底层机制：`InstanceCount > 1` 时，IA 重复网格，并给每个 VS 调用一个 `SV_InstanceID`。

## 6. 为什么不给每个实例一份 CBV

CBV 的 GPU 地址和 `SizeInBytes` 都必须 **256 字节对齐**。一份 64 字节矩阵也要占 256 字节单元。六个实例就要 1536 字节，还要 6 个描述符或 6 次 root CBV 切换。

`StructuredBuffer` 的元素只需 16 字节对齐：

```text
InstanceData  stride = 96 bytes
  +0   float4x4 world          64
  +64  float4   color          16
  +80  uint     instance_id     4
  +84  uint3    padding        12
```

六个实例 = 576 字节。HLSL `StructuredBuffer<T>` 按 `sizeof(T)` 步进；C++ 结构体必须和它逐字段一致。
`uint3` 填充不是“第三个颜色”，是为了让下一个元素仍从 16 字节边界开始。

Root Signature 增加的是 **Root SRV**，不是又一个 descriptor table：

```text
root parameter 4
    TYPE_SRV
    ShaderRegister = 1   -> HLSL register(t1)
    Visibility = VERTEX
```

```cpp
command_list->SetGraphicsRootShaderResourceView(
    4, frame.instance_buffer_gpu);
```

它把 Buffer 的 GPU 虚拟地址嵌进命令列表，占 2 DWORD 的 root 预算。
它**不**占用 CBV/SRV/UAV heap 槽，也**不**调用 `CreateShaderResourceView`。
Root SRV 没有 `NumElements`：越界由 Shader 自己负责。本课 CPU 写满 6 个元素，Draw 的 `StartInstanceLocation + InstanceCount` 也不超过 6。

和 R.5.6 的对照：

```text
b0  CBV table        每帧一份 ViewProjection，256 对齐，所有实例共享
b1  Root Constants   每 Draw 一份材质，8 DWORD 嵌进命令流
t0  SRV table        颜色纹理
s0  Sampler table    过滤规则
t1  Root SRV         每帧一份实例数组，96 字节 stride
```

## 7. 更新实例不得改网格

验收要求：**实例数据更新不改变静态网格资源**。

本课每帧只 `memcpy` 当前 frame 的 `instance_buffer`。`vertex_buffer` / `index_buffer` 在启动时上传一次，之后既不 Map，也不 Copy。

Fence 保护的是：

```text
frame[i].constant_buffer     上一帧 VS 可能还在读 ViewProjection
frame[i].instance_buffer     上一帧 VS 可能还在读 gInstances[id]
frame[i].command_allocator   上一帧命令还在
```

它不保护网格：网格在 Default Heap 上，所有帧共享只读副本。CPU 改 `cpu_instances[]` 再写入当前 frame 的 Upload Heap，不会碰到那 108 字节 VB。

## 8. 每实例常量的代价

实例化省的是：

```text
CPU：少录 N-1 次 SetPSO / 绑材质 / Draw
网格：VRAM 里只有一份 VB/IB
IA：重复读取同一份小网格，cache 友好
```

它不省的是：

```text
VS 仍为每个实例的每个顶点跑一遍
每实例仍要读 96 字节 World/颜色
像素覆盖该多少还是多少
```

把 1000 棵树合成一次 Draw，不等于 VS 只跑一棵树。它等于：命令列表更短、网格不复制、CPU 提交更少。
VS 成本随 `顶点数 × 实例数` 走；PS 成本随屏幕覆盖走。

本课三个不透明墙合成一次 Draw，是因为它们材质相同、PSO 相同、不需要单独排序。
MASK/BLEND 仍各画一次：Alpha Mode 不同就必须换材质 root constants，BLEND 还要按深度排序。
**实例化不能把不同 PSO / 不同混合顺序的物体塞进同一次 Draw。**

透明排序现在用的是实例平移的 z，不再是顶点局部 z。R.5.6 留下的“局部 z 不够用”在这里已经碰到：物体位置在 World 里，排序键必须跟实例变换走。本课相机仍在 `-Z` 看向原点，所以仍用世界 z；引擎通常用相机空间深度。

## 9. 当前场景与验收

```text
共享网格     3 vertices, 108 bytes, stride=36
             3 indices, 6 bytes, R16_UINT

实例 0..2    OPAQUE 墙     一次 Draw, InstanceCount=3
实例 3       MASK 叶片     一次 Draw, StartInstance=3
实例 4       BLEND 远玻璃  一次 Draw, StartInstance=4
实例 5       BLEND 近玻璃  一次 Draw, StartInstance=5
```

PowerShell：

```powershell
cd C:\xf\Cuda\accelerated-computing-hub\learning\sandbox
.\build.ps1 d3d12\r01-r08-mesh\d3d12_mesh_input_layout.cu -NoRun
.\d3d12\r01-r08-mesh\d3d12_mesh_input_layout.exe --frames 2 --no-vsync
```

本机 RTX 5070 / `sm_120` 实测：

```text
uploaded vertex buffer: 3 vertices, 108 bytes, stride=36
uploaded index buffer: 3 indices, 6 bytes, format=R16_UINT
instancing: shared mesh=3 vertices/3 indices, opaque Draw InstanceCount=3,
total instances=6, InstanceData=96 bytes
created 2 per-frame instance StructuredBuffers: count=6, stride=96, bytes=576
rendered frames: 2
D3D12 R.6 instanced mesh and StructuredBuffer: PASS
```

看画面时应能看到三面不透明墙、一片 MASK 叶片、两块半透明玻璃；墙在动，网格文件没有变大。

## 10. 商业引擎里那些“实例化”分别对应什么

引擎里“实例”被用滥了。先把**场景实例**和**GPU Draw 实例**分开：Prefab/Actor 复制是玩法层对象；GPU instancing 才是“同一份 VB/IB，一次 Draw，N 个变换”。下面只对照后者。

| 引擎说法 | 底层更像什么 | 和本课的关系 |
|---|---|---|
| Unity `DrawMeshInstanced` / 材质勾 GPU Instancing | `DrawIndexedInstanced` + 每实例常量 | **最近**：共享 mesh，CPU 填实例数组，VS 用 instance ID 取 World |
| Unity `DrawMeshInstancedIndirect` | `ExecuteIndirect` + 实例 Buffer | 本课还没有 Indirect；可见列表可由 Compute 写 |
| Unity SRP Batcher | 同变体材质的 CB 布局对齐，减少 SetPSO | **不是**实例化：仍然多次 Draw，只是绑定更便宜 |
| Unity Static Batching | 把多份网格焊进一份更大的 VB/IB | **不是**实例化：网格被复制/合并，丢掉每物体独立 VB |
| Unity Dynamic Batching | CPU 每帧把小网格拼起来 | **不是**实例化：改的是网格，不是 InstanceCount |
| UE Instanced Static Mesh (ISM) | 一个 Component 持有 N 份变换，按 LOD/材质段合 Draw | 本课三个不透明墙 = 最小 ISM |
| UE Hierarchical ISM / Foliage | ISM + 空间树，按簇剔除 | 本课没有 cluster cull |
| UE Auto Instance / MeshDrawCommand 合并 | 相同 PSO+mesh+material 的 Draw 合成一次 | 本课手写合批：墙合、MASK/BLEND 不合 |
| UE GPU Scene | 基元数据进 GPU Buffer，VS 用 PrimitiveId 取变换 | **同一类 Buffer 路径**：StructuredBuffer + ID，不是 IA 实例流 |
| Niagara / 粒子 Mesh | GPU 写实例 Buffer，再 instanced draw | 后续 CUDA 写 `t1` 就是这个方向 |
| Nanite | 软件光栅簇，不是经典 IA instancing | 共享网格源，但光栅路径不同，不要硬套 |

相同的底层机制始终是：

```text
共享 VB/IB
Draw 的 InstanceCount > 1
每个 VS 调用有一个实例 ID
用这个 ID 去取每实例 World/自定义数据
```

差别在数据从哪来、谁来剔除、Draw 是 CPU 写死还是 Indirect：

```text
本课          CPU 写 Upload Heap StructuredBuffer，Root SRV，CPU Draw
ISM/DrawMesh  CPU 建实例数组，可能走 IA 流或 StructuredBuffer
GPU Scene     变换长期住 GPU Buffer，Draw 只带 PrimitiveId 窗口
Indirect      Compute 先写可见实例列表和 Draw 参数，GPU 自己 Draw
```

本课：6 个实例、CPU 写 Upload Heap、Root SRV、不透明 3 个合一次 Draw，透明仍按队列分开。
没有 GPU culling、没有 Indirect、没有按材质自动合批编译器。

## 11. 当前简化边界

- 没有 IA `PER_INSTANCE_DATA` 主路径；只作为对照。
- 没有 `ExecuteIndirect`；Draw 仍由 CPU 写死。
- 实例缓冲在 Upload Heap，没有 Default Heap 副本。数量变大后应改成 Upload staging + Default。
- Root SRV 没有越界检查；错误的 `StartInstanceLocation` 会读到未定义数据。
- 透明排序仍是 CPU、世界 z，没有 OIT。
- Debug Layer 已在 R.7 打开并验收干净；窗口 resize 仍未做。

## 12. 小结

```text
实例化 = 同一份 VB/IB，IA 按 InstanceCount 重复网格
SV_InstanceID = IA 生成，等于 StartInstanceLocation + 局部实例号
StructuredBuffer = 每实例 World/颜色，96 字节 stride，不必 256 对齐
Root SRV = 把 Buffer GPU 地址嵌进命令列表，不占 descriptor heap
更新实例 = 只写当前帧的 instance_buffer，不动网格 Resource
合批边界 = 相同 PSO + 相同材质才能进同一次 Draw
```

## 13. 自测题

1. 为什么三个不透明墙能合成一次 Draw，MASK 叶片却不行？
2. `SV_InstanceID` 是从 Vertex Buffer 读出来的吗？`StartInstanceLocation=3` 时第一个 VS 调用的 ID 是多少？
3. 每实例 96 字节的 World 为什么不适合做成 CBV？StructuredBuffer 的对齐要求是什么？
4. 每帧改实例颜色时，为什么不必重新上传 Vertex Buffer？Fence 这时保护的是哪块内存？
