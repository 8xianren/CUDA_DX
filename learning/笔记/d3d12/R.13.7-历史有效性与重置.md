# R.13.7：历史有效性与重置

2026-10-14。代码入口：[r13-renderer](../../sandbox/d3d12/r13-renderer/README.md)。本节输出在`results/r13-07/`。本节实现已知状态的自动历史判定，仍无窗口/资源resize；R.13.8接显示与窗口。

## 1. 先问“我们在平均谁”

上一节维护每像素未曝光线性平均值M，假设所有样本都在估计同一个像素积分C。场景/相机状态记作θ：

    C_p(θ) = E[Y_p(θ, ξ)]

ξ是随机样本，θ是决定图像的状态。改变ξ是在同一个积分里继续取样；改变θ则可能换了目标。像素坐标仍然相同，不意味着对应同一条射线或同一组物体。

假设旧状态有N个样本、均值A，新状态有M个样本、均值B。不reset继续普通平均会得到

    mixed = (N A + M B)/(N+M)
    mixed - B = N/(N+M) * (A-B)

期望形式同理：bias=N/(N+M)*(C_old-C_new)。旧样本多时，即使累积很多新样本仍会残留旧画面。本课选择保守的全图失效：目标关键状态变了就从新目标重新累积；不尝试重投影或复杂样本复用。

适用边界：这是固定目标的渐进路径追踪预览策略，不是动态游戏的完整历史方案。它避免错误复用，但持续运动时会反复重置，无法积累高spp。全图重置也可能丢弃本来仍可使用的局部数据；本课选择易于验证的保守策略，不声称其效率最优。同帧计算多条jitter射线是合法替代，也可以每次多spp再继续分批累积，数学关系见[R.13.6第4.1节](R.13.6-像素采样与线性HDR累积.md#41-为什么分批累积而不是同一帧发很多条jitter射线)。

## 2. 目标、采样过程和显示三层

|变化|本课行为|原因|
|---|---|---|
|相机位置/方向、FOV、near、TMax|重置|射线或可见区间可能变化|
|ViewRect/输出尺寸|重置|像素索引到射线/滤波范围的映射可能变化|
|灯的Le、材质rho|重置|线性光照积分发生变化|
|几何/可见实例集合|重置|命中与遮挡关系可能变化|
|像素中心点采样 ↔ 像素区域平均|重置|积分目标/滤波定义改变|
|正常像素jitter、灯面样本变化|继续|只是同一目标的新样本|
|RNG样本序号、seed改变|继续|本课仍采用相同的采样分布与权重|
|显示曝光倍率、色调映射、sRGB编码|继续|它们位于未曝光线性历史之后|
|用户手动重新开始|重置|显式操作|

“关键状态变化”是保守充分条件：例如当前场景没有靠近近面的物体，修改near未必改变最终颜色，但我们仍reset，不尝试证明此次变化对所有像素都无影响。

### 曝光特别说明

本课链路是：未曝光线性M → E*M → tone mapping → sRGB → 量化。曝光倍率从1变2只改变显示，不需要重新追踪；Le从1倍变2倍则改变样本值，是另一个操作。

这里指显示曝光补偿，不是会改变景深、运动模糊等成像积分的物理相机设置。若引擎使用pre-exposure，把E_old*M存入历史，曝光尺度变化时必须统一尺度，例如仅针对这份线性均值可转换H_new=(E_new/E_old)*H_old；不能不转换就把不同尺度的数据混合。本课未实现pre-exposure，也不声称所有引擎的曝光控件都不触发重置。

## 3. 状态签名TargetKey如何建立

见`dxr_history_policy.h`。Key是影响目标的字段集合，不是对整个常量缓冲做memcmp，也没有依赖可能碰撞的哈希判等。

当前包含：无jitter逆VP、相机位置/near、前向/TMax、ViewRect、输出尺寸、灯强度开关、黑材质开关、实例mask、像素滤波模式和积分器版本。

明确排除：View.targetInfo.z提交序号、sampleIndex、seed、正常随机偏移、显示曝光和曲线参数。比较整个View会因提交序号每次变化而错误地每帧reset；通用C++结构还有padding不适合比较原始字节的问题。

相机矩阵使用当前确定性构造的float字段精确比较；不对持续变化的相机简单套一个epsilon然后认为历史必然有效。当前jitter只在像素坐标中施加。若以后采用投影矩阵jitter，应从不带jitter的基础相机状态构造Key，避免把采样变化误当作相机变化。

Key只覆盖当前实际实现的状态：场景变化使用主/阴影射线的实例mask验证，没有新增动态TLAS重建。未来网格顶点、实例Transform、纹理或环境贴图更新时，需要相应数据版本号或失效通知；不能只比较GPU资源地址。integratorRevision是预留的人工版本钩子，本次固定为1，没有测试shader热重载。

## 4. 四种序号不能混用

|名称|用途|目标改变时|
|---|---|---|
|RNG sampleIndex|选择随机样本|本课继续递增，不必归零|
|history count|当前目标已有多少样本|归零，新样本后变1|
|epoch|标记当前历史属于哪一代目标|增加1，CPU日志记录|
|Fence/提交serial|GPU完成与资源生命周期|继续递增，不回退|

本节沿用b1的16B四个uint：x=RNG sampleIndex，y=seed，z=采样测试flags，w=当前目标的旧history count。R.13.6模式保留旧语义，独立编译宏ENABLE_HISTORY控制新语义。

例如真实日志中：旧目标累计48次像素颜色估计；相机平移后的第一个提交，RNG序号48，prior_history=0，count=1，epoch=2。不是把RNG序号48当作历史里已有48次针对新视角的颜色估计。“像素内位置样本→主射线→颜色估计”的区别见[R.13.6第2节](R.13.6-像素采样与线性HDR累积.md)。

策略核心：

```cpp
if (firstFrame || targetChanged || forceReset) {
    historyCount = 0;
    ++epoch;
}
// 把更新前的historyCount传给GPU；本次成功提交后代表已安排一个新样本。
```

实际Tracker在schedule时就记录已安排的计数；如果后续资源或提交失败，本测试程序立即终止，不继续用这份状态恢复渲染。

## 5. GPU reset为什么不必先清整块buffer

本课全图Dispatch，每个有效像素的第一次新目标样本直接覆盖：

```hlsl
uint count = sampleControls.w + 1u;
if (count == 1u)
    mean = result.directLight.xyz;
else
    mean = history[index].xyz
         + (result.directLight.xyz-history[index].xyz)/float(count);
history[index] = float4(mean, float(count));
```

第一次不读取旧历史，故不需要额外ClearUnorderedAccessView调用。视口外同样显式写零，避免ViewRect变化后留存旧像素。

这个结论有前提：所有相关像素都被当前Dispatch覆盖并赋值。如果以后使用局部更新、checkerboard或稀疏调度，应增加每像素代号/有效位或明确清理；不能只改一个全局计数就认为未触及的像素也已重置。

## 6. CPU已经切换目标，旧GPU帧仍在途怎么办

本节抽出了`dxr_gpu_sequence.h`，R.13.6/7共用同一套两槽、Root绑定、UAV barrier、CopyResource与Fence逻辑，不再逐课程复制执行层。

同一队列中顺序为：

    旧目标Dispatch写历史
      → history UAV barrier
      → 新目标Dispatch（priorCount=0，不读旧值）
      → history UAV barrier
      → 新目标下一样本（读取新历史）

切换目标本身不要求CPU额外等待整条队列。仍需在复用某个上传/allocator/读回槽前等该槽Fence；全局history通过UAV barrier建立访问顺序。重置计数不是同步机制，资源barrier也不会自动判断积分目标是否改变。

绑定依旧使用`SetComputeRoot32BitConstants(6,4,controls,0)`。第6号Root参数映射b1；4是DWORD数量；controls是CPU uint数组；0是目标DWORD偏移。值进入命令列表，后续修改CPU变量不会改变已录制的root constants。View则通过root CBV记录GPU地址，必须在对应Fence完成前保持上传槽内容。

回调持有该帧不可变的相机、材质、灯、期望计数快照，而不是读取“现在最新的设置”。否则CPU切到新状态后，旧帧读回会被错误地按新状态验证。

共享history是Default Heap、float4/像素，192B输出record及116B主payload保持不变。新增b1语义没有扩大Root Signature。调用方拥有设备/AS/SBT/管线；GpuRaySequence拥有两槽资源与history，在flush后释放。Map不是等待，析构前必须排空引用验证对象的读回回调。序列创建前主程序已等AS构建完成，Fence从已完成的1继续增加；通用引擎应由队列统一管理已提交Fence计数，不能在仍有旧任务在途时用completed值重新编号。

失败检查沿用HRESULT、设备移除/等待超时、shader读回有限性与Debug Layer检查；期望策略与数值验证失败会汇总为非零返回，不把失败结果标记为通过。

## 7. 实机验证：正确平均也可能平均错了对象

2026-10-14，RTX5070/Tier1.1，DXC lib_6_3，宿主build.ps1/sm_120，GPU实际执行DXR，无CUDA kernel。

自动序列18段共256次Dispatch：

|阶段|结束时epoch|结束时历史count|
|---|---|---|
|初始化16样本|1|16|
|继续jitter8样本|1|24|
|仅曝光×2，8样本|1|32|
|仅切换显示曲线，8样本|1|40|
|仅换seed，8样本|1|48|
|相机平移|2|16|
|相机旋转|3|16|
|FOV|4|16|
|near|5|16|
|ViewRect|6|16|
|灯Le加倍|7|16|
|黑材质|8|16|
|恢复材质|9|16|
|仅保留地板实例|10|16|
|恢复全部实例|11|16|
|切到固定像素中心|12|16|
|切回像素面积采样|13|16|
|手动reset|14|16|

初始化也计为一次reset，共14次。期望reason/epoch/count由测试阶段独立指定，不从被测Tracker的结果计算期望；errors=0。每段第一帧全量检查几何与灯光，其余轮转抽查；所有帧全量检查四维样本、历史平均/计数及视口外。

- 自动序列invalid/geometry/shadow mismatch均0，checked=249044。
- GPU平均对独立CPU double原始样本求和平均最大差1.86e-7。
- 方向最大差5.70e-7、位置5.01e-6、直接光样本5.06e-7。
- 首次新目标样本全像素mean等于本次raw sample，没有混入旧数据。

故意错误对照：旧相机64样本后，相机平移(0,.9,.1)，新相机32样本仍沿用旧count。不正确的图像均值确实满足

    wrong = 2/3 * old64 + 1/3 * new32

另在相同新相机设置下，使用完全相同的像素内位置与灯面位置样本（RNG序号64…95），从count=0重跑干净参考。wrong与clean的MSE=0.00206292885；GPU错误混合图与上述加权式最大差1.74e-7。它不是算术错误，是目标混合错误；Debug Layer不能发现这类数学语义错误。

全部384次Dispatch加AS构建后Fence385/385；Debug0 error/0 warning、exit0。R.13.4/5/6重新编译当前shader并回归通过，R.13.6误差统计与此前一致。

![历史与显示对照](../../sandbox/d3d12/r13-renderer/results/r13-07/history_comparison.png)

上排：旧相机64样本、不reset混合、仅新相机32样本。下排全部读取同一张干净PFM，分别应用曝光×1/Reinhard、曝光×2/Reinhard、曝光×2/截断曲线，随后sRGB编码。截断仅为诊断对照，不推荐作为正式HDR显示方案。Python只做离线显示，不参与历史策略、采样或累积。图像已实际查看。

[逐帧CSV](../../sandbox/d3d12/r13-renderer/results/r13-07/history_events.csv)保存serial、stage、RNG序号、旧/新count、epoch、reason和显示参数；[验证日志](../../sandbox/d3d12/r13-renderer/results/r13-07/validation.txt)保存数值。

## 8. 与引擎和TAA的关系

2026-10-14补充：需要区分UE5的三个使用场景，不能把所有使用历史的机制统一称为TAA。以下是依据Epic官方文档的机制对照，不是对本机某个UE源码版本的逐行复刻。

|场景|样本与历史的用途|与本课的关系|
|---|---|---|
|编辑器Path Tracer预览|相机静止时渐进累积；相机、视图、材质、物体等变化使样本失效|本课借鉴这种固定目标累积原则|
|Movie Render Queue路径追踪输出|Spatial Sample Count控制每个时间样本下的像素样本数；Temporal Sample Count在快门区间内取时间样本；总数为两者乘积|支持同一输出帧内多样本，本课尚未实现快门时间积分|
|实时TAA/TSR|运动中重投影历史，判断失效并进行融合/重建；TSR还承担时域超分辨率|本课没有实现，不应把全图reset当作动态实时方案|

UE Path Tracer的编辑器累积说明支持本课思路的合理性，但不代表其所有动态对象变化都与本课TargetKey一一对应。MRQ的Temporal Sample也不是把上一张成片混到下一张：它是在当前输出帧的曝光时间范围内采样场景运动，服务于时间积分/运动模糊。静态渐进预览则可以始终保持场景时间不变，只在多次计算更新之间追加样本。

本课的历史是同一个积分的线性样本平均，权重由有效样本数确定。TAA类方法需要把旧像素映射到当前帧，再处理遮挡、新暴露区域、深度或其他属性不一致以及历史权重；不是对相同数组下标无限平均。即使能重投影到同一表面，观察方向、高光、可见性或光照变化也未必允许把旧辐亮度当成当前目标的等价样本。

TSR使用当前图像、历史、深度和速度等信息重建输出；它降低单帧渲染成本，同时存在历史失效、细节恢复速度和运动伪影的权衡，不能视为与同帧高spp真采样无条件等价。不能给所有TAA/TSR实现套用一个固定混合系数或声称它们都使用相同历史策略。更复杂复用留在抗锯齿/时域重建课程。

选型原则：固定场景数值验收可以同帧多spp或分批累积；交互式静态预览可用少量spp持续累积并重置；离线动画每张输出帧计算足够样本并按需采样时间；动态实时渲染则需在每帧成本约束下采用更完善的有效性判断、复用与重建。此处是方法对照，不代表本课已经实现后面三类的全部功能。

本次场景变化用实例mask实际改变可见/遮挡集合，实例mask分别1/2/4，主和阴影都用同一个选择mask。没有在运行中修改顶点或重建TLAS。输出尺寸进入Key，但真正resize的资源重分配、窗口和Present属于下一节。

## 9. 运行、文件职责与自测

新增`dxr_history_policy.h`负责判定，`dxr_history_reference.h`负责CPU验收，`dxr_history_runner.h`负责实验序列，`dxr_history_preview.py`负责离线展示。公共提交层为`dxr_gpu_sequence.h`。

从仓库根目录逐步执行，前一步成功再执行下一步：

```powershell
$lesson='learning/sandbox/d3d12/r13-renderer'
$dxc='C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\dxc.exe'
& $dxc -T lib_6_3 -D ENABLE_DIRECT_LIGHT=1 -D ENABLE_PROGRESSIVE=1 -D ENABLE_HISTORY=1 -Fo "$lesson/dxr_history.dxil" "$lesson/dxr_view.hlsl"
& learning/sandbox/build.ps1 "$lesson/dxr_view_pipeline.cu" -NoRun
& "$lesson/dxr_view_pipeline.exe" "$lesson/dxr_history.dxil" history
python "$lesson/dxr_history_preview.py"
```

history参数必须与三个宏启用的DXIL配对。旧diagnostic/lighting/progressive模式保持各自协议。

自测：①旧目标均值1、64样本，新目标均值4、32样本，不reset得到多少，距离新目标差多少？②只把显示曝光从1改2，和把灯Le从1倍改2倍，为什么reset行为不同？③RNG序号已到500，相机变化后的新目标第一帧priorCount和输出count分别是什么，Fence需要归零吗？

下一节R.13.8将把未曝光HDR接到曝光/色调映射/sRGB和真实窗口，并处理resize与退出同步。

## 参考

- [Epic Path Tracer](https://dev.epicgames.com/documentation/en-us/unreal-engine/path-tracer-in-unreal-engine)：编辑器累积与样本失效。
- [Epic Temporal Super Resolution](https://dev.epicgames.com/documentation/en-us/unreal-engine/temporal-super-resolution-in-unreal-engine)：实时历史重投影、重建及其限制。
- [Microsoft Resource Barriers](https://learn.microsoft.com/en-us/windows/win32/direct3d12/using-resource-barriers-to-synchronize-resource-states-in-direct3d-12)：GPU访问顺序与资源状态。
- [Microsoft TraceRay](https://learn.microsoft.com/en-us/windows/win32/direct3d12/traceray-function)：实例mask与射线参数。
