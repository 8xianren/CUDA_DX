# PT.12 第一小节：缓存替代哪个积分，三种表示有何区别

2026-10-21。第一小节完成概念推导、UE5.7.2本机源码与NVIDIA官方资料对照；本节图为示意图，不是渲染实验。缓存实现、无缓存/缓存均值与方差实测在下一小节继续，PT.12尚未完成。

[代码目录](../../sandbox/path_tracing/radiance-cache/README.md)

## 前节自测答案

UE ReSTIR中的Sample.PDF初始保存proposal，随后覆盖为目标评分，所以必须沿赋值流理解语义。时间重采样操作候选及权重，颜色时间累积操作已经估计出的光照。极端权重裁剪改变候选处理，不能仅凭引擎采用它就宣称严格无偏。

## 1. 从路径分解推导缓存查询

路径追踪走到一个状态S时，已经累积部分贡献A，前缀吞吐为beta。S至少包含当前位置、需要估计的方向和相关材质/法线等状态；此处规定缓存是该状态剩余辐亮度，beta不包含在缓存值里。

若继续追踪，得到随机后缀估计Lhat_tail(S)，完整估计为：

    Ihat_full = A + beta*Lhat_tail(S)

这里“完整”是相对于选定积分器模型的后缀，例如同样的有限反弹预算；有限K的截断偏差不能混进缓存误差。若已有直接光估计包含在A，后缀定义须排除这一项，否则重复计数。相反，若缓存包含该点完整出射光，就不能再独立添加同一份直接光。

把后缀替换为查询函数C(S)：

    Ihat_cache = A + beta*C(S)

对路径前缀H条件化，令真实后缀期望L_tail(S)=E[Lhat_tail|H]，并假设同一前缀生成规则：

    E[Ihat_cache-Ihat_full] = E[beta*(C(S)-L_tail(S))]

这是缓存偏差如何回到像素的关系。beta为RGB时按分量乘；缓存误差的简单空间平均不能代替经过路径分布和吞吐加权的误差。

例：beta=.25，真实后缀8，缓存6，像素该项误差=.25*(6-8)=-.5。反复查询同一错误值，平均后仍为-.5。

## 2. 降方差的来源与限制

对固定前缀H，A和beta已经确定。若后缀估计条件无偏，则：

    Var(Ihat_full)=Var(A+beta*L_tail(S))
                 +E[beta²*Var(Lhat_tail|H)]

这个等式对标量/单颜色通道成立，来源于全方差公式。若缓存恰好等于真实条件期望，输出仅保留第一项，消除了后缀采样噪声。这解释了缓存的潜在价值。

实际C并不精确。错误函数会改变均值，也可能改变前缀间方差，不能保证一定低于无缓存。若缓存由随机训练集T生成，应区分：固定一份缓存的条件方差，与重新生成T后端到端方差。只固定训练结果测查询，会漏掉训练噪声；后续实验应明确采用哪种统计。

对参考积分I，MSE=Var(Ihat)+(E[Ihat]-I)²。更平滑仅反映方差的一部分，不代表MSE或均值正确。缓存无效时应有显式回退或有效性处理，不能把未初始化值当作合法黑色辐亮度。

![完整路径、查询与探针插值](../../sandbox/path_tracing/radiance-cache/results/overview/path-cache-probes.png)

## 3. 探针插值如何构造C

假设位置p附近有若干探针，每个探针记录随方向变化的辐亮度R_i(omega)。简单形式为：

    C(p,omega)=sum_i w_i(p,omega)*R_i(omega) / sum_i w_i(p,omega)

探针是空间采样记录，不是灯。方向分辨率决定它能区分多少不同来光方向；位置分辨率决定它能分辨多快的空间变化。方向或位置合并都可能抹平阴影边界。

权重和归一化可精确复现常量，但不能保证任意真实光场。墙两侧即使位置相近也可能光照完全不同，仅按距离插值会把墙另一边亮度带过来，这就是一种漏光来源。提高训练/追踪样本数只能减少每个记录的噪声，不能自动消除固定网格的插值偏差。

辐亮度L(p,omega)保留方向；辐照度E(p,n)=∫L(p,omega)*max(0,n·omega)domega已对半球做余弦积分。Lambert表面可由rho/pi乘辐照度得到出射光；一般光泽BRDF仍需要方向分布，不能把辐照度与辐亮度当相同缓存。

## 4. 本机Lumen的证据

源码根`C:/xf/engine/unreal/UnrealEngine`，版本5.7.2：

- `Engine/Source/Runtime/Renderer/Private/Lumen/LumenRadianceCache.h:110`附近注释：在标记位置周围放探针，复用旧结果，只追踪更新其中一部分，然后提供插值参数。
- `LumenRadianceCacheInterpolation.h:19`的FRadianceCacheInputs含ClipmapWorldExtent、ClipmapDistributionBase、探针位置与方向分辨率、NumProbesToTraceBudget等。
- 同文件41的插值参数含3D间接索引纹理、radiance/irradiance/occlusion/depth图集、探针偏移与各clipmap角点/格距。
- `Engine/Shaders/Private/Lumen/LumenRadianceCacheInterpolation.ush:374`附近按位置和方向查询，计算方向mip，包含随机插值与完整三线性插值路径；不是仅查一个最近RGB值。
- 同shader:442的SampleRadianceCacheAndApply将缓存辐亮度乘当前Transparency加入Lighting，随后Transparency设0。此处Transparency是该追踪合成流程的剩余权重，不把它直接等同所有路径追踪器的beta。
- `LumenRadianceCache.cpp:2142`检查UseHardwareRayTracedRadianceCache，进入RenderLumenHardwareRayTracingRadianceCache。由条件分支只能说可用HWRT更新，不能说所有配置必走HWRT。

Clipmap是不同空间尺度的嵌套网格，扩大覆盖范围而不对远处也使用近处的密度。每层有角点和格距，世界位置变成网格位置可写为(p-corner)/cellSize；3D间接索引再找到实际探针图集位置。位置层级与方向mip是两种不同分辨率，不能混称为同一个LOD。

### 更新接口的角色

```cpp
void UpdateRadianceCaches(
    FRDGBuilder& GraphBuilder,
    const FLumenSceneFrameTemporaries& FrameTemporaries,
    const TInlineArray<FUpdateInputs>& InputArray,
    TInlineArray<FUpdateOutputs>& OutputArray,
    const FScene* Scene,
    const FViewFamilyInfo& ViewFamily,
    bool bPropagateGlobalLightingChange,
    ERDGPassFlags ComputePassFlags = ERDGPassFlags::Compute);
```

GraphBuilder接收本帧资源与Pass依赖；FrameTemporaries借用Lumen帧资源；InputArray提供各缓存配置、View、可选ScreenProbeParameters、BRDF SH密度资源及标记回调；OutputArray中的FUpdateOutputs引用调用者持有的缓存状态与插值参数；Scene/ViewFamily提供场景和视图族；bool传递全局光照改变；最后一个参数指定计算Pass标志。FUpdateInputs内部View为const引用，回调经MoveTemp转移；FUpdateOutputs不凭空拥有独立状态副本。

这是RDG录制接口，调用返回不代表GPU追踪已完成。消费者通过资源依赖使用结果，跨帧状态需保持生命周期。本节没有执行该接口，不报告GPU耗时、更新帧数或资源错误路径已验收；完整接入需继续审计各配置与资源有效性。

## 5. NVIDIA NRC是另一种函数表示

NRC论文采用渲染时在线训练，以适应动态场景；缓存由网络参数表示，而不是本课显式格点表。它允许用较短训练更新及自训练传播后缀信息，不应理解为每帧都有精确真值标签。[论文官方入口](https://research.nvidia.com/labs/rtr/publication/muller2021nrc/)

当前[官方SDK指南](https://github.com/NVIDIA-RTX/RTXGI/blob/main/Docs/NrcGuide.md)区分更新路径、查询路径和后续resolve；查询值按路径前缀权重合成。终止策略使用路径扩散尺度控制偏差/噪声取舍。记录查询不等于在当前shader立即获得网络结果。本课不调用SDK，不声称已完成网络训练、NRC资源同步或GPU集成。

用一般函数逼近语言理解：网络C_theta(S)接收状态特征，预测后缀辐亮度；训练以路径产生的估计目标更新theta。目标含采样噪声，模型有表达限制，场景变化时目标本身也变化。若目标后缀含缓存预测，旧误差还可参与下一轮训练。训练损失下降不单独证明最终像素均值无偏，仍需无缓存参考。

## 6. 对照与后续实验约定

|项|本机Lumen Radiance Cache|NVIDIA NRC|本课教学缓存|
|---|---|---|---|
|表示|空间探针/clipmap、方向图集|在线训练的网络参数|小型显式位置/朝向记录|
|查询|选层、取探针、方向采样与插值|网络预测指定状态的辐亮度|明确的索引和插值|
|更新|标记需求并按预算追踪更新探针|路径数据驱动训练|可控独立样本生成记录|
|近似来源|空间/方向离散、插值与更新滞后等|函数逼近、训练覆盖/噪声/滞后等|量化、插值与有限更新样本|
|本课工作|读取实际源码|依据官方资料讲原理|下一节实现并实测|

三者不能混名。这些Lumen文件展示的是探针系统，不是NVIDIA NRC实现；本节也没有以局部文件检查证明整个UE安装中不存在任何第三方插件。

后续验收将固定同一物理模型与路径长度：无缓存完整后缀、教学缓存查询、不同记录密度；测量均值与参考的误差及跨独立运行方差，区分更新噪声与离散偏差，记录查询与更新工作量。不能只用一张更平滑的图完成验收。完整CPU/CUDA小场景实验尚未实现，本节只完成架构和数学地基。

自测：beta为什么必须乘缓存值？缓存已包含直接光时再次NEE会怎样？每个探针采样无限多次能否消除位置插值误差？下一节直接给答案并继续实验。
