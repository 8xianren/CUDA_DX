# PT.11 ReSTIR DI 教学主线

第一小节完成原始候选的加权Reservoir/RIS CPU double参考与概率验收；真实几何直接光与NEE/MIS对照已在第二小节完成；reservoir合并已在第三小节完成；静态时间/空间复用已在第四小节完成；动态重投影/拒绝已在第五小节完成；GI/Jacobian两次散射对照已在第六小节完成；UE源码对照与整章验收已完成，见第七小节。不能将此概率demo称为完整ReSTIR实现。

[讲义：Reservoir与RIS权重推导](../../../笔记/path_tracing/PT.11-Reservoir与RIS权重推导.md)。

|文件|职责|
|---|---|
|reservoir.h|按值保存候选、sum(t/q)、选中t、候选总数M、有效位；流式替换与S/(Mt)归一化|
|verify_reservoir.cu|CPU固定权重选择、独立二候选枚举、40万次统计、支持域/可见性/M负对照、非法输入|
|verify_reservoir.ps1|课程sm_120构建入口与运行检查；本小节没有GPU kernel|

工作目录仓库根：

```powershell
& ./learning/sandbox/path_tracing/restir-di/verify_reservoir.ps1
```

可执行文件位于本目录，结果直接写入results/reservoir/：build.txt、run.txt、selection.csv、statistics.csv、checks.txt。无需Nsight计数器权限；本节CPU无GPU sanitizer需求，不报告性能。

2026-10-21验收通过：二候选穷举正确期望11，错误沿用proposal得到4113/350≈11.7514286，漏M为22、漏可见性15、丢支持域3。40万次八候选RIS均值11.005376、方差47.093227；完整评估八个候选的NEE均值11.00055、方差8.615976，说明保留一个样本的收益目标是减少昂贵评估，不能宣称凭空减少方差。CPU结构40B，不是生产GPU二进制布局。


## 第二小节：面积灯、真实遮挡与NEE/MIS/RIS对照

[讲义](../../../笔记/path_tracing/PT.11-面积灯RIS与可见性验收.md)。新增direct_scene.h（固定平面几何/面积测度/BSDF/独立求积）、verify_direct.cu（两场景24×16点×4096试验、逐RGB统计与漏遮挡负对照）、verify_direct.ps1（构建运行）、plot_direct.py（固定曝光图，复用PT.9 build/python-deps）。

工作目录仓库根：

```powershell
& ./learning/sandbox/path_tracing/restir-di/verify_direct.ps1
python ./learning/sandbox/path_tracing/restir-di/plot_direct.py
```

结果results/direct/：pixels.csv、summary.csv、checks.txt、构建/运行日志、mean/noisy-comparison.png。有板参考平均亮度.354005540，RIS .354037398，漏遮挡.484398142；错误版383/384位置超限。所有正确方法逐RGB统计通过，参考256/512最大亮度差3.06643e-7。CPU解析几何，无CUDA kernel、无GPU性能结论；LightSample24B、Reservoir56B。时空复用与整章验收仍待后续。


## 第三小节：Reservoir合并与相关性

[讲义](../../../笔记/path_tracing/PT.11-Reservoir合并与相关性.md)。reservoir.h新增Merge(source,t_destination,u)，同一面积域J=1，权重t_destination*source.W*source.M，总M累加。verify_merge.cu负责独立枚举/不同来源4+12候选/真实几何/重复来源/坏输入；verify_merge.ps1构建运行并回归原始Reservoir。

工作目录仓库根：

```powershell
& ./learning/sandbox/path_tracing/restir-di/verify_merge.ps1
```

结果results/merge/：geometry.csv、selection.csv、checks.txt、构建与运行日志。二灯正确期望5，漏源M为10/3，错误原q为4.85；5个几何点各10万试验正确亮度均值通过，两种负对照5/5检出。重复同一来源逐次输出相同、方差不降，M不是独立样本数。无时空buffer/重投影，无通用GI映射，支持域前置条件仍必须满足。当前CPU double，无GPU性能结论。


## 第四小节：静态时间/空间复用缓冲

[讲义](../../../笔记/path_tracing/PT.11-静态时空复用与独立统计.md)。reuse_pipeline.h拥有fresh/temporal/spatial/history和输出，Step分阶段处理固定12×8网格；verify_reuse.cu运行4模式、2场景、16帧、256独立run，逐RGB统计和计数/反向遍历验收；plot_reuse.py绘制跨run方差与单次帧图。

工作目录仓库根：

```powershell
& ./learning/sandbox/path_tracing/restir-di/verify_reuse.ps1
python ./learning/sandbox/path_tracing/restir-di/plot_reuse.py
```

结果results/reuse/含frames.csv、pixels.csv、checks.txt、日志、variance-curves.png、frame16.png、visibility-model.json。正确性检查全部通过，history最大M128、spatial640，正反遍历逐RGB相同。无板both第16帧方差.000457428，关闭空间/时间分别.00107983/.00416397；有板收益趋缓，单次可见性模型约.04697835。模型不是普适方差下界。CPU固定场景参考；尚无运动重投影/法线深度拒绝，不得保留历史直接改变场景或尺寸。历史只保存temporal，不反馈spatial；未进行颜色历史平均。


## 第五小节：运动重投影、历史拒绝与当前可见性

[讲义](../../../笔记/path_tracing/PT.11-运动重投影与历史拒绝.md)。dynamic_surface.h负责正交相机/真实平面几何、重投影、当前灯积分与独立求积；dynamic_reuse.h负责分阶段时空复用、几何拒绝和全局重置；verify_dynamic.cu负责12帧×256独立run与旧可见性负对照；verify_dynamic.ps1构建运行；plot_dynamic.py绘制共同亮度范围的参考/正确/错误均值图。

工作目录仓库根：

```powershell
& ./learning/sandbox/path_tracing/restir-di/verify_dynamic.ps1
python ./learning/sandbox/path_tracing/restir-di/plot_dynamic.py
```

结果results/dynamic/含build/run.txt、checks.txt、frames/pixels/rejections/stale-visibility.csv、visibility-comparison.png。逐RGB统计失败0，一像素平移88接受/8越界，深度/法线/身份拒绝及显露通过；全局重置55296像素与空时间历史结果一致。移动板参考.433170876、正确.432623226、旧遮挡错误.370984161，错误40/96像素超限。仅CPU解析几何，无对象运动向量、GPU调度或长期M限制；不是生产ReSTIR实现。此前第四小节的StaticReuse仍只允许固定场景，动态案例使用DynamicReuse。


## 第六小节：GI重连接与Jacobian

[讲义](../../../笔记/path_tracing/PT.11-GI重连接与Jacobian推导.md)。gi_reconnection.h负责两次Lambert散射/点灯解析后缀、方向-面积测度与映射权重、独立正确/错误积分；verify_gi.cu负责486点数值Jacobian、3目标各10万次统计和逐次面积域等价；verify_gi.ps1构建运行，plot_gi.py绘制均值/标准误与各算法期望。

工作目录仓库根：

```powershell
& ./learning/sandbox/path_tracing/restir-di/verify_gi.ps1
python ./learning/sandbox/path_tracing/restir-di/plot_gi.py
```

结果results/gi/：build/run.txt、checks.txt、statistics.csv、jacobian-comparison.png。最大数值J相对差9.45262e-11、面积/方向写法逐次差2.77556e-16，正确均值全部通过。漏J/倒J共5/6超10SE，各自错误期望检查全部通过；同高度漏J不强称超10SE。仅CPU固定两次散射项，无一般GI时空流水线/光泽后缀/支持域校正，不报告GPU性能。现有DI代码未修改。


## 第七小节：UE源码对照与整章验收

[讲义及逐项验收表](../../../笔记/path_tracing/PT.11-UE源码对照与整章验收.md)。本机UE5.7.2只读源码：默认关闭的prototype Final Gather、五组纹理、历史/空间阶段、空间J与时间J=1、屏幕遮挡及独立颜色滤波，明确没有执行UE。

verify_chapter.cu补齐同一12×8网格、2场景、256独立run的NEE1/MIS2/RIS8/第16帧ReSTIR DI逐RGB统计；verify_chapter.ps1负责构建运行。工作目录仓库根：

```powershell
& ./learning/sandbox/path_tracing/restir-di/verify_chapter.ps1
```

结果results/chapter/：comparison.csv、checks.txt、build/run.txt、evidence.json（本机UE版本、源码哈希及七组实验检查摘要）。8组统计通过；无板时空方差.000454244，有板.0472494。不同方法预算不同，不当作等时间性能比较。PT.11按既定教学范围完成，继续PT.12；一般GI生产流水线、GPU ReSTIR和UE运行不是本章已完成内容。
