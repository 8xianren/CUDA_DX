# R.10 TLAS：实例、变换与 glTF 节点对应

## 1. 本节目标与边界

本节在 R.9 的 BLAS 之上建立 TLAS：让两个场景实例引用同一个 BLAS，但拥有不同的 `Transform`、`InstanceID` 和 hit-group 索引贡献。

本节验证真实 D3D12/DXR 资源关系：

```text
局部 Vertex/Index Buffer
    -> BLAS Result
    -> 两个 D3D12_RAYTRACING_INSTANCE_DESC
    -> GPU 可读 Instance Desc Buffer
    -> TLAS Result
    -> Fence 完成
```

本节仍不创建：

```text
State Object
Shader Table
RayGen / Miss / ClosestHit
TraceRay / DispatchRays
```

因此“TLAS build: PASS”只证明实例层加速结构构建成功，不代表已经发射射线。

程序：`learning/sandbox/d3d12/r10-tlas/dxr_tlas_build.cu`

运行：

```powershell
cd C:\xf\Cuda\accelerated-computing-hub\learning\sandbox
.\build.ps1 d3d12\r10-tlas\dxr_tlas_build.cu
```

本机 Windows + RTX 5070 + DXR Tier 1.1 实测：

```text
D3D12 Debug Layer: enabled
adapter: NVIDIA GeForce RTX 5070
raytracing tier: 11
BLAS result=2560 scratch=1792; TLAS result=2176 scratch=2048; instances=128 bytes
InfoQueue: errors=0 warnings=0 stored=0
instances: ID=10 x=0, ID=20 x=3, shared_blas=0x784f000
TLAS result_gpu=0x7cb6000
TLAS build: PASS
```

地址每次运行都可能变化；它们是本次进程有效的 GPU 虚拟地址，不是稳定的物理地址。

---

## 2. 为什么需要 TLAS

假设一个三角形 mesh 被场景中的两个 node 引用：

```text
同一份局部三角形
    -> Node A：x = 0
    -> Node B：x = 3
```

如果为两个 node 各建一份 BLAS，就会重复存储相同的局部几何。DXR 的分层结构允许：

```text
一个 BLAS：保存一次局部几何
两个 TLAS instance：保存两个场景放置
```

所以：

```text
BLAS：这个 mesh 的局部三角形是什么？
TLAS：这个场景里有哪些实例、它们在哪里、引用哪个 BLAS？
```

这正好对应 glTF 的典型关系：多个 `node` 可以引用同一个 `mesh`。mesh/primitive 准备 Vertex/Index 和 BLAS，node 的 World Matrix 留到 TLAS instance。

### 2.1 与 BVH 的关系

从算法抽象看，TLAS 仍是 BVH 家族的一层：它用实例包围盒先剔除不可能命中的实例，命中候选后再进入实例所引用的 BLAS。BLAS 再对局部几何做层次剔除，最后才到三角形求交。

```text
World ray
    -> TLAS 的实例层
    -> 实例变换后的局部 ray
    -> BLAS 的几何层
    -> 三角形
```

DXR Result Buffer 的内部布局由驱动和 GPU 管理，可能使用宽节点、压缩/量化和针对构建或更新的不同布局。应用只提交 `Geometry Desc`、`Instance Desc` 和 Build 命令，不能读取或自行遍历内部节点。

---

## 3. `D3D12_RAYTRACING_INSTANCE_DESC`

Windows SDK 中的逻辑布局是：

```cpp
typedef struct D3D12_RAYTRACING_INSTANCE_DESC
{
    FLOAT Transform[3][4];

    UINT InstanceID : 24;
    UINT InstanceMask : 8;

    UINT InstanceContributionToHitGroupIndex : 24;
    UINT Flags : 8;

    D3D12_GPU_VIRTUAL_ADDRESS AccelerationStructure;
} D3D12_RAYTRACING_INSTANCE_DESC;
```

本节最重要的字段：

```text
Transform
    实例的 3×4 仿射变换。

InstanceID
    应用写入的 24 位标识；未来 ClosestHit 可通过 InstanceID() 读取。

InstanceMask
    实例可见性位掩码；未来 TraceRay 的 inclusion mask 与它做过滤。

InstanceContributionToHitGroupIndex
    参与选择 Shader Table 命中记录；本节只填入不同值，R.11 才完整使用。

Flags
    实例级 DXR 行为标志；本节使用 0。

AccelerationStructure
    被实例引用的 BLAS GPU 虚拟地址，不是 CPU 指针。
```

`D3D12_RAYTRACING_INSTANCE_DESC` 通常为 64 字节；本节两个实例的有效数据是 128 字节，满足 `D3D12_RAYTRACING_INSTANCE_DESCS_BYTE_ALIGNMENT` 的 16 字节对齐要求。

### 3.1 `Transform[3][4]`

它表示：

```text
x' = m00*x + m01*y + m02*z + m03
y' = m10*x + m11*y + m12*z + m13
z' = m20*x + m21*y + m22*z + m23
```

单位变换写成：

```cpp
{
    {1, 0, 0, 0},
    {0, 1, 0, 0},
    {0, 0, 1, 0}
}
```

第二个实例本节只改变 X 平移：

```cpp
{
    {1, 0, 0, 3},
    {0, 1, 0, 0},
    {0, 0, 1, 0}
}
```

因此两个实例共享同一份局部三角形，但场景位置不同。

不要把 `Transform` 与 glTF `matrix` 的字节拷贝约定想当然地混用。glTF 的矩阵语义、CPU 数学库的行/列向量约定和 D3D12 instance transform 的布局必须在 C.4 中专门核对。本节使用手工 3×4 数据，避免把 TLAS 基础和 glTF 矩阵约定同时混入。

---

## 4. BLAS GPU 地址如何进入 TLAS

R.9 的 BLAS Result 资源通过：

```cpp
blas_result->GetGPUVirtualAddress()
```

取得 GPU 虚拟地址，然后写入：

```cpp
instance.AccelerationStructure = blas_result->GetGPUVirtualAddress();
```

错误写法是把 COM 对象地址、CPU 映射地址或 C++ 指针塞进去。TLAS 构建和之后的 DXR 遍历都要求这个 GPU 地址仍指向有效的 BLAS Result。

资源生命周期关系：

```text
BLAS Result
    -> 被 Instance Desc 引用
    -> TLAS 构建期间必须有效
    -> TLAS 遍历期间也必须有效
```

本节的 `ComPtr` 让资源至少活到 `main` 结束；真实渲染器还要把 BLAS 的生命周期接到资源缓存和 GPU fence retire 机制上。

---

## 5. Instance Desc Buffer：CPU 结构变成 GPU 输入

`D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS::InstanceDescs` 的类型是：

```cpp
D3D12_GPU_VIRTUAL_ADDRESS InstanceDescs;
```

所以它不是 CPU 指针。程序先在 CPU 栈上构造：

```cpp
D3D12_RAYTRACING_INSTANCE_DESC instances[2]{};
```

然后复制到 Upload Heap Buffer：

```text
CPU instance array
    -> Map / memcpy
    -> Upload Heap resource
    -> GetGPUVirtualAddress()
    -> inputs.InstanceDescs
```

本节的 Upload Heap 资源保持：

```cpp
D3D12_RESOURCE_STATE_GENERIC_READ
```

TLAS 构建只读取实例描述，因此这里没有把它转换成 UAV。生产引擎通常会根据帧生命周期使用上传环、Default Heap staging 或持久化 instance buffer；本节采用 Upload Heap 是为了直接看清 CPU 数据到 GPU 地址的关系，不代表大规模场景的最终性能方案。

---

## 6. TLAS Build Inputs

核心代码逻辑：

```cpp
D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS tlas_in{};
tlas_in.Type = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL;
tlas_in.DescsLayout = D3D12_ELEMENTS_LAYOUT_ARRAY;
tlas_in.NumDescs = 2;
tlas_in.InstanceDescs = instance_gpu;
tlas_in.Flags =
    D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE;
```

与 R.9 的 BLAS 输入对比：

```text
BLAS:
    Type = BOTTOM_LEVEL
    NumDescs = geometry 数量
    pGeometryDescs = CPU 可访问的 Geometry Desc

TLAS:
    Type = TOP_LEVEL
    NumDescs = instance 数量
    InstanceDescs = GPU 地址
```

这里 `NumDescs=2` 表示两个 instance，不是两个三角形，也不是两个 BLAS。每个 instance 内部再通过 `AccelerationStructure` 引用一个 BLAS。

### 6.1 `GetRaytracingAccelerationStructurePrebuildInfo`

真实接口：

```cpp
void ID3D12Device5::GetRaytracingAccelerationStructurePrebuildInfo(
    const D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS* pDesc,
    D3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO* pInfo);
```

TLAS 也必须先查询驱动给出的：

```text
ResultDataMaxSizeInBytes
ScratchDataSizeInBytes
UpdateScratchDataSizeInBytes
```

本机这个两实例 TLAS 的结果是：

```text
TLAS result = 2176 bytes
TLAS scratch = 2048 bytes
```

这些不是通用常数；几何数量、实例数量、Build Flags、GPU 架构和驱动都可能改变它们。

---

## 7. TLAS Result、Scratch 与构建命令

TLAS Result：

```cpp
D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS
D3D12_RESOURCE_STATE_RAYTRACING_ACCELERATION_STRUCTURE
```

Scratch：

```cpp
D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS
初始 COMMON
构建前转换到 UNORDERED_ACCESS
```

构建描述：

```cpp
D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC build{};
build.Inputs = tlas_in;
build.DestAccelerationStructureData = tlas_result->GetGPUVirtualAddress();
build.ScratchAccelerationStructureData = tlas_scratch->GetGPUVirtualAddress();
```

录制：

```cpp
list->BuildRaytracingAccelerationStructure(&build, 0, nullptr);
```

这只是把命令写入 Command List，不是 CPU 同步执行。之后仍要：

```text
Close Command List
    -> ExecuteCommandLists
    -> Queue Signal(Fence)
    -> 等待 Fence
```

等待完成前不能释放：

```text
BLAS Result
Instance Desc Buffer
TLAS Scratch
TLAS Result
```

---

## 8. 为什么只改实例变换通常不需要重建 BLAS

如果 mesh 顶点和索引不变，只改变 glTF node 的 World Matrix：

```text
局部几何不变
    -> BLAS 保持不变
实例变换改变
    -> 更新 Instance Desc
    -> 重建或更新 TLAS
```

如果顶点本身发生形变，例如 CPU 蒙皮后的顶点位置变化，则影响 BLAS；如果只是整个对象移动、旋转、缩放，则主要影响 TLAS。

实际引擎还会根据静态/动态几何选择 build、refit、update、重建和压缩策略；本节只建立资源依赖，不把动态更新策略混入第一次 TLAS 构建。

---

## 9. 本节与 UE/glTF 的对应

概念映射：

```text
glTF mesh / primitive
    -> Vertex/Index Buffer
    -> BLAS geometry

glTF node 层级和 World Matrix
    -> TLAS Instance Transform

glTF node 的稳定对象标识
    -> InstanceID 或引擎自己的对象数据索引
```

UE 生产实现会额外处理多 GPU、资源驻留、动态几何、Nanite/Ray Tracing Geometry、SBT 材质参数缓存和帧间资源生命周期。本节用一个进程、一个 GPU、两个实例只验证相同的底层 D3D12 机制，不把教学程序描述成引擎级资源系统。

---

## 10. 本节验收

```text
两个 Instance Desc 共享一个 BLAS GPU 地址       PASS
InstanceID 分别为 10 和 20                       PASS
实例 X 平移分别为 0 和 3                         PASS
TLAS Prebuild Info 成功                          PASS
TLAS Result/Scratch 创建并构建                   PASS
GPU Fence 完成                                   PASS
D3D12 InfoQueue errors=0 warnings=0              PASS
```

本节仍未验证：

```text
TraceRay
ClosestHit / Miss
Shader Table
DispatchRays
```

这些属于 R.11。

## 小结

```text
BLAS = 局部几何加速结构
TLAS = 场景实例加速结构
Instance Desc = 一个实例如何引用 BLAS、放置在哪里、如何参与后续命中选择
```

下一节 R.11 将把已经存在的 TLAS 接入真实 DXR 执行链：

```text
DXIL Shader Library
    -> Hit Group
    -> State Object
    -> Shader Table
    -> DispatchRays
    -> RayGen / Miss / ClosestHit
```
