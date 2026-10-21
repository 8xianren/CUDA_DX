# 路径追踪程序目录

[返回 sandbox](../README.md) · [讲义索引](../../笔记/path_tracing/README.md) · [当前进度](../../进度.md)

按实际依赖学习：**PT.1–8 → PT.10 → PT.9 → PT.11 → PT.12**。课号保留原定义，不因为实现顺序重命名讲义。PT.1–5 是 CPU 原理实验；PT.6 起逐步接入 glTF/DXR，同时保留 CPU 参考。PT.9 是 CUDA 后端对照；当前应用入口是 [H 动态人物 Demo](../d3d12/dynamic-character/README.md)。

|目录|课程与范围|
|---|---|
|[pt01-radiometry](pt01-radiometry/README.md)|PT.1 辐射度量|
|[pt02-ray-geometry](pt02-ray-geometry/README.md)|PT.2 射线、几何求交与诊断图|
|[pt03-monte-carlo](pt03-monte-carlo/README.md)|PT.3 蒙特卡洛积分|
|[pt04-lambert](pt04-lambert/README.md)|PT.4 Lambert 与半球采样|
|[pt05-direct-lighting](pt05-direct-lighting/README.md)|PT.5 直接光、NEE 与阴影射线|
|[pt06-mis](pt06-mis/README.md)|PT.6 CPU / GPU 多重重要性采样，Balance / Power 对照|
|[pt07-throughput](pt07-throughput/README.md)|PT.7 多反弹、吞吐量、俄罗斯轮盘赌与补偿|
|[pt08-materials](pt08-materials/README.md)|PT.8 镜面/玻璃/GGX，材质采样专项与白炉验证|
|[dxr-path-tracer](dxr-path-tracer/README.md)|PT.8 / PT.10 共享积分器：GPU 历史、SDR/降噪、CUDA 互操作、OIDN 与误差/性能评测；H 复用|
|[cuda-path-tracer](cuda-path-tracer/README.md)|PT.9 CUDA BVH、Megakernel / Wavefront、压缩重排、CPU/后端一致性与布局审计|
|[restir-di](restir-di/README.md)|PT.11 Reservoir / RIS、时空复用、动态重投影、GI 重连接及负对照；教学范围不等于完整商用算法|
|[radiance-cache](radiance-cache/README.md)|PT.12 后缀替换、位置—方向缓存、偏差/方差实验与整章审计|

PT.9 按用户调整后的范围完成；剩余 Nsight Compute 硬件计数器分析已授权跳过，仍标为未验证。PT.11 / PT.12 教学验收完成不代表 H 已集成这两种算法。精确状态与限制见各课 README 和[当前进度](../../进度.md)。

每课 README 提供文件职责、构建/运行命令、结果和讲义入口。所有命令明确工作目录；新结果写到本课 `results/`。简单示例从仓库根目录运行：

```powershell
& learning/sandbox/build.ps1 learning/sandbox/path_tracing/pt01-radiometry/pt1_radiometry.cu
& learning/sandbox/build.ps1 learning/sandbox/path_tracing/pt02-ray-geometry/pt2_ray_geometry.cu
```
