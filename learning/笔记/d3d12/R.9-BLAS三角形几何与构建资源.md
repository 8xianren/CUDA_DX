# R.9 BLAS：三角形几何、Prebuild Info、Scratch Buffer 与 Result Buffer

## 1. 本节目标与边界

本节把一份 D3D12 三角形几何数据描述成 DXR 的 **BLAS（Bottom-Level Acceleration Structure，底层加速结构）**，并真正提交到 RTX GPU 构建。

本节只验证：

```text
Vertex/Index Buffer
    -> D3D12_RAYTRACING_GEOMETRY_DESC
    -> D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS
    -> GetRaytracingAccelerationStructurePrebuildInfo
    -> Scratch Buffer + Result Buffer
    -> BuildRaytracingAccelerationStructure
    -> Fence 等待 GPU 完成
```

本节暂不做：

```text
TLAS                 R.10
Shader Table/State Object/DispatchRays  R.11
阴影射线             R.12
主射线和最小 Path Tracer R.13
```

程序：`learning/sandbox/d3d12/r09-blas/dxr_blas_build.cu`

运行：

```powershell
cd C:\xf\Cuda\accelerated-computing-hub\learning\sandbox
.\build.ps1 d3d12\r09-blas\dxr_blas_build.cu
```

本机 Windows + RTX 5070 + DXR Tier 1.1 实测：

```text
D3D12 Debug Layer: enabled
adapter: NVIDIA GeForce RTX 5070
raytracing tier: 11
prebuild result=2560 bytes scratch=1664 update_scratch=0
aligned result=2560 scratch=1792 result_gpu=0x784f000
BLAS build: PASS
```

`result_gpu` 是每次运行可能变化的 GPU 虚拟地址，不是稳定的硬件物理地址；后续 TLAS 只把它当作本次进程中有效的 `D3D12_GPU_VIRTUAL_ADDRESS`。

---

## 2. BLAS 到底是什么

把一个物体想成两层数据：

```text
三角形顶点/索引
    = 原始几何数据

BLAS
    = 对这些三角形建立的可遍历加速结构
```

BLAS 不是：

```text
Vertex Buffer 的别名
Index Buffer 的别名
Material
TLAS
Shader Table
```

它是驱动/硬件使用的另一份 GPU 数据结构。顶点和索引 Buffer 至少必须保持有效到 GPU 完成 BLAS 构建。构建完成后，DXR 的加速结构遍历本身使用 BLAS Result；但 ClosestHit 若要根据 primitive/barycentrics 重建插值法线、UV、材质属性，通常仍需原始 Vertex/Index Buffer，允许更新的动态 BLAS 也可能继续需要构建输入。故是否释放取决于后续 shader 和 update 设计，不能把“构建输入生命周期”与“着色属性数据生命周期”混为一谈。

本节的三角形：

```text
vertex 0 = ( 0,  1, 0)
vertex 1 = (-1, -1, 0)
vertex 2 = ( 1, -1, 0)
index   = 0, 1, 2
```

`VertexBuffer.StrideInBytes=12`，因为每个顶点是三个 `float`；索引使用 `R32_UINT`。

---

## 3. BLAS 在底层属于什么结构

从算法抽象看，BLAS/TLAS 都属于 BVH（Bounding Volume Hierarchy，层次包围体）家族：内部节点用包围盒做射线剔除，叶节点才关联三角形或实例。BLAS 的层次对象是局部几何，TLAS 的层次对象是实例包围盒和 BLAS 引用。

但 D3D12 不规定内部必须是简单二叉 BVH。驱动和 GPU 可以使用更宽的节点、压缩/量化包围盒、叶节点重排以及针对静态构建或动态更新的不同布局；这些都是实现细节，应用只看到 opaque 的 Result Buffer，不能像自己写的树一样读取内部节点、指定分支或自行遍历。它们也不是 Chaos 物理碰撞树的同一份资源：二者都可能使用 AABB/BVH 思路，但 DXR AS 面向 GPU 光线遍历与硬件三角形求交，物理系统还要服务 Sweep、Overlap、接触和约束求解。

本课程只需要掌握这条调用边界：

```text
Geometry Desc / Instance Desc
    -> DXR Build
    -> 驱动/硬件私有的 BLAS/TLAS 布局
    -> TraceRay 遍历
```

不另做脱离真实 DXR 的 CPU“假 BVH”或可视化验收；若后续需要学习自定义 BVH，放在 PT.9 CUDA 对照扩展中。

## 4. BLAS 不负责什么

BLAS 主要负责底层几何层的加速结构。它不决定：

```text
当前场景里放了几个实例
每个实例的位置/旋转/缩放
哪个实例属于哪个材质
射线命中后调用哪个 shader
路径贡献是多少
```

这些分别属于：

```text
TLAS                       实例层，R.10
Shader Table/Hit Group     shader 选择和 record，R.11
BRDF/PDF/MIS               路径积分器，PT.6 以后
```

所以：

```text
一个 BLAS 可以被多个 TLAS instance 复用
同一份 mesh 不必为每个 node 重建一份 BLAS
```

这正是它与 glTF 对接的关键：glTF 的一个 `mesh` 可以被多个 `node` 引用，mesh/primitive 适合准备几何和 BLAS，node 的 World Matrix 留到 TLAS instance。

---

## 5. `D3D12_RAYTRACING_GEOMETRY_TRIANGLES_DESC`

Windows SDK 10.0.26100.0 中的核心布局是：

```cpp
typedef struct D3D12_RAYTRACING_GEOMETRY_TRIANGLES_DESC {
    D3D12_GPU_VIRTUAL_ADDRESS Transform3x4;
    DXGI_FORMAT IndexFormat;
    DXGI_FORMAT VertexFormat;
    UINT IndexCount;
    UINT VertexCount;
    D3D12_GPU_VIRTUAL_ADDRESS IndexBuffer;
    D3D12_GPU_VIRTUAL_ADDRESS_AND_STRIDE VertexBuffer;
} D3D12_RAYTRACING_GEOMETRY_TRIANGLES_DESC;
```

本节填写：

```cpp
D3D12_RAYTRACING_GEOMETRY_TRIANGLES_DESC tri{};
tri.VertexBuffer.StartAddress = vertex_gpu_address;
tri.VertexBuffer.StrideInBytes = sizeof(Vertex);
tri.VertexCount = 3;
tri.VertexFormat = DXGI_FORMAT_R32G32B32_FLOAT;
tri.IndexBuffer = index_gpu_address;
tri.IndexCount = 3;
tri.IndexFormat = DXGI_FORMAT_R32_UINT;
```

### `Transform3x4`

它是可选的几何变换 GPU 地址，常用于把几何变换放在 geometry 层。当前设置为 0：

```text
BLAS 中的三角形直接使用当前 Vertex Buffer 坐标
实例变换由未来 TLAS 的 D3D12_RAYTRACING_INSTANCE_DESC 负责
```

对于 glTF：

```text
primitive 的顶点数据     -> BLAS geometry
node 的 World Matrix      -> TLAS instance Transform
```

不要把 node 变换提前烘进每份静态顶点，除非你明确选择了这种资源策略；否则会丢掉 mesh/BLAS 复用优势。

### `VertexFormat` 与 `StrideInBytes` 是两层不同信息

```text
VertexFormat
    一个顶点属性如何解释，例如 R32G32B32_FLOAT

StrideInBytes
    从一个顶点起点走到下一个顶点起点跨多少字节
```

本节二者都是 12，但这不是永远如此。真实 glTF/D3D12 资源可能是 interleaved 或转换后的内部 Vertex：

```text
VertexFormat = position 的三 float
Stride       = 内部 Vertex 整体大小，例如 32/36/48 bytes
```

---

## 6. `D3D12_RAYTRACING_GEOMETRY_DESC`

外层结构选择几何类型和几何 flags：

```cpp
D3D12_RAYTRACING_GEOMETRY_DESC geom{};
geom.Type = D3D12_RAYTRACING_GEOMETRY_TYPE_TRIANGLES;
geom.Flags = D3D12_RAYTRACING_GEOMETRY_FLAG_OPAQUE;
geom.Triangles = tri;
```

`OPAQUE` 的教学含义：

```text
该几何不使用 AnyHit shader 做透明裁剪
```

这不是 glTF `alphaMode` 的完整实现。后续 glTF 材质接入时：

```text
OPAQUE/MASK/BLEND
    会影响 DXR geometry flags、AnyHit 逻辑、材质读取和光线类型
```

当前先使用 OPAQUE，避免把透明材质路径混入 BLAS 正确性测试。

---

## 7. `D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS`

构建输入：

```cpp
D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS inputs{};
inputs.Type = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL;
inputs.DescsLayout = D3D12_ELEMENTS_LAYOUT_ARRAY;
inputs.NumDescs = 1;
inputs.pGeometryDescs = &geom;
inputs.Flags =
    D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE;
```

字段含义：

```text
Type
    当前构建 BLAS，而不是 TLAS

DescsLayout
    几何描述是数组布局

NumDescs
    几何描述数量；本节只有一个三角形 geometry desc

pGeometryDescs
    CPU 录制时可访问的几何描述数组

Flags
    构建策略提示，例如偏向快速追踪或偏向快速构建
```

### `pGeometryDescs` 的所有权

`pGeometryDescs` 指向 CPU 内存中的描述结构。它不是 GPU 指针，也不是一个永久由 GPU 保存的 descriptor。调用 `BuildRaytracingAccelerationStructure` 录制命令时，运行时读取它并把所需参数写入命令记录。

但是它引用的：

```text
VertexBuffer GPU 地址
IndexBuffer GPU 地址
```

必须在 GPU 真正执行构建前有效。`Close()` 或 `ExecuteCommandLists()` 返回不代表 GPU 已经读完。

本节通过：

```text
ExecuteCommandLists
    -> Queue Signal(Fence)
    -> CPU 等待 Fence
```

才结束资源生命周期。

---

## 8. `GetRaytracingAccelerationStructurePrebuildInfo`

真实接口：

```cpp
void ID3D12Device5::GetRaytracingAccelerationStructurePrebuildInfo(
    const D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS* pDesc,
    D3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO* pInfo);
```

参数：

```text
pDesc
    与将要执行的 BLAS 构建输入相同

pInfo
    驱动填写的尺寸需求
```

返回：

```cpp
typedef struct D3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO {
    UINT64 ResultDataMaxSizeInBytes;
    UINT64 ScratchDataSizeInBytes;
    UINT64 UpdateScratchDataSizeInBytes;
} ...;
```

本机结果：

```text
ResultDataMaxSizeInBytes = 2560
ScratchDataSizeInBytes  = 1664
UpdateScratchDataSizeInBytes = 0
```

不能自己猜：

```cpp
result = vertex_count * 常数
scratch = triangle_count * 常数
```

不同 GPU、驱动、geometry 数量、flags 和构建策略都可能改变需求。正确流程是：

```text
先填写完整 inputs
    -> 调 GetRaytracingAccelerationStructurePrebuildInfo
    -> 按返回值创建资源
```

### 为什么 `UpdateScratchDataSizeInBytes` 是 0？

当前构建 flags 是普通构建，不是允许 update 的动态 BLAS 路线。若未来使用：

```cpp
D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_ALLOW_UPDATE
```

就需要按 update 场景保存相应 scratch 需求，并使用 SourceAccelerationStructureData 等字段；动态 BLAS 暂留后续，不在本节混入。

---

## 9. Result Buffer 与 Scratch Buffer

### 8.1 Result Buffer

Result Buffer 是构建完成的 BLAS 本体。未来 TLAS instance 会使用：

```cpp
result->GetGPUVirtualAddress()
```

作为：

```cpp
D3D12_RAYTRACING_INSTANCE_DESC::AccelerationStructure
```

Result Buffer：

```text
GPU 创建/写入
初始状态：D3D12_RESOURCE_STATE_RAYTRACING_ACCELERATION_STRUCTURE
构建完成后保存到 R.10/R.11 使用
```

### 8.2 Scratch Buffer

Scratch Buffer 是构建过程临时工作空间：

```text
GPU 构建期间使用
不是 BLAS 本体
本次构建完成后，若没有其他构建正在使用，可以复用或释放
```

本节创建：

```cpp
D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS
```

因为加速结构构建以 UAV 写入语义使用底层资源。第一次实验中如果省略这个 flag，`CreateCommittedResource` 在本机返回：

```text
E_INVALIDARG (0x80070057)
```

这不是 DXR Tier 不支持，而是资源描述不满足该用途。修正后 Debug Layer 开启、BLAS 构建通过。

### 8.3 对齐

Windows SDK 定义：

```cpp
D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BYTE_ALIGNMENT = 256
D3D12_RAYTRACING_INSTANCE_DESCS_BYTE_ALIGNMENT = 16
```

本节使用：

```cpp
UINT64 align_up(UINT64 x, UINT64 alignment) {
    return (x + alignment - 1) / alignment * alignment;
}
```

本机：

```text
Result 需求 2560 -> 对齐后 2560
Scratch 需求 1664 -> 对齐后 1792
```

不能把普通 CBV 的 256-byte 规则、instance desc 的 16-byte 规则和所有 Buffer 的规则混成一个“都对齐 256”。每一种 API 字段的对齐要求都要按 SDK 定义检查。

---

## 10. 资源状态与命令录制

创建资源时：

```cpp
Result:
    D3D12_RESOURCE_STATE_RAYTRACING_ACCELERATION_STRUCTURE

Scratch:
    D3D12_RESOURCE_STATE_UNORDERED_ACCESS
```

然后命令列表：

```cpp
command_list->BuildRaytracingAccelerationStructure(
    &build_desc, 0, nullptr);
```

构建后，当前程序还录制了一个 UAV barrier：

```cpp
D3D12_RESOURCE_BARRIER barrier{};
barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_UAV;
barrier.UAV.pResource = result.Get();
command_list->ResourceBarrier(1, &barrier);
```

本节后面紧接着是 Fence；未来若另一个 GPU 命令要读取/使用 BLAS，必须建立正确的命令顺序和资源状态/同步关系。UAV barrier 和 Fence 不是同一层：

```text
UAV barrier
    GPU 命令之间的 UAV 写后读/写后写顺序

Fence
    Queue 与 CPU/另一 queue 之间的时间线同步和生命周期保护
```

二者不能互相替代。

---

## 11. `BuildRaytracingAccelerationStructure` 的描述

```cpp
void ID3D12GraphicsCommandList4::BuildRaytracingAccelerationStructure(
    const D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC* pDesc,
    UINT NumPostbuildInfoDescs,
    const D3D12_RAYTRACING_ACCELERATION_STRUCTURE_POSTBUILD_INFO_DESC* pPostbuildInfoDescs);
```

本节 `pDesc`：

```cpp
D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC build{};
build.DestAccelerationStructureData = result_gpu_address;
build.ScratchAccelerationStructureData = scratch_gpu_address;
build.Inputs = inputs;
```

暂未使用：

```text
SourceAccelerationStructureData
    只有更新已有 AS 等路线才需要

PostbuildInfo
    例如输出当前 AS 尺寸或序列化结果，本节先不做
```

命令录制后，GPU 才会真正读取几何 Buffer 并写入 Result/Scratch。CPU 不应在 Execute 后立即释放资源。

---

## 12. 构建生命周期图

```text
CPU 创建 Upload Vertex/Index Buffer
    |
    |  GPU VA 写入 Geometry Desc
    v
填写 BLAS Inputs + Geometry Desc
    |
    v
GetRaytracingAccelerationStructurePrebuildInfo
    |
    +--> 创建 Result Buffer（Default/UAV/AS state）
    +--> 创建 Scratch Buffer（Default/UAV/UAV state）
    |
    v
录制 BuildRaytracingAccelerationStructure
    |
    v
录制 UAV barrier
    |
    v
Close -> ExecuteCommandLists
    |
    v
Queue Signal(Fence)
    |
    v
CPU 等待 Fence
    |
    v
BLAS Result 可交给 R.10 TLAS
```

这里的 CPU 等待是教学验收用的全局 flush。生产引擎会把 AS 构建排进资源上传/构建队列，通过更细粒度的 Fence 与 frame graph 管理重叠，不代表本节的等待方式就是最终性能方案。

---

## 13. 本节验收

本机结果：

```text
D3D12 Debug Layer: enabled
RTX 5070 / Raytracing Tier 1.1
prebuild result=2560 bytes scratch=1664 update_scratch=0
aligned result=2560 scratch=1792
BLAS build: PASS
```

已验证：

```text
三角形 Vertex/Index Buffer 的 GPU 地址可用于 Geometry Desc
Geometry Desc 的格式/stride/count 正确
Prebuild Info 返回有效尺寸
Result/Scratch 对齐并创建成功
Result/Scratch 的资源 flags/state 满足本机 DXR 构建
BuildRaytracingAccelerationStructure 命令执行完成
Fence 到达后才宣布 BLAS 完成
```

尚未验证：

```text
TLAS
TraceRay
Miss/ClosestHit
Shader Table
```

下一节：**R.10 TLAS：实例、变换与 glTF node/world matrix 对应**。
