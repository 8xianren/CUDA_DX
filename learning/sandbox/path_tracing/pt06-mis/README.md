# PT.6 MIS 共享实验

本次状态：PT.6漫反射直接光MIS完成。保留CPU积分实验，并新增正交相机主射线与GPU采样/积分；多次反弹在PT.7，当前还不是完整多反弹路径追踪器。

- `mis_math.h`：PCG、Balance/Power与独立面积求积参考。
- `mis_test.cpp`：24×24表面点、64轮/128方向样本、16seed，CPU采样权重与DXR可见性、线性CSV/MSE/方差。
- `visibility.hlsl`：16B payload返回最近命中的材质身份与t；复用D.4提交层。
- `make_fixture.py`：生成小/大面积灯与遮挡板的固定glTF，不是通用解析器。
- `verify.ps1`：复用gltf-scene CMake依赖与scene_import/scene_render库，编译、原始文件校验、两场景运行。
- `preview.py`：由数值CSV生成同曝光对照图；Pillow用于图表绘制。

从仓库根依次运行：

```powershell
& learning/sandbox/path_tracing/pt06-mis/verify.ps1
python learning/sandbox/path_tracing/pt06-mis/preview.py
```

依赖沿用C/D的VS2022、CMake、DXC、Node gltf-validator与Python/Pillow；无CUDA kernel。exe位于本课build/Release，公共静态库复用gltf-scene/build。全新工作副本需按C.6先安装validation目录npm依赖。日志、shader DXIL、生成资产、原始线性CSV、PPM和图表直接位于本课results，按small/large分组；禁止用图像码值代替线性MSE。

2026-10-21 RTX5070：每场景2359296真实DXR射线，CPU/GPU可见性mismatch0、Fence17/17、Debug/GPU Validation0、Validator0/0。Power MIS小灯MSE2.14259e-7，BSDF4.35119e-5、NEE1.03893e-7；大灯Balance1.41651e-3，BSDF8.72605e-4、NEE4.67570e-3。MIS未优于各场景最好的单策略，不宣称性能最优。wrong-add均值接近参考两倍；完整指标见results/*/summary.csv，图像见results/comparison.png。

本测试固定Lambert、一盏恒定单面面积灯与不透明板，不做纹理/多灯/高光/delta仿真。emissiveFactor映射到本课单位辐亮度标尺。CPU灯采样射线追到发光几何，不是传统提前截断的shadow接口；GPU输出身份，由CPU积分。资源生命周期复用D.4同步Fence策略，没有异步退役或新加速结构实现。

[讲义](../../../笔记/path_tracing/PT.6-两种直接光估计器与MIS推导.md)。本段描述前课CPU实验；新GPU入口如下，下一课PT.7。

## GPU积分与相机（2026-10-21）

- `gpu_mis.h`：64B配置、32B像素结果与同步调度接口。
- `gpu_integrator.hlsl`：正交主射线、采样、PDF与MIS；ClosestHit仅返回材质ID/t。
- `gpu_mis_dispatch.cpp`：根签名、SBT复用、DispatchRays、Fence与读回所有权。
- `gpu_reference.h`：同整数随机序列、double计算与独立解析几何对照。
- `gpu_mis_test.cpp`：16seed逐像素与统计验证、黑材质/倍亮/相机平移回归。
- `verify_gpu.ps1`、`preview_gpu.py`：构建运行及线性结果预览。

仓库根运行：

```powershell
& ./learning/sandbox/path_tracing/pt06-mis/verify_gpu.ps1
python ./learning/sandbox/path_tracing/pt06-mis/preview_gpu.py
```

结果写`results/gpu/{small,large}/`，比较图为`results/gpu/comparison.png`；生成资产继续复用`results/{small,large}/scene.gltf`。exe在本课`build/Release/gpu_mis_test.exe`，共享构建仍在gltf-scene/build。

RTX5070每场景3321088射线、计数mismatch0，CPU/GPU最大辐亮度误差小灯1.49e-8、大灯8.34e-7；相机覆盖改变205像素，倍亮/黑材质通过，Fence20/20、Debug0、Validator0/0。32²图像含黑背景，不能与前课24²表面点图的MSE直接比较。没有GPU计时。

[本节讲义](../../../笔记/path_tracing/PT.6-GPU积分与正交相机.md)。固定灰度Lambert/平面法线/单灯/不透明几何，无通用PBR、delta专项、像素抖动与多次反弹。GPU负责本节所有采样与积分，CPU解析计算仅用于验收。

2026-10-21 PT.7后续：`gpu_mis_dispatch.cpp`的底层四根参数调度已抽至共享`gltf-scene/src/ray_buffer_dispatch.cpp`，本文件保留PT.6配置校验与结构化返回。verify_gpu.ps1两场景回归PASS，原计数/误差未变。
