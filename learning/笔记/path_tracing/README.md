# 路径追踪讲义索引

[返回笔记总目录](../README.md) · [程序目录](../../sandbox/path_tracing/README.md) · [学习进度](../../进度.md)

本目录收录 41 篇讲义与复习材料。建议顺序为 **PT.1–PT.8 → PT.10 → PT.9 → PT.11 → PT.12**：先完成 DXR 积分器及显示/降噪，再用 CUDA BVH 对照执行架构。PT.6 起需要 [D3D12 的 C/D 场景主线](../d3d12/README.md)。

每组按小节依赖排列。历史讲义记录了当时发现的问题与“下一节”安排，后续修正紧跟其后；不要将单篇阶段性结果当作全章或当前 Demo 的结论。完成情况与教学边界见进度和各章验收讲义。

## PT.1–PT.5：成像、概率与直接光

对应 [pt01-radiometry](../../sandbox/path_tracing/pt01-radiometry/)、[pt02-ray-geometry](../../sandbox/path_tracing/pt02-ray-geometry/)、[pt03-monte-carlo](../../sandbox/path_tracing/pt03-monte-carlo/)、[pt04-lambert](../../sandbox/path_tracing/pt04-lambert/)、[pt05-direct-lighting](../../sandbox/path_tracing/pt05-direct-lighting/)。

- [PT.1 辐射度量学-立体角与渲染方程](PT.1-辐射度量学-立体角与渲染方程.md)
- [PT.2 相机射线-几何求交与可见性](PT.2-相机射线-几何求交与可见性.md)
- [PT.3 蒙特卡洛积分-随机变量与PDF](PT.3-蒙特卡洛积分-随机变量与PDF.md)
- [PT.4 Lambert-BRDF与余弦加权半球采样](PT.4-Lambert-BRDF与余弦加权半球采样.md)
- [PT.5 直接光照-阴影射线与NEE](PT.5-直接光照-阴影射线与NEE.md)

## PT.1–PT.5 补充与复习

前五节主讲义读完后，用下面两篇把 PDF、测度转换、材质和面积光连起来。它们不取代各节的推导与实验。

- [PT.3 PT.5-补课-重要性采样到面积光](PT.3-PT.5-补课-重要性采样到面积光.md)
- [PT.1 PT.5-串联复习](PT.1-PT.5-串联复习.md)

## PT.6：MIS 与 DXR 直接光

程序入口：[pt06-mis](../../sandbox/path_tracing/pt06-mis/README.md)。

- [PT.6 两种直接光估计器与MIS推导](PT.6-两种直接光估计器与MIS推导.md)
- [PT.6 GPU积分与正交相机](PT.6-GPU积分与正交相机.md)

## PT.7：多次散射与路径状态

程序入口：[pt07-throughput](../../sandbox/path_tracing/pt07-throughput/README.md)。

- [PT.7 路径吞吐量与多反弹展开](PT.7-路径吞吐量与多反弹展开.md)
- [PT.7 DXR多反弹与MIS状态](PT.7-DXR多反弹与MIS状态.md)
- [PT.7 俄罗斯轮盘赌与存活补偿](PT.7-俄罗斯轮盘赌与存活补偿.md)

## PT.8：镜面、玻璃、GGX 与共享积分器

专项实验：[pt08-materials](../../sandbox/path_tracing/pt08-materials/README.md)；共享渲染主线：[dxr-path-tracer](../../sandbox/path_tracing/dxr-path-tracer/README.md)。glTF 混合采样小节保留曾发现的能量反例，后两节给出修正与 GPU 验证，必须连续阅读。

- [PT.8 理想镜面与离散采样](PT.8-理想镜面与离散采样.md)
- [PT.8 折射方向与全反射](PT.8-折射方向与全反射.md)
- [PT.8 Fresnel与透射路径权重](PT.8-Fresnel与透射路径权重.md)
- [PT.8 DXR平滑介质界面](PT.8-DXR平滑介质界面.md)
- [PT.8 有厚度玻璃与多界面状态](PT.8-有厚度玻璃与多界面状态.md)
- [PT.8 GGX微表面推导与白炉验证](PT.8-GGX微表面推导与白炉验证.md)
- [PT.8 glTF材质与GPU混合采样](PT.8-glTF材质与GPU混合采样.md)
- [PT.8 漫反射与镜面能量耦合](PT.8-漫反射与镜面能量耦合.md)
- [PT.8 GPU能量表与窄高光数值稳定性](PT.8-GPU能量表与窄高光数值稳定性.md)
- [PT.8 共享积分器与粗糙度场景验收](PT.8-共享积分器与粗糙度场景验收.md)

## PT.10：累积、显示、降噪与质量评测

按既定依赖在 PT.9 前阅读，继续使用 [dxr-path-tracer](../../sandbox/path_tracing/dxr-path-tracer/README.md)。质量比较同时看原始线性误差、降噪误差、配置和耗时；接入成功不自动等于画质提高。

- [PT.10 GPU线性累积与历史重置](PT.10-GPU线性累积与历史重置.md)
- [PT.10 曝光色调映射与窗口显示](PT.10-曝光色调映射与窗口显示.md)
- [PT.10 降噪特征与CUDA外部消费者](PT.10-降噪特征与CUDA外部消费者.md)
- [PT.10 降噪窗口与质量性能验收](PT.10-降噪窗口与质量性能验收.md)

## PT.9：CUDA BVH 与执行架构对照

程序入口：[cuda-path-tracer](../../sandbox/path_tracing/cuda-path-tracer/README.md)。CPU/GPU 一致性、队列地址模型与 Systems 时间线已有各自证据；剩余 Nsight Compute 硬件计数器分析由用户授权跳过，仍属未验证，不能用地址模型代替硬件指标。

- [PT.9 从最近命中到CUDA-BVH](PT.9-从最近命中到CUDA-BVH.md)
- [PT.9 CUDA路径状态与Megakernel](PT.9-CUDA路径状态与Megakernel.md)
- [PT.9 Wavefront队列与路径压缩](PT.9-Wavefront队列与路径压缩.md)
- [PT.9 样本并行控制与Nsight时间线](PT.9-样本并行控制与Nsight时间线.md)
- [PT.9 队列压缩与状态地址布局](PT.9-队列压缩与状态地址布局.md)

## PT.11：Reservoir / ReSTIR 与重连接

程序入口：[restir-di](../../sandbox/path_tracing/restir-di/README.md)。本章 CPU 教学实验与 UE 源码对照各有边界，不等于把生产 ReSTIR GI 接进 H 场景。

- [PT.11 Reservoir与RIS权重推导](PT.11-Reservoir与RIS权重推导.md)
- [PT.11 面积灯RIS与可见性验收](PT.11-面积灯RIS与可见性验收.md)
- [PT.11 Reservoir合并与相关性](PT.11-Reservoir合并与相关性.md)
- [PT.11 静态时空复用与独立统计](PT.11-静态时空复用与独立统计.md)
- [PT.11 运动重投影与历史拒绝](PT.11-运动重投影与历史拒绝.md)
- [PT.11 GI重连接与Jacobian推导](PT.11-GI重连接与Jacobian推导.md)
- [PT.11 UE源码对照与整章验收](PT.11-UE源码对照与整章验收.md)

## PT.12：辐射缓存与课程收尾

程序入口：[radiance-cache](../../sandbox/path_tracing/radiance-cache/README.md)。教学位置—方向缓存、引擎探针缓存和 NVIDIA NRC 的表示与用途分开讨论。

- [PT.12 缓存后缀与三种表示](PT.12-缓存后缀与三种表示.md)
- [PT.12 方向缓存与偏差方差实测](PT.12-方向缓存与偏差方差实测.md)
- [PT.12 最终验收与课程收尾](PT.12-最终验收与课程收尾.md)
