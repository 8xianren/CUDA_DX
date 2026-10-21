# path_tracing

2026-10-14按小节归档，源码和该节产物放在同一文件夹：

|目录|内容|
|---|---|
|[pt01-radiometry](pt01-radiometry/)|PT.1 辐射度量|
|[pt02-ray-geometry](pt02-ray-geometry/)|PT.2 射线、几何求交与诊断图|
|[pt03-monte-carlo](pt03-monte-carlo/)|PT.3 蒙特卡洛积分|
|[pt04-lambert](pt04-lambert/)|PT.4 Lambert与半球采样|
|[pt05-direct-lighting](pt05-direct-lighting/)|PT.5 直接光与NEE|
|[pt06-mis](pt06-mis/README.md)|PT.6：CPU参考+GPU正交相机/采样/积分，glTF/DXR与Balance/Power验收|
|[pt07-throughput](pt07-throughput/README.md)|PT.7：CPU基准、glTF/DXR多反弹/MIS、俄罗斯轮盘赌与存活补偿验收|
|[pt08-materials](pt08-materials/README.md)|PT.8专项验收完成：镜面/玻璃、GGX、glTF GPU混合采样、能量表/白炉与窄高光稳定性；共享积分见下一行|
|[dxr-path-tracer](dxr-path-tracer/README.md)|PT.8共享积分器与PT.10整章核心完成：GPU历史/重置、SDR和降噪窗口、CUDA External Memory/Fence、OIDN及误差/GPU时间/射线/显存报告；保留明确教学边界|
|[cuda-path-tracer](cuda-path-tracer/README.md)|PT.9按用户调整范围完成：BVH、Lambert Megakernel/Wavefront、原子压缩、CPU double/后端逐值一致、重排/分批与memcheck/synccheck通过；样本并行控制组/Systems时间线/真实队列地址布局审计已完成；Systems保留采集警告，剩余Compute硬件分析由用户授权跳过、未验证|

|[restir-di](restir-di/README.md)|PT.11教学范围完成：原始候选Reservoir/RIS CPU参考、推导、穷举与统计验收；真实几何NEE/MIS/RIS与漏遮挡负对照已通过，合并/不同来源权重/相关性验证已通过，静态时空四模式验收通过，动态重投影/历史拒绝与移动遮挡验收通过；GI/Jacobian两次散射重连接及负对照通过，UE5.7.2源码对照与整章同网格验收完成|

路径追踪附加课的可运行验收。PT.1–5为CPU程序；PT.6起复用C/D的D3D12/DXR后端，保留CPU参考；PT.10增加sm_120 CUDA审计kernel与OIDN外部消费者。

```powershell
cd ..
.\build.ps1 path_tracing\pt01-radiometry\pt1_radiometry.cu
.\build.ps1 path_tracing\pt02-ray-geometry\pt2_ray_geometry.cu
.\build.ps1 path_tracing\pt03-monte-carlo\pt3_monte_carlo.cu
```


PT.12：[radiance-cache](radiance-cache/README.md)教学范围已完成，第一节完成后缀替换/误差推导和三种表示对照；位置—方向缓存与偏差/方差数值实验已通过，整章审计已完成。
