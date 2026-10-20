# path_tracing

2026-10-14按小节归档，源码和该节产物放在同一文件夹：

|目录|内容|
|---|---|
|[pt01-radiometry](pt01-radiometry/)|PT.1 辐射度量|
|[pt02-ray-geometry](pt02-ray-geometry/)|PT.2 射线、几何求交与诊断图|
|[pt03-monte-carlo](pt03-monte-carlo/)|PT.3 蒙特卡洛积分|
|[pt04-lambert](pt04-lambert/)|PT.4 Lambert与半球采样|
|[pt05-direct-lighting](pt05-direct-lighting/)|PT.5 直接光与NEE|

路径追踪附加课的可运行验收。目前都是 CPU 程序，没有 CUDA kernel。

```powershell
cd ..
.\build.ps1 path_tracing\pt01-radiometry\pt1_radiometry.cu
.\build.ps1 path_tracing\pt02-ray-geometry\pt2_ray_geometry.cu
.\build.ps1 path_tracing\pt03-monte-carlo\pt3_monte_carlo.cu
```
