# D3D12 / DXR 程序目录

[返回 sandbox](../README.md) · [讲义索引](../../笔记/d3d12/README.md) · [当前进度](../../进度.md)

## 当前工程与共享主线

|目录|用途|
|---|---|
|[dynamic-character](dynamic-character/README.md)|H.1–H.7 综合 Demo；玩家输入、仿真、动画、CUDA 蒙皮、DXR 路径追踪按模块组织；当前使用入口|
|[aa-reconstruction](aa-reconstruction/README.md)|F.1–F.10：MSAA/FXAA/TAA、空间缩放、官方NIS/FSR/XeSS、官方帧生成与序列评测；独立共享实验室|
|[gltf-scene](gltf-scene/README.md)|C.1–C.6 / D.1–D.4：CPU 场景、资产导入、GPU 资源、材质与提交边界；H/PT 复用|
|[cuda-interop](cuda-interop/README.md)|E.1–E.3：实例/动态顶点共享，External Memory/Fence、帧槽与时间线|
|[r13-renderer](r13-renderer/README.md)|R.13.3–8：矩阵相机、命中属性、直接光、累积/历史、SDR 显示及窗口 resize|
|[common](common/README.md)|R.13 / PT.10 共用窗口、交换链、HDR 显示与 Back Buffer 读回|

H 是当前应用主线；R.13 是保留的基础实验，不用它的早期画面或尺寸判断 H 当前效果。PT.8–10 共享积分器在 [dxr-path-tracer](../../sandbox/path_tracing/dxr-path-tracer/README.md)。下一轮应用优化见[渲染器路线](../../规划/渲染器后续优化路线.md)，尚未实施。

## 按课复习基础

|目录|课程内容|
|---|---|
|[window-basics](window-basics/README.md)|窗口、交换链与清屏基础|
|[r01-r08-mesh](r01-r08-mesh/README.md)|R.1–8 共用网格光栅化实验|
|[r08a-capability](r08a-capability/README.md)|DXR 能力查询|
|[r09-blas](r09-blas/README.md)|底层加速结构 BLAS|
|[r10-tlas](r10-tlas/README.md)|实例与顶层加速结构 TLAS|
|[r11-01-minimal](r11-01-minimal/README.md)|最小 DXR 管线|
|[r11-02-local-root](r11-02-local-root/README.md)|Local Root 与 Shader Table|
|[r11-03-window](r11-03-window/README.md)|DXR 输出到窗口|
|[r11-04-geometry-raytype](r11-04-geometry-raytype/README.md)|Geometry / RayType 寻址|
|[r12-01-shadow](r12-01-shadow/README.md)|有限阴影射线|
|[r12-02-area](r12-02-area/README.md)|矩形灯 NEE 与逐样本 CPU/GPU 对照|
|[r13-01-02-camera-math](r13-01-02-camera-math/README.md)|新版 View / Projection 数学推导与验证|
|[r13-legacy-camera](r13-legacy-camera/README.md)|旧相机诊断，仅作历史对照|

构建命令、Shader 变体与结果路径下沉到各课 README。旧单文件通过 [build.ps1](../build.ps1) 面向 `sm_120` 编译；C/D/E/H 使用本课 CMake 包装脚本。源码和课程结果同属一个目录，结果进入 `results/`；共享工程按课号归档结果。
