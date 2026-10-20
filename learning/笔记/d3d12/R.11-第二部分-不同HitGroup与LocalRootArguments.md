# R.11 第二部分：不同 Hit Group 与 Local Root Arguments

## 1. 目标、范围与真实验收

第一部分的两个实例选择同一条 Hit record，只凭 InstanceID 返回 1/2；第二部分新增独立 `dxr_local_root_pipeline.cu` 与 `dxr_local_root.hlsl`，保留第一部分源码不变。现在两个实例使用相同 InstanceID=7，但 InstanceContributionToHitGroupIndex 分别为 0/1，真正选择 HitGroupA/HitGroupB 以及各自 ClosestHitA/B。每条 record 后跟两个 local root DWORD（material、cookie），GPU 返回程序标记与两个参数的组合结果。

2026-10-08 本机 Windows SDK DXC + VS2022/nvcc sm_120 编译、RTX 5070 Tier 1.1 实测：正常与 `--swap-local` 对照均 PASS，D3D12 Debug Layer 都是 0 error / 0 warning。窗口仍未完成；多 geometry/多 ray type、local root GPU 地址/descriptor table、AnyHit/纹理材质、多帧 SBT 管理尚未验收。多 geometry 是后续加深范围，不改写原计划的窗口要求。R.11 保持 [~]。

## 2. 直觉：同一场景、不同调用卡

Hit Group 是程序组合；record 是调用卡，不是射线类型。第一部分的卡只含 identifier；第二部分卡带上局部数据。全局资源 t0/u0 像本次 dispatch 共享的场景与输出，local b0 像每张调用卡上的材质参数。生产引擎常将很多 record 指向共享 shader 并传材质索引/地址，本课刻意用两段 ClosestHit 的 A/B 标记，先明确验证程序选择；cookie 则是检查参数字节顺序的测试数据，不是生产材质设计。

## 3. 四层关系与 API

源文件为 `learning/sandbox/d3d12/r11-02-local-root/dxr_local_root_pipeline.cu`（以下 C++ 行号基于本次版本）和同目录 `dxr_local_root.hlsl`。

- 资源层：一个三角形 BLAS、两个 TLAS 实例、Upload SBT、Default UAV、Readback。BLAS/TLAS Result 保持 RAYTRACING_ACCELERATION_STRUCTURE；Scratch 转 COMMON→UAV。构建不是绑定 shader u0 来写 AS。
- 访问层：TraceRay 读 t0，RayGen 写 u0；Build 写 Result 后的 UAV barrier 保证后续构建/遍历依赖，不把 AS 转成普通 UAV 状态。
- 绑定层：Global Root Signature 的 t0/u0 在命令列表用 SetComputeRoot... 设置；Local Root Signature 规定 b0 参数布局，数据来自选中的 Hit record，不通过 SetComputeRoot32BitConstants 提交。
- 程序选择层：实例 contribution→Hit record→HitGroup identifier→ClosestHitA/B；InstanceID=7 仅作为结果最低字节，与记录选择无关。

C++ 第 138–145 行设置两个实例 contribution=i，第二个实例 x 平移 3，两者 InstanceID=7、mask=0xff、共享 BLAS。HLSL 第 30 行 `TraceRay(scene,RAY_FLAG_NONE,0xff,0,0,0,ray,payload)`：TLAS、射线标志、包含遮罩、ray contribution、geometry multiplier、Miss index、RayDesc、可修改 payload。公式为 `HitIndex=InstanceContribution+GeometryIndex*Multiplier+RayContribution`；这里唯一 geometry，后两项为零，因此索引为 0/1。几何乘数不是强制每个 geometry 配几条 record；本节没有第二种射线用途。

### Local Root Signature：规则与值分离

C++ 第 173–189 行：`D3D12_ROOT_PARAMETER lp` 的 ParameterType=32BIT_CONSTANTS，Constants.ShaderRegister=0、RegisterSpace=0、Num32BitValues=2；对应 HLSL 第 8–11 行 `cbuffer LocalData : register(b0)` 中 material/cookie。ShaderVisibility=ALL；根签名描述 Flags=LOCAL_ROOT_SIGNATURE。调用 `D3D12SerializeRootSignature(&lrd,version,&blob,&error)` 把布局序列化；错误 blob 在失败时打印，HRESULT 经 check 终止。`CreateRootSignature(0,blob指针,blob大小,IID_PPV_ARGS(&local_root))` 创建对象，0 是 node mask。本例两个 DWORD 内联，不是 CBV 指针，不需为它们分配 256B constant buffer。

Global signature 仍只有 SRV t0/UAV u0（第 158–171 行），Local 只有 b0；二者寄存器绑定不冲突。并不是将 local signature 关联到 global signature：Global subobject 提供全局绑定规则，Local subobject 经 export association 提供各个 Hit Group 的局部规则。

### State Object associations

C++ 第 191–222 行固定 `D3D12_STATE_SUBOBJECT sub[8]`：DXIL library、两个 Hit Group、shader config(payload 4B/attributes 8B)、global root、pipeline config(递归深度1)、local root、association。HitGroupA/B 分别导入 ClosestHitA/B，类型 TRIANGLES，不含 AnyHit/Intersection。

`D3D12_SUBOBJECT_TO_EXPORTS_ASSOCIATION` 的 pSubobjectToAssociate=&sub[6] 指向 Local Root Signature subobject，NumExports=2，pExports 为 HitGroupA/B 两个导出名。GPU 据此解释两类 Hit record 的附加参数；RayGen/Miss 不使用 b0。association 与其目标在同一固定数组中，不能容器扩容后让指针失效。`CreateStateObject(&sod,IID_PPV_ARGS(&state))` 消费本次创建描述；所有描述和 DXIL 字节在创建期间有效，COM 对象在 GPU 工作期间保持存活。失败打印 HRESULT；GetShaderIdentifier 返回 null 也立即失败。

## 4. SBT 字节布局与对齐

C++ 第 224–250 行用 unsigned char 数组和 memcpy 显式排布，而非依赖 C++ struct 自动 padding。

```text
绝对偏移 0..31      RayGen identifier（无 local 参数）
绝对偏移 64..95     Miss identifier（无 local 参数）
绝对偏移 128..191   Hit record 0
  相对 +0..31       HitGroupA identifier：32B
  相对 +32..35      material：DWORD（默认 0x11）
  相对 +36..39      cookie：DWORD（默认 0x5a）
  相对 +40..63      padding：24B
绝对偏移 192..255   Hit record 1，同布局，HitGroupB + (0x22,0xa5)
```

identifier 从 GetShaderIdentifier 获取，32B opaque token，不是自行构造的函数地址。local arguments 共8B，所以 record 内容40B，按 record alignment32B向上取整得到 stride64B。每张 table 起点64B对齐；本次数值也为64，但不是同一种要求。CPU 检查 buffer GPU VA 的64B对齐，static_assert检查 record stride；Hit表从base+128开始，有两条64B记录，SizeInBytes=128、StrideInBytes=64。RayGen大小32，Miss大小32/stride32。详见 C++ 第 267–272 行。SBT从 Upload Heap GPU直接读取，整个提交完成前不可覆写，即使已Unmap。

## 5. GPU 输出如何同时验证程序与数据

HLSL 第 40–47 行两个 ClosestHit 分别用 A/B 高四位标记，输出 `(A或B)<<28 | material<<16 | cookie<<8 | InstanceID`，material/cookie仅取低8位；本例ID=7。每个返回 uint 含三项独立证据：程序选择、局部第一个参数、局部第二个参数。RayGen只有一份，前三射线命中A，4/5/6命中B，3/7 Miss返回0。

正常模式：A=(0x11,0x5a)→0xa0115a07；B=(0x22,0xa5)→0xb022a507。

`--swap-local` 只交换 CPU 写入的两组参数，不改变 instance contribution、shader identifier、shader代码：A→0xa022a507；B→0xb0115a07。因此标记不动、两个参数字节一起交换。比仅观察两个不同颜色更明确：结果不仅来自硬编码A/B，也确实受SBT内联参数影响。两个InstanceID相同排除了ID分支造成伪验证。

## 6. 同步、所有权与失败边界

同一 direct queue 单次提交：Build BLAS→BLAS UAV barrier→Build TLAS→TLAS UAV barrier→输出COMMON转UAV→全局绑定+StateObject+DispatchRays→输出UAV转COPY_SOURCE→CopyResource(Readback,Output)→Close/Execute→Signal fence1→CPU等待→Map Readback核对8项。transition负责UAV写到copy读的状态/同步，不额外重复加输出UAV barrier。详见C++第257–301行。

Map不会自动等待GPU；Unmap也不是GPU完成事件。Upload VB/IB/instance/SBT、AS Result/Scratch、root signatures、State Object与命令对象均在本次fence完成前保留；读回映射声明CPU读范围32B，Unmap写范围0。严格要求Debug接口及InfoQueue可用，否则失败；有warning/error也失败，预期数组任何不一致则返回1。当前未开GPU-based validation，零Debug消息不等于验证所有运行时风险；设备移除超时恢复和多帧队列管理不属于本最小示例。

## 7. 真实命令和运行结果

仓库根目录 PowerShell（命令已实际执行，DXC与C++均编译成功）：

```powershell
& 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\dxc.exe' -T lib_6_3 -Fo learning/sandbox/d3d12/r11-02-local-root/dxr_local_root.dxil learning/sandbox/d3d12/r11-02-local-root/dxr_local_root.hlsl
& .\learning\sandbox\build.ps1 learning\sandbox\d3d12\r11-02-local-root\dxr_local_root_pipeline.cu -NoRun
& .\learning\sandbox\d3d12\r11-02-local-root\dxr_local_root_pipeline.exe .\learning\sandbox\d3d12\r11-02-local-root\dxr_local_root.dxil
& .\learning\sandbox\d3d12\r11-02-local-root\dxr_local_root_pipeline.exe .\learning\sandbox\d3d12\r11-02-local-root\dxr_local_root.dxil --swap-local
```

build.ps1 初始化VS2022，用nvcc -arch=sm_120 -std=c++17构建。shader的目标是lib_6_3，不是sm_120；.cu仅承载Windows/D3D12宿主代码，本节没有CUDA kernel。DXIL是DXC编译产物，exe由nvcc/MSVC构建；没有提交生成产物。

```text
adapter: NVIDIA GeForce RTX 5070
raytracing tier: 11
normal:
ray[0..7] = a0115a07 a0115a07 a0115a07 00000000 b022a507 b022a507 b022a507 00000000
swap-local:
ray[0..7] = a022a507 a022a507 a022a507 00000000 b0115a07 b0115a07 b0115a07 00000000
两次各自：
Miss=2 HitGroupA+local=3 HitGroupB+local=3
InfoQueue: errors=0 warnings=0
DispatchRays + local root: PASS
```

以上两行ray数组为工具逐条输出的等价汇总，不冒充程序原始行格式。first-part源码/讲义与学习计划保持不变。

## 8. 自测与后续

1. 为什么两个InstanceID都是7，仍能执行不同ClosestHit？答：contribution0/1选择不同Hit record，record identifier决定HitGroup。
2. 为什么identifier32B+参数8B的record stride不是40？答：须是32B倍数，向上取64，尾部填充24B。
3. 为什么没有SetComputeRoot32BitConstants却能读b0？答：b0是local，参数来自SBT；global t0/u0仍从命令列表设置。

接下来R.11窗口呈现仍必须完成；多geometry/multi-ray-type、共享shader不同材质record以及更复杂local布局作为后续深化。本节不提前宣称阴影/积分器完成。

权威资料：
- DXR规范：https://microsoft.github.io/DirectX-Specs/d3d/Raytracing.html
- Local Root Signature：https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ns-d3d12-d3d12_local_root_signature
- Export association：https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ns-d3d12-d3d12_subobject_to_exports_association
- Shader identifier：https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12stateobjectproperties-getshaderidentifier
