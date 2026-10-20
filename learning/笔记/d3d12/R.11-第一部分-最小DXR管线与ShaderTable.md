# R.11 第一部分：最小 DXR 管线、Shader Table 与 DispatchRays

> 状态：**部分完成**。本课只验收无窗口、单 Hit Group、无 local root arguments 的真实 GPU `DispatchRays`。原计划（`learning/学习计划.md` R.11）要求的真实窗口、不同实例选不同 Hit Group/材质索引、GPU 验证 local root record 字节布局仍待完成；不能把本课 PASS 当作完整 R.11 验收。R.12 阴影射线和 R.13 路径追踪也没有因此完成。

## 1. 目标与游戏开发类比

R.10 只把一个三角形 BLAS 放入两个实例的 TLAS；现在要真的发射射线。类比光栅化：光栅化的 PSO 先确定 shader 集合，Draw 处理图元；DXR 用 **State Object** 定义可用的 shader/Hit Group 和绑定配置，**Shader Binding Table（SBT）**为 RayGen/Miss/Hit 选择具体 shader record，`DispatchRays` 决定发射网格大小，`TraceRay` 从 RayGen 发起遍历。State Object 与 SBT 分工不同，SBT 不是资源绑定的总替代品。

本例流水线：`HLSL -> dxc DXIL library -> State Object -> GetShaderIdentifier -> Upload Heap SBT`；另一条是 `VB/IB -> BLAS -> 两个实例 -> TLAS`；二者汇合于 `DispatchRays -> Default Heap UAV -> Readback -> CPU 校验`。代码：`learning/sandbox/d3d12/r11-01-minimal/dxr_minimal_pipeline.cu` 与 `learning/sandbox/d3d12/r11-01-minimal/dxr_minimal.hlsl`。

## 2. GPU 上到底执行了什么

HLSL 第 3–5 行声明 `RaytracingAccelerationStructure scene : register(t0)`、`RWStructuredBuffer<uint> output : register(u0)` 和 4 字节 `Payload`。`[shader("raygeneration")] RayGen` 用 `DispatchRaysIndex().x` 生成 8 条沿 +Z 方向的射线，`RayDesc` 的 `Origin`、`Direction`、`TMin=0.001`、`TMax=100` 定义起点、方向和有效距离（不是 R.12 的有限光源阴影射线）；`TraceRay(scene, RAY_FLAG_NONE, 0xff, 0, 0, 0, ray, payload)` 用 0xff 实例遮罩、一个 ray type、Miss 表 0 号记录。RayGen 在 `TraceRay` 返回后才把 payload 写入 `output[x]`。见 HLSL 第 7–26 行。

三角形局部坐标为 `(0,1,0),(-1,-1,0),(1,-1,0)`；两实例共用 BLAS，第二个 x 平移 3，ID 分别为 1/2（C++ 第 108–144 行）。设计的 x=3 和 x=7 的 Origin 被置于远处，因此 Miss；其他射线分别命中两个实例。`Miss` 写 0；`ClosestHit` 通过 `InstanceID()` 写 1 或 2。初值 `0xffffffff` 是防止遗漏 Miss/Hit 时误以为结果正确的哨兵。`BuiltInTriangleIntersectionAttributes` 在本例不使用，其三角形重心坐标配置需 8 字节；`InstanceID()` 读取应用写入的自定义字段，**可重复，不是 `InstanceIndex()`**（HLSL 第 28–34 行）。结果是整数标签而非真正的 RGB 颜色，也没有屏幕窗口。

## 3. 资源准备：AS、Global Root Signature、DXIL

C++ 第 88–105 行先打开 Debug Layer、选硬件适配器，创建 `ID3D12Device5` 并用 `CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS5, &options, sizeof(options))` 检查 RaytracingTier；没有设备/Tier 则报错退出。使用 Direct 命令队列、allocator、`ID3D12GraphicsCommandList4` 和 fence。DXIL 从命令行指定的本地文件读取；文件不存在/为空失败，不会假装能直接运行 HLSL（第 84–107 行）。

`GetRaytracingAccelerationStructurePrebuildInfo(&inputs,&info)` 分别查询 BLAS/TLAS Result 和 Scratch 字节需求，检测零大小，按 256 字节对齐分配。BLAS 指向 3 个顶点/索引；TLAS 的 `D3D12_RAYTRACING_INSTANCE_DESC` 设置 3x4 Transform、InstanceMask、`InstanceID`、`InstanceContributionToHitGroupIndex=0` 和相同 BLAS GPU VA。实例描述符数组驻留 Upload Heap（第 109–151 行）；只在 GPU 完成前保持不变。构建 Result 是 Default Heap UAV 能力的 AS 资源，Scratch 是 Default Heap UAV；构建前把 Scratch 从 COMMON 转到 UAV。AS 的大小和状态与 shader table 不是一回事。

全局 Root Signature（第 153–168 行）含两个 **root descriptor**：参数 0 是 `SRV(t0)`，直接给 TLAS GPU 虚拟地址；参数 1 是 `UAV(u0)`，直接给 8 个 `uint32_t` 的输出缓冲 GPU 虚拟地址。这是 buffer/AS 的简化直绑，不创建 descriptor heap，也不需要 `SetDescriptorHeaps`；不是“空 Root Signature”，更不是任意纹理都能用 root descriptor。`D3D12SerializeRootSignature` 失败时输出编译消息和 HRESULT，`CreateRootSignature` 失败也有 HRESULT。命令中调用 `SetComputeRootSignature`、`SetComputeRootShaderResourceView(0,...)`、`SetComputeRootUnorderedAccessView(1,...)`；这里的 compute 命令列表接口用于 DXR 全局根绑定，不表示这是普通 compute shader（第 217–220 行）。

本机 DXC 用 `-T lib_6_3` 把包含三个 `[shader(...)]` 入口的 HLSL 编为 DXIL **library**，不是分别编成光栅 VS/PS。`D3D12_DXIL_LIBRARY_DESC` 指向文件内容；State Object 内还有：`D3D12_HIT_GROUP_DESC` 导出 `HitGroup` 并导入 `ClosestHit`（类型 TRIANGLES）；`D3D12_RAYTRACING_SHADER_CONFIG` 的 `MaxPayloadSizeInBytes=4`、`MaxAttributeSizeInBytes=8`；`D3D12_GLOBAL_ROOT_SIGNATURE`；`D3D12_RAYTRACING_PIPELINE_CONFIG` 的 `MaxTraceRecursionDepth=1`，本例没有递归 TraceRay。五个 subobject 填入 `D3D12_STATE_OBJECT_DESC`，类型 `D3D12_STATE_OBJECT_TYPE_RAYTRACING_PIPELINE`，经 `ID3D12Device5::CreateStateObject(&sod, IID_PPV_ARGS(&state))` 创建（第 170–190 行）。这里不关联 local root signature；`ClosestHit` 是 hit group 的成员，**Hit SBT 记录找的导出名是 `HitGroup`，不是 `ClosestHit`**。创建失败输出 HRESULT。

## 4. SBT：Identifier、32/64 字节对齐和命中索引

`ID3D12StateObjectProperties::GetShaderIdentifier(exportName)` 分别查询 `RayGen`、`Miss`、`HitGroup`，NULL 即失败；返回的 32 字节标识符只在相应 State Object 的有效期内有意义，不能当成代码地址或预设常数（第 191–202 行）。每个 **shader record** = `[32B identifier][可选 local root arguments][填充到 32B 倍数]`。本例没有 local root 数据，故每条 record 恰为 32B；`D3D12_RAYTRACING_SHADER_RECORD_BYTE_ALIGNMENT=32` 约束 record stride；`D3D12_RAYTRACING_SHADER_TABLE_BYTE_ALIGNMENT=64` 约束每个表的起始 GPU 地址。两种对齐不是同一个概念。

布局（C++ 第 193–203、221–227 行；表本体为上传缓冲且起始 GPU VA 满足对齐）：

```text
sbt[0..31]    RayGen identifier     表起点 base+0；record 大小 32
sbt[32..63]   padding               为下一张表凑 64 对齐
sbt[64..95]   Miss identifier       表起点 base+64；stride=32,size=32
sbt[96..127]  padding
sbt[128..159] HitGroup identifier   表起点 base+128；stride=32,size=32
sbt[160..191] padding
```

注意 **表的 64 字节间距不是每条 record 的 stride**；表内部这里只有一条 32 字节 record。`D3D12_DISPATCH_RAYS_DESC` 的 `RayGenerationShaderRecord` 为 `{base,32}`，`MissShaderTable` 为 `{base+64,32,32}`，`HitGroupTable` 为 `{base+128,32,32}`；`CallableShaderTable` 留空（不使用 callable），`Width=8, Height=1, Depth=1`。`SetPipelineState1(state.Get())` 后 `ID3D12GraphicsCommandList4::DispatchRays(&dispatch)` 提交命令；调用录制命令，不是 CPU 在调用时同步算出结果。详见第 220–228 行。

三角形命中表的常用索引式：`HitGroupIndex = RayContributionToHitGroupIndex + InstanceContributionToHitGroupIndex + GeometryIndex * MultiplierForGeometryContributionToHitGroupIndex`。这里 `TraceRay` 的贡献=0、乘数=0；两个实例的 contribution 都=0；BLAS 只有一个三角形 geometry，故最终都为 0，选择 **同一条 HitGroup record**。结果 1/2 不同只是 `ClosestHit` 读取 InstanceID 的结果不同；本例并没有证明不同实例选不同 hit group。`MissShaderIndex=0` 选择唯一 Miss record。`InstanceID` 的 24-bit 字段、另一个 24-bit hit-group contribution 字段、`InstanceIndex()` 与 TLAS 实例数量上限是不同概念；本机 SDK 定义单个 TLAS 上限 `D3D12_RAYTRACING_MAX_INSTANCES_PER_TOP_LEVEL_ACCELERATION_STRUCTURE=16777216`，不要由 `NumDescs` 是 UINT 反推可放 2^32 个，也不要把实例数量限制简单归因于 `InstanceID` 位宽。

后续 local root 部分才会在 shader identifier 后放 local root arguments（例如材质索引/地址），配置相应 local root signature 与 export association，并由 GPU 验证布局；**本课没有做，也没验证 local root 被读取**。

## 5. 命令顺序、资源状态、CPU/GPU 所有权

同一条 Direct command list：先 `COMMON -> UNORDERED_ACCESS` 转换 BLAS/TLAS Scratch；`BuildRaytracingAccelerationStructure` 建 BLAS；对 BLAS Result 做 UAV barrier（构建写 -> TLAS 构建读）；建 TLAS；对 TLAS Result 做 UAV barrier（构建写 -> TraceRay 遍历读）。普通输出 Default buffer 创建为 COMMON，再显式转为 UAV：不能假定传给 `CreateCommittedResource` 的 UAV InitialState 真生效；第一次试运行就被 Debug Layer 警告该初始状态被忽略，改成显式 transition 后零警告。见 C++ 第 204–217 行。

`DispatchRays` 写输出 UAV 后做 `UNORDERED_ACCESS -> COPY_SOURCE` transition，并 `CopyResource(readback,output)`；Readback buffer 创建在 `COPY_DEST`（第 204–205、228–230 行）。命令列表 `Close`、提交到 queue、队列 `Signal(fence,1)`、CPU `SetEventOnCompletion`/等待，**等 GPU 完成后**才 `Map` Readback 并逐元素检查（第 231–251 行）。同一队列的命令顺序、必要的 UAV barrier / state transition 管 GPU 间依赖；fence 管 CPU 何时能读取 Readback、重置 allocator、复用或释放仍被 GPU 使用的 Upload/SBT/实例缓冲和 Scratch。本例只有单次提交，不实现多帧环形上传，也不证明 `Unmap` 代表 GPU 已用完。

`verify_messages` 统计 Debug Layer 的 ERROR/CORRUPTION 和 WARNING；有警告即退出失败。HRESULT 经 `check` 打印；DXIL 缺失、export 找不到、预构建尺寸为零、设备不支持等经 `require` 报错。校验 `expected={1,1,1,0,2,2,2,0}` 后才能打印 PASS。能力检查和 Debug Layer 不能替代完整的设备移除处理/GPU validation，也不代表大场景稳定性测试。

## 6. 本机构建与已记录的真实验收

在 **仓库根目录** PowerShell 中执行（`.dxil`/`.exe` 是生成产物，不是课程源文件；`build.ps1` 内部用 VS2022 + `nvcc -arch=sm_120` 构建 `.cu`）：

```powershell
& 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\dxc.exe' -T lib_6_3 -Fo learning/sandbox/d3d12/r11-01-minimal/dxr_minimal.dxil learning/sandbox/d3d12/r11-01-minimal/dxr_minimal.hlsl
& .\learning\sandbox\build.ps1 learning\sandbox\d3d12\r11-01-minimal\dxr_minimal_pipeline.cu -NoRun
& .\learning\sandbox\d3d12\r11-01-minimal\dxr_minimal_pipeline.exe .\learning\sandbox\d3d12\r11-01-minimal\dxr_minimal.dxil
```

上次实现阶段在本机 RTX 5070 的**实际运行记录**（本次笔记工作仅核对已有代码和输出，不冒充新一轮执行）：

```text
Debug Layer: enabled
adapter: NVIDIA GeForce RTX 5070
raytracing tier: 11
ray[0] = 1 (expected 1)
ray[1] = 1 (expected 1)
ray[2] = 1 (expected 1)
ray[3] = 0 (expected 0)
ray[4] = 2 (expected 2)
ray[5] = 2 (expected 2)
ray[6] = 2 (expected 2)
ray[7] = 0 (expected 0)
Miss=2 ClosestHit(ID=1)=3 ClosestHit(ID=2)=3
InfoQueue: errors=0 warnings=0
DispatchRays: PASS
```

第一次运行虽然读回预期数值，Debug Layer 对输出缓冲初始 UAV 状态给出 1 条 WARNING，严格验收退出失败；修复为 COMMON 创建 + 显式 UAV transition 后重编译、复跑才得到上述 PASS。Tier 输出 `11` 是枚举数值，对应 Tier 1.1，不是“11 级”。

## 7. 商业引擎对照、动手和后续

商业引擎通常把 AS、材质、多个 ray type、不同 hit group、local root/descriptor tables、SBT 和多帧 Upload Ring 抽象为场景/渲染图的资源与生命周期，并把结果写入纹理呈现；本课故意用 8 个整数 + CPU readback，便于独立验证着色器调用链。共同底层机制仍是 AS 遍历、State Object、SBT record 选择、资源状态与 fence。

动手：用上述命令复跑，先预测 8 个标签；再只在纸上推导“若第二实例 `InstanceContributionToHitGroupIndex=1`，hit table 至少需要什么 record”，不要直接改为 1 而不添加第二条有效 hit-group record，避免越界选择。自测：① 32B identifier 与 64B 表起点分别限制什么？② 为什么两个不同 InstanceID 的输出**不**证明使用了两个 hit group？③ 为什么 `Unmap` 后仍须等 fence 才能安全覆写 SBT？

下一部分仍属 **R.11**：真实窗口、两个不同 Hit Group/材质索引、local root arguments 在 CPU record 和 GPU 着色器间的逐字节验证。R.12 再处理阴影射线，R.13 再处理主射线累积；不要提前把第一部分的 PASS 扩大为完整路径追踪器。

参考：Microsoft [DirectX Raytracing](https://learn.microsoft.com/en-us/windows/win32/direct3d12/directx-raytracing)、[D3D12 API](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/)、[资源屏障](https://learn.microsoft.com/en-us/windows/win32/direct3d12/using-resource-barriers-to-synchronize-resource-states-in-direct3d-12)、[根签名](https://learn.microsoft.com/en-us/windows/win32/direct3d12/root-signatures)；精确结构体/常量以本机 Windows SDK `d3d12.h` 为准。
