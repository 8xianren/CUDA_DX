# R.13 旧版相机参考

基础教学实验；当前综合Demo见[dynamic-character](../../d3d12/dynamic-character/README.md)。 本目录为历史参考，新课沿[矩阵相机主线](../r13-renderer/README.md)推进。

## 文件职责

|文件|职责|
|---|---|
|[dxr_camera.hlsl](dxr_camera.hlsl)|GPU shader|
|[dxr_camera_pipeline.cu](dxr_camera_pipeline.cu)|宿主与本课验收入口|
|[dxr_camera_preview.py](dxr_camera_preview.py)|实际结果预览或分析|
|[dxr_camera_reference.h](dxr_camera_reference.h)|CPU参考 / 共享定义|

## 构建与运行

以下命令从仓库根目录执行，目标为RTX5070 / sm_120。

```powershell
dxc -T lib_6_3 -Fo learning/sandbox/d3d12/r13-legacy-camera/dxr_camera.dxil learning/sandbox/d3d12/r13-legacy-camera/dxr_camera.hlsl
& learning/sandbox/build.ps1 learning/sandbox/d3d12/r13-legacy-camera/dxr_camera_pipeline.cu -NoRun
& learning/sandbox/d3d12/r13-legacy-camera/dxr_camera_pipeline.exe learning/sandbox/d3d12/r13-legacy-camera/dxr_camera.dxil wide
& learning/sandbox/d3d12/r13-legacy-camera/dxr_camera_pipeline.exe learning/sandbox/d3d12/r13-legacy-camera/dxr_camera.dxil square
python learning/sandbox/d3d12/r13-legacy-camera/dxr_camera_preview.py
```

构建产物当前生成在源码旁；无需重复保存到另一课程目录。 图像写入本目录`results/`，以EXE位置定位，不受启动工作目录影响。

每像素一条相机射线，CPU 逐像素对照实例、距离、位置、法线与重心重建。输出法线、距离、实例 ID 诊断图，无光照/累积/窗口；预览脚本只将实际 GPU 输出转换为图片。

## 讲义与状态

- [R.13-第一部分-针孔相机与几何属性诊断](../../../笔记/d3d12/R.13-第一部分-针孔相机与几何属性诊断.md)
- [R.13-重启计划与相机约定](../../../笔记/d3d12/R.13-重启计划与相机约定.md)

课程完成与历史实测以[学习进度](../../../进度.md)及讲义为准；补写README不代表重新执行了所有实验。
