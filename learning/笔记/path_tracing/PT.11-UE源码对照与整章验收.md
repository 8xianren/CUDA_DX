# PT.11 第七小节：UE源码对照与整章验收

2026-10-21。本机Engine/Build/Build.version为5.7.2。本节只读源码，不构建或运行UE，不据此报告UE画质、性能或完整算法无偏性。[课程入口](../../sandbox/path_tracing/restir-di/README.md)。源码SHA256与各实验检查摘要保存在[证据记录](../../sandbox/path_tracing/restir-di/results/chapter/evidence.json)。

## 前节自测答案

次级面余弦进入dω/dA=cos_y/r²；接收面余弦进入Fω=BRDF*L*cos_x。合并权重已乘J，累计权重和归一化已包含它，最终不能再重复乘。平滑代表随机波动小，不代表期望正确；漏J的样本会稳定地估计错误测度下的积分。

## 1. 入口定位：Lumen Final Gather原型

源码根为`C:/xf/engine/unreal/UnrealEngine`，以下行号以本节读取版本为准。

- `Engine/Source/Runtime/Renderer/Private/Lumen/LumenReSTIRGather.cpp:28`：`r.Lumen.ReSTIRGather`默认0；注释称prototype Final Gather，质量目前低于ScreenProbeGather、支持特性更少。这是该本地版本的自述，不推广到未来版本。
- 同文件278：平台限制PCD3D_SM6且支持LumenGI；286的UseReSTIRGather还检查启用光追、Lumen硬件光追和开关。
- `LumenScreenProbeGather.cpp:2150`：Lumen gather分支调用RenderLumenReSTIRGather。不能因此把它叫作UE Path Tracer积分器。

Final Gather在这里指间接光收集阶段。要解决的是当前可见表面从其他表面接收多少光；这不是“调用一次开关后整个渲染器变成完整路径追踪”。

## 2. 样本字段与概率语义

`Engine/Shaders/Private/Lumen/LumenReSTIRGather.usf:90`附近FSample包含RayDirection、PDF、OutgoingRadiance、TraceHitDistance、TraceHitNormal。命中位置可由接收点+方向*距离恢复，后两个字段让重连接几何可计算。

usf:147附近FReservoir存Sample、wSum、M、W：Update以wNew/wSum选择；Merge在usf:187使用OtherReservoirSamplePDF*Other.W*Other.M，并恢复合并后的候选总数；调用者随后计算W。M为float，与本课uint64计数不同，不把二者当相同二进制布局。

特别注意PDF字段语义随阶段改变：usf:470初始为HemisphereSample.w；475计算TargetPDF=Luminance(OutgoingRadiance)，476用目标/原PDF求权重，478再将Sample.PDF覆盖为TargetPDF。因此后续读取的PDF实际上是目标评分，不一定归一化。若因名字PDF就将它当原始proposal计算F/PDF，会重现本课第一节的错误。

本课示例评分还可包含当前接收BRDF/余弦；这段UE初始化评分使用出射辐亮度亮度。评分选择可以不同，不能将所有变量逐字等同。

## 3. GPU资源布局、所有权与阶段依赖

cpp:899的AllocateReservoirTextures把逻辑reservoir拆为五组纹理：

|纹理|内容|创建格式|
|---|---|---|
|RayDirection|xyz方向，w为阶段相关的PDF/目标评分|PF_FloatRGBA|
|TraceRadiance|RGB出射辐亮度|PF_FloatR11G11B10|
|TraceHitDistance|命中距离|PF_R32_FLOAT|
|TraceHitNormal|编码法线|PF_A2B10G10R10|
|Weights|wSum、M、W|PF_FloatRGBA|

格式与通道赋值分别由cpp:901–913和usf:105–247核实。它们不是本课CPU结构的直接显存拷贝，也不按HLSL浮点类型推断真实存储精度。还需要接收表面深度/法线和视图参数。

RDG是Render Dependency Graph，渲染依赖图。此处Pass通过参数声明读取Texture与写入UAV：UAV是允许shader写入资源的视图，不是CPU接管资源。旧历史由RegisterExternalTexture引入本帧图，新的时间结果另行分配，QueueTextureExtraction在图执行完成后把结果保留给ViewState，供下一帧使用；不是CPU读回。

cpp:1085检查历史是否存在、camera cut、previous transforms reset、尺寸与显式重置；失败走ClearTemporalHistoryCS初始化当前历史输出，不把未初始化旧纹理交给时间复用。

cpp:1170提取的是TemporalReservoirTextures；空间循环从1182开始，每一轮另建SpatialReservoirTextures，写新资源，1209再替换当前读取引用。这与本课空间前历史及分阶段读写有共同结构。不能据此推断所有ReSTIR实现都必须用这种历史策略。

cpp:1223以后IntegrateAndUpsample输出DiffuseIndirect、RoughSpecularIndirect和方差；1250以后另调DispatchTemporalAccumulation，再有双边滤波。两种“Temporal”区别：reservoir时间复用重采样路径候选；颜色时间累积平滑已经估计出来的光照。开启后者得到更平滑画面，不足以证明前者正确。

本节没有展开或修改RDG实现，未测GPU同步；可从这些Pass参数和读写表关系确认资源依赖意图，不能编造实际Fence值、barrier次数或运行耗时。

## 4. Jacobian：数学公式与工程处理要分开读

usf:541 CalculateJacobian先恢复邻居命中点y，再计算源/目标距离及y处的余弦：

    J = NewCosAngle*OriginalDistance² / (OriginalCosAngle*NewDistance²)

这与上节dω_d/dω_s推导一致。该函数还把NaN/Inf置0，为特定miss表示设J=1，并将J<.1或J>10置0以丢弃极端权重。不是“推导出的J自然有这个范围”；丢弃规则改变候选处理，不能自动沿用我们完整支持域下的无偏证明。

空间分支usf:875调用CalculateJacobian。时间分支usf:695却是`float Jacobian = 1`，原调用被注释，旁边有fireflies的TODO。时间源M在685附近限制为20。因此“文件中存在Jacobian函数”等同于“所有复用分支都执行完整变换”是错误读法。

Firefly是少量大权重造成的异常亮点；裁剪可以控制可见噪声，却可能引入取舍。仅凭代码存在裁剪无法给出整个引擎偏差的数值，也不能声称它严格无偏。

## 5. 可见性检查的范围

usf:880空间复用中，屏幕遮挡查询还依赖“候选是否将替换当前样本”。WillChangeSampleOnMerge用同一个SwapNoise预判；满足条件时ScreenShadowRayCast使用屏幕空间限定长度和8步查询；查询通过才执行相应Merge。

屏幕空间方法读取当前可见的屏幕深度信息，不能据此声称等价于任意世界空间连接的完整几何可见性。初始采样另有硬件光追，但“初始路径经过光追”和“每条重连接都做完整光追查询”不同。

本课DI在最终选中样本处执行完整解析遮挡判定；GI小实验显式限定所有连接可见。UE原型的有限查询、强度限制、历史M限制、时间J=1与颜色滤波是实际工程内容，不是本课严格基线可以随意照抄的数学步骤。

## 6. 整章同场景补充验收

新增verify_chapter.cu/.ps1，将NEE1、Power MIS2、单帧RIS8和第16帧ReSTIR DI放在同一12×8位置网格、同一三面积灯与遮挡板场景。固定种子方案，256独立run，固定第16帧跨run统计，各像素逐RGB检查参考积分。

|场景|方法|平均亮度|平均像素亮度方差|
|---|---|---:|---:|
|无板|NEE1|.485441|.142320|
|无板|MIS2|.485543|.135207|
|无板|RIS8|.485032|.0177982|
|无板|ReSTIR DI第16帧|.484996|.000454244|
|有板|NEE1|.355807|.166791|
|有板|MIS2|.356182|.158840|
|有板|RIS8|.354410|.0622487|
|有板|ReSTIR DI第16帧|.355189|.0472494|

全部方法逐RGB均值检查通过。该表不是等时间/等历史预算性能比较。CSV记录mean_squared_mean_error，是有限试验均值与参考之差的平方平均，不能直接宣称测得真实bias²。先前固定网格的完整16候选面积平均和时空方法也不能只比较名字来推断收益。

|课程要求|已检查证据|
|---|---|
|Reservoir/RIS推导、错误原PDF与候选计数|results/reservoir，独立枚举与40万试验|
|真实面积灯、NEE/MIS/RIS、可见性|results/direct，逐RGB检查及漏可见性383/384超限|
|合并、不同源数量、相关性|results/merge，4+12源与重复来源逐次一致|
|时间/空间复用及开关|results/reuse，四模式×两场景，关闭任一复用无板方差回升|
|运动、法线/深度/身份拒绝、重置|results/dynamic，12帧事件、256run，旧遮挡负对照有效|
|GI路径与Jacobian|results/gi，两次散射，数值微分/面积域等价/错误积分|
|NEE/MIS/完整时空DI同网格比较|results/chapter，8组逐RGB统计通过|
|本机UE源码、原型定位与差异|本讲义及evidence.json中的版本/哈希|

已读取检查文件、运行日志及相关验证代码，确认不是仅凭PASS名称推断覆盖。PT.11按计划允许的教学范围完成：DI具有真实时空复用和动态拒绝，GI提供推导与小实验而不要求完整生产复现。保留CPU执行、解析几何、有限帧数、无一般GI支持域校正的边界。未执行UE、没有GPU性能结论。

仓库根运行章末新增对照：

```powershell
& ./learning/sandbox/path_tracing/restir-di/verify_chapter.ps1
```

## 下一章连接

ReSTIR主要复用随机候选及其权重；辐射缓存将一部分光输运函数用离散表或模型近似，查询该近似来代替后续路径工作。下一章PT.12区分UE Lumen Radiance Cache、NVIDIA Neural Radiance Cache和本课教学缓存，测量查询近似的偏差与方差。

自测：为什么Sample.PDF不能只按名字理解？为什么时间重采样与颜色时间累积是两件事？为什么引擎裁剪规则不能直接当成无偏证明？下一节先回答再继续。
