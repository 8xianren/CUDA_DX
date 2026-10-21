# D3D12 / DXR 课程目录

2026-10-14按课程归档。每节源码、shader、可执行文件和结果放在对应文件夹；R.13共享主线的结果另按小节放在`results/`内。笔记仍统一保留在`learning/笔记/d3d12/`。

|目录|课程内容|
|---|---|
|[cuda-interop](cuda-interop/README.md)|E.1–E.3完成：实例/动态顶点External Memory/Fence、1/2/3槽正确性与固定负载性能、NVTX+Systems时间线；多缓冲缩短间隙，未观察到跨API区间重叠|
|[window-basics](window-basics/)|窗口与清屏基础|
|[common](common/README.md)|R.13/PT.10共用窗口、交换链、HDR显示与Back Buffer读回|
|[r01-r08-mesh](r01-r08-mesh/)|R.1–8共用的网格渲染器|
|[r08a-capability](r08a-capability/)|DXR能力查询|
|[r09-blas](r09-blas/)|BLAS|
|[r10-tlas](r10-tlas/)|TLAS|
|[r11-01-minimal](r11-01-minimal/)|最小DXR管线|
|[r11-02-local-root](r11-02-local-root/)|Local Root|
|[r11-03-window](r11-03-window/)|DXR窗口输出|
|[r11-04-geometry-raytype](r11-04-geometry-raytype/)|Geometry与RayType寻址|
|[r12-01-shadow](r12-01-shadow/)|有限阴影射线|
|[r12-02-area](r12-02-area/)|矩形灯NEE|
|[r13-legacy-camera](r13-legacy-camera/)|旧版相机实验，保留对照|
|[r13-01-02-camera-math](r13-01-02-camera-math/)|新版View/Projection数学|
|[r13-renderer](r13-renderer/README.md)|已验收主线：矩阵相机、命中属性、直接光、累积/历史、GPU SDR窗口、输出resize与最小化恢复|
|[gltf-scene](gltf-scene/README.md)|C/D共享资产主线；C.1–C.6、D.1–D.4完成；CPU导入/GPU资源/材质与提交边界，官方资产采样及无导入库GPU测试通过，下一节PT.6|

下面的编译与运行命令已同步到新路径。

小型网格渲染器。当前主程序是 `d3d12_mesh_input_layout.cu` / `.hlsl`。

HLSL 必须和 `.exe` 放在同一目录：程序按可执行文件目录加载 `d3d12_mesh_input_layout.hlsl`。

```powershell
cd ..
.\build.ps1 d3d12\r01-r08-mesh\d3d12_mesh_input_layout.cu -NoRun
.\d3d12\r01-r08-mesh\d3d12_mesh_input_layout.exe --frames 2 --no-vsync
```

## R.12 面积光 NEE 数值验收

`dxr_area_pipeline.cu` / `dxr_area.hlsl` / `dxr_area_reference.h`：独立无窗口程序。
8组场景，每组4096个灯面样本；GPU执行主/阴影TraceRay，CPU在Fence后比较逐样本结果与面积积分。
从仓库根目录执行以下命令，每一步成功后再执行下一步：

```powershell
& 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\dxc.exe' -T lib_6_3 -Fo learning/sandbox/d3d12/r12-02-area/dxr_area.dxil learning/sandbox/d3d12/r12-02-area/dxr_area.hlsl
& .\learning\sandbox\build.ps1 learning\sandbox\d3d12\r12-02-area\dxr_area_pipeline.cu -NoRun
& .\learning\sandbox\d3d12\r12-02-area\dxr_area_pipeline.exe .\learning\sandbox\d3d12\r12-02-area\dxr_area.dxil
```

预期：八组PASS、visibility_mismatch=0、Debug0/0、Fence1/1；不输出窗口或路径追踪图像。

## R.13 第一部分：相机与几何属性

`dxr_camera_pipeline.cu` / `dxr_camera.hlsl` / `dxr_camera_reference.h`：每像素一条相机射线，CPU逐像素对照实例、距离、位置、法线与重心重建。输出法线、距离、实例ID诊断图，无光照/累积/窗口。

```powershell
& 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\dxc.exe' -T lib_6_3 -Fo learning/sandbox/d3d12/r13-legacy-camera/dxr_camera.dxil learning/sandbox/d3d12/r13-legacy-camera/dxr_camera.hlsl
& .\learning\sandbox\build.ps1 learning\sandbox\d3d12\r13-legacy-camera\dxr_camera_pipeline.cu -NoRun
& .\learning\sandbox\d3d12\r13-legacy-camera\dxr_camera_pipeline.exe .\learning\sandbox\d3d12\r13-legacy-camera\dxr_camera.dxil wide
& .\learning\sandbox\d3d12\r13-legacy-camera\dxr_camera_pipeline.exe .\learning\sandbox\d3d12\r13-legacy-camera\dxr_camera.dxil square
python learning/sandbox/d3d12/r13-legacy-camera/dxr_camera_preview.py
```

每步成功后再执行下一步；最后的Pillow脚本把实际GPU诊断PPM转换为PNG，不重新计算图像。

## 新版 R.13.3–4：矩阵相机与命中属性

当前主线为`dxr_view_pipeline.cu`和`dxr_view.hlsl`，相机参考在`dxr_view_reference.h`，R.13.4几何参考在`dxr_surface_reference.h`。2026-10-13扩展后输出三实例的属性/法线诊断，详见`learning/笔记/d3d12/R.13.4-从命中约束推导位置与法线.md`。

```powershell
& 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\dxc.exe' -T lib_6_3 -Fo learning/sandbox/d3d12/r13-renderer/dxr_view.dxil learning/sandbox/d3d12/r13-renderer/dxr_view.hlsl
.\learning\sandbox\build.ps1 .\learning\sandbox\d3d12\r13-renderer\dxr_view_pipeline.cu -NoRun
.\learning\sandbox\d3d12\r13-renderer\dxr_view_pipeline.exe .\learning\sandbox\d3d12\r13-renderer\dxr_view.dxil
python learning/sandbox/d3d12/r13-renderer/dxr_surface_preview.py
```

## R.13.5：Lambert矩形灯直接光

同一主线通过`ENABLE_DIRECT_LIGHT=1`编译光照变体，运行时配对`lighting`参数；不加两者仍为R.13.4诊断版。新增`dxr_direct_light.hlsli`、`dxr_lighting_reference.h`及PFM预览脚本。固定像素中心，每命中点64灯样本，没有跨帧累积。输出8张线性RGB PFM和四格预览PNG。

```powershell
& 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\dxc.exe' -T lib_6_3 -D ENABLE_DIRECT_LIGHT=1 -Fo learning/sandbox/d3d12/r13-renderer/dxr_lighting.dxil learning/sandbox/d3d12/r13-renderer/dxr_view.hlsl
.\learning\sandbox\build.ps1 .\learning\sandbox\d3d12\r13-renderer\dxr_view_pipeline.cu -NoRun
.\learning\sandbox\d3d12\r13-renderer\dxr_view_pipeline.exe .\learning\sandbox\d3d12\r13-renderer\dxr_lighting.dxil lighting
python learning/sandbox/d3d12/r13-renderer/dxr_lighting_preview.py
```

2026-10-13：8组数值验证PASS、Debug0/0、Fence9/9；原诊断模式回归PASS。PFM保留线性float，PNG统一Reinhard+sRGB仅作预览。详见`learning/笔记/d3d12/R.13.5-Lambert矩形灯NEE与线性光照图.md`。
