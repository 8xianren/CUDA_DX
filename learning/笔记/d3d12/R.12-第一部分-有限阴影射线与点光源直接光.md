# R.12 第一部分：有限阴影射线与 PT.5 点光源直接光

## 正式授课记录（2026-10-09）

R.11 已统一收束；本页 2026-10-08 的实现属于预备材料，不代表当时已完成授课。2026-10-09 用户明确请求开始 R.12，正式从本小节讲起。当天重新执行 DXC `lib_6_3`、build.ps1 `sm_120` 宿主编译及 RTX 5070 运行：10 组结果符合预期，Fence 1/1，Debug Layer 0 error / 0 warning，退出码 0。R.12 保持进行中；面积光 NEE 留待第二部分。

本节目标：能解释为什么 shadow payload 可以默认 0、只在 Miss 写 1，能配置有限 RayDesc 并说清两个 RayFlags、Miss 索引、InstanceMask、递归深度和 CPU 读回同步的独立职责。

### 从游戏中的视线查询建立直觉

主射线问最近命中的表面是谁，阴影射线问表面到灯之间有没有不透明阻挡。后者只需要存在性结果，不需要最近阻挡的材质颜色。这里的“第一个命中”是遍历中第一个被接受的候选，不保证几何距离最近；用于不透明二值可见性仍正确。

调用关系为 RayGen 主 TraceRay → SurfaceHit → 阴影 TraceRay → ShadowMiss 或接受遮挡并跳过 ClosestHit → 回到 SurfaceHit → 回到 RayGen → 写 UAV。逻辑上阴影 TraceRay 返回后读取已更新的 payload；这不是 CPU/GPU Fence，也不意味着所有 GPU 射线串行执行。

### RayDesc 的三个不同边界

真实字段顺序为 float3 Origin、float TMin、float3 Direction、float TMax。P(t)=Origin+t Direction；只有单位方向时 t 才直接表示距离。本例起点 z=0.0001，灯 z=2，所以 shadowDistance=1.9999，常规 TMax=1.9989；世界空间终点约为 z=1.999。

Origin bias 移动整条射线的起点；TMin 从该起点再裁掉一段；TMax 限制终点。三者不能当同一个 epsilon。若灯太近以致区间无效，通用实现应在调用前检查；本例固定距离 2 没有完整退化输入处理。

光照公式使用原始着色点到灯的 distance=2；阴影参数使用偏移后 shadowDistance=1.9999。偏移用于数值查询，不能顺手把物理照明的距离也改掉。

### TraceRay 参数和 SBT

八个参数为 TLAS、flags、instance inclusion mask、ray hit-record contribution、geometry contribution multiplier、miss index、RayDesc、inout payload。

本例主射线 `(scene,NONE,1,0,0,0,ray,p)`；阴影 `(scene,FIRST_HIT|SKIP_CLOSEST,mask,0,0,1,shadow,s)`。hit index 三项全为 0，因此只有一条 HitGroup record；Miss 表则有 PrimaryMiss 和 ShadowMiss 两条。不是靠 payload 类型自动选择入口。

ShadowPayload 只有 visible 一个 uint，4B；PrimaryPayload 为 test、visible、quantized 三个 uint，12B。它们属于各次调用的逻辑 payload，不是 Root Signature 描述的资源，也不是 SBT 的内容。shader config 声明最大 payload 12B；triangle attributes 的 float2 重心坐标另计 8B。不要把这些逻辑尺寸解释为硬件物理寄存器分配。

阴影预置 visible=0；所有几何为 OPAQUE，无 AnyHit。接受遮挡后跳过 ClosestHit，payload 保持 0；只有无有效命中才运行 ShadowMiss 并设为 1。SKIP_CLOSEST_HIT 不代表跳过求交，也不把 hit 变成 miss。删除该 flag 会让阴影调用进入接收 PrimaryPayload 的 SurfaceHit，破坏 payload 契约并可能继续发射射线，不能作为安全实验。

AnyHit 是可在候选交点检查 Alpha 并 IgnoreHit 的着色器；名字不表示“开启存在性查询”。当前全 opaque 不需要它。透明度、透射与通用材质读取后续再处理。

InstanceMask 由 TLAS 实例设置；射线 mask 与其按位与非零才考虑该实例。接收面=01，挡板=10；主射线01只见接收面，正常阴影11两者都见。flags 控制遍历/着色行为，mask 控制哪些实例参与；都不自动定义“阴影材质”。

### 递归与数学

MaxTraceRecursionDepth=2，因为主 TraceRay 尚未返回时，ClosestHit 中又调用一次 TraceRay。它表示最大同时嵌套层数，不表示两次光照反弹；本课没有间接光。超过配置深度有设备移除风险，不作为动手实验。

PT.5 点光公式 Lo=V*(rho/pi)*I*cos/r²；本课 rho=.5、I=8、r=2、cos=1，因此无遮挡 Lo=1/pi≈.318309886。UAV 存 round(Lo*1e6)=318310，目的是数值验收，不是显示编码。V=2 是主射线 Miss 的输出分类，不能当作真实可见性乘进光照。

### 资源和失败路径

Global Root 的 t0 绑定 TLAS GPU VA，u0 绑定输出 buffer GPU VA；每测试 uint2 为 8B，共80B。没有 local root arguments。SBT 中只存32B标识符：RayGen@0，PrimaryMiss@64，ShadowMiss@96，HitGroup@128；Miss stride32，table起点64对齐。

BLAS构建后 UAV barrier 使 TLAS 构建可读；TLAS构建后 UAV barrier 使 TraceRay 可读；输出从 UAV 转 COPY_SOURCE 后复制到 COPY_DEST Readback。CPU 提交后 Signal fence1，等待完成再 Map；Map本身不保证 GPU 已写完。Upload、SBT、加速结构等资源在本例全部保持到 Fence 后再释放。

编译失败不运行后续阶段；缺DXIL、缺导出、HRESULT失败、Fence等待失败都报错退出，Debug warning/error 及数值不符均视为验收失败。当前没有GPU-based validation或设备移除恢复流程，Debug0/0不等于所有可能行为都已验证。

固定+Z法线与从下方发出的测试主射线，是本例分离遍历与阴影的诊断设置，不是通用单面反射材质或相机成像方案；没有背面剔除，亦未基于视线翻转法线。真实渲染器需处理几何/着色法线、正反面和材质约定。

### 本节动手

先运行本页命令并预测 case1/2、case3/9 两组：前一组只有 TMax 行为不同，后一组只有 inclusion mask 对挡板的包含关系不同。自测：阴影命中后为什么可以完全没有 ShadowClosestHit？为什么 SKIP_CLOSEST 不会调用 ShadowMiss？为什么深度2不等于两次反弹？下一部分将复用相同可见性查询，接入 PT.5 矩形采样与方向 PDF。

## 范围与验收

2026-10-08，新建独立 dxr_shadow_pipeline.cu / dxr_shadow.hlsl，R.11 第一/二/三部分与 PT.5 保持不变。RTX 5070 / Tier 1.1，DXC lib_6_3、build.ps1 默认 sm_120 真编译运行，十组对照全部通过；Fence target=1 completed=1，InfoQueue errors=0 warnings=0，进程退出0、stderr空。本节只是确定性点光源直接光，不是完整路径追踪，也没有面积光蒙特卡洛采样。

R.12计划要求单面发光/cos_light约定与CPU NEE一致，此部分尚未迁移，保持[~]。点光源没有面积光源的cos_light或有限面积PDF，不能为凑齐验收硬套面积公式。

## 从 PT.5 到 DXR

PT.5 `learning/sandbox/path_tracing/pt05-direct-lighting/pt5_direct_lighting.cu` 第74–80行 visible：起点沿法线偏移，有限区间内检测球体遮挡；第93–98行 direct_point：I*(rho/pi)*cos_surface/r²乘可见性。面积采样在85–89行另用 Le*(rho/pi)*cos_surface*V/pdf_omega。DXR更换的是遍历/求交后端，数学积分规则不由API自动实现。

本节HLSL第26–53行在真实主射线ClosestHit中求世界命中点：WorldRayOrigin()+RayTCurrent()*WorldRayDirection()。固定法线+Z仅适用于本课平移接收面，不称为通用法线插值。

光源在命中点正上方2单位，rho=.5、强度I=8（标量辐射强度模型），Lo=V*(rho/pi)*I*max(n·wi,0)/r²；可见时1/pi≈.318309886，量化round(Lo*1e6)=318310。CPU用double独立计算解析参考，容许1个量化单位；不是像素最终sRGB值。

## 调用链与payload

RayGen发主射线→SurfaceHit→Shadow TraceRay→阴影Miss或接受遮挡→SurfaceHit返回→RayGen写UAV。

主payload为test/visible/quantized三个DWORD(12B)，阴影仅visible一个DWORD(4B)。shader config声明最大12B；pipeline MaxTraceRecursionDepth=2，因为在主TraceRay内再次TraceRay。两层嵌套不等于两次路径反弹：这里只有直接光可见性查询。

TraceRay的参数依次是AccelerationStructure、RayFlags、InstanceInclusionMask、RayContributionToHitGroupIndex、MultiplierForGeometryContributionToHitGroupIndex、MissShaderIndex、RayDesc、inout payload。主调用(第17行)为mask1、偏移0、乘数0、Miss0；阴影(第46–47行)为mask1或3、偏移0、乘数0、Miss1。所有instance contribution为0，只有一个SurfaceHit record。

Shadow visible预置0，flags=ACCEPT_FIRST_HIT_AND_END_SEARCH | SKIP_CLOSEST_HIT_SHADER。几何OPAQUE无AnyHit：遇到有效遮挡即保留0、无需运行ClosestHit；全段Miss才由ShadowMiss置1。因此不需要另一个Shadow HitGroup；两种射线用途仍由应用定义而非DXR类型。绝不能把4B ShadowPayload送进12B SurfaceHit：这里靠明确跳过ClosestHit避免不兼容，DXR不替应用做语义自动识别。透明材质需AnyHit或其他透射模型，本节不包含。

## 场景与成对验证

C++第136–155行：同一个三角形BLAS以平移方式实例化成9个接收面和8个挡板，TLAS共17实例。接收mask1、挡板mask2，主射线只见接收。各列x=4*test，三角形互不干扰；test8射向x100产生主Miss。

|case|场景/参数|V|Q|
|---|---|---:|---:|
|0|无挡板|1|318310|
|1|挡板z3，光源z2，有限TMax|1|318310|
|2|同样z3但故意TMax=4|0|0|
|3|挡板z1，shadow mask1排除挡板|1|318310|
|4|挡板z.0005，TMin=.001|1|318310|
|5|同样z.0005，TMin=.00001|0|0|
|6|挡板z1.9995，TMax=distance-.001|1|318310|
|7|同样端点附近挡板，TMax=distance+.001|0|0|
|8|主射线Miss，分类2|2|0|
|9|同样z1挡板，shadow mask3包含挡板|0|0|

V=2只是CPU输出协议的“主Miss”，不是物理可见性。

Origin=x+.0001*n，方向正规化；本节从偏移后的origin重新算到光源距离shadowDistance，再做TMax=shadowDistance-.001。PT.5原代码用未偏移距离减epsilon，此处为明确端点采用更严格的一致参数化；没有修改CPU原课。

TMin、Origin bias、TMax的三项影响不同：bias移动起点，TMin裁去起点附近区间，TMax限定光源前端点。case4/6故意展示它们也会忽略真实薄挡板：固定epsilon不是无偏稳健性万能方案，会漏光。商业引擎一般需尺度/误差驱动偏移和透明材质处理。本课用较大可测epsilon把影响隔离，不能直接当生产配置。

InstanceMask与InclusionMask按位与非零才参与射线；mask1排除mask2，mask3包含1和2。Flags不负责选择这些应用角色。

## 资源、SBT及同步

C++第167–181行global root：t0 root SRV为TLAS VA，u0 root UAV为RWStructuredBuffer<uint2> VA。本例buffer不是R.11窗口纹理，故可以不用descriptor heap。输出80B，各测试相邻8B；CPU按values[2*i]/[2*i+1]读V/Q。

SBT布局：RG@0；Miss表@64，PrimaryMiss@64、ShadowMiss@96，Size64/Stride32；Hit表@128，Size32/Stride32。每记录identifier32B，无local参数；table起点64B对齐，单条record并不必须64B对齐。State Object五个subobject=library/HitGroup/shader config/global root/pipeline config。

Build BLAS→UAV barrier→Build TLAS→UAV barrier→输出COMMON→UAV→DispatchRays→输出UAV→COPY_SOURCE→CopyResource到Readback(COPY_DEST)→Close/Execute→Signal fence1→等最多10秒→Map。barrier保证GPU依赖，Fence保证CPU读回时机和Upload VB/IB/实例/SBT及AS资源所有权；Unmap不是GPU完成。Map范围80B，Unmap CPU写范围0，全部COM资源保持到fence后。没有Present，故不涉及第三部分呈现队列退出问题。HRESULT、缺失export、fence等待失败和Debug warning/error都会导致失败；数值不符返回1。

## 真执行命令与输出

在仓库根目录PowerShell：
```powershell
& 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\dxc.exe' -T lib_6_3 -Fo learning/sandbox/d3d12/r12-01-shadow/dxr_shadow.dxil learning/sandbox/d3d12/r12-01-shadow/dxr_shadow.hlsl
& .\learning\sandbox\build.ps1 learning\sandbox\d3d12\r12-01-shadow\dxr_shadow_pipeline.cu -NoRun
& .\learning\sandbox\d3d12\r12-01-shadow\dxr_shadow_pipeline.exe .\learning\sandbox\d3d12\r12-01-shadow\dxr_shadow.dxil
$LASTEXITCODE
```

真实尾部：
```text
Fence target=1 completed=1; CPU Lambert Q=318310
InfoQueue: errors=0 warnings=0
R.12 shadow / point direct: PASS
NativeExit=0
```

首次宿主生成脚本匹配旧代码失败，未生成源码、构建报C1083；已修正生成并重新完整编译。最终代码/运行通过，不将前次失败描述为成功。nvcc sm_120构建的是D3D12宿主，无CUDA kernel；DXIL目标是lib_6_3。

## 未验证与下一部分

固定+Z法线、同距离/同cos的Lambert解析参考、单BLAS几何和opaque硬阴影；未验证任意变换法线、多距离/角度扫描、精确t=0自相交、透明AnyHit、GPU-based validation、设备移除、面积光PDF/cos_light/单面发光、软阴影、MIS、间接光、窗口整合。R.12下一部分应把PT.5矩形面积光采样、朝向与可见性接上，并做CPU/GPU误差对照。

自测：为什么阴影命中不需要ClosestHit？为什么TMax不能无限长？为什么点光源没有面积PDF和cos_light？

官方参考：https://learn.microsoft.com/en-us/windows/win32/direct3d12/traceray ，https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ne-d3d12-d3d12_ray_flags ，https://microsoft.github.io/DirectX-Specs/d3d/Raytracing.html
