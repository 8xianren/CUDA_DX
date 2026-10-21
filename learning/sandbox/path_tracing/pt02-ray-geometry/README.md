# PT.2 射线与几何

基础教学实验；当前综合Demo见[dynamic-character](../../d3d12/dynamic-character/README.md)。

## 文件职责

|文件|职责|
|---|---|
|[pt2_ray_geometry.cu](pt2_ray_geometry.cu)|宿主与本课验收入口|

## 构建与运行

以下命令从仓库根目录执行，目标为RTX5070 / sm_120。

```powershell
& learning/sandbox/build.ps1 learning/sandbox/path_tracing/pt02-ray-geometry/pt2_ray_geometry.cu -NoRun
& learning/sandbox/path_tracing/pt02-ray-geometry/pt2_ray_geometry.exe
```

构建产物当前生成在源码旁；无需重复保存到另一课程目录。 图像写入本目录`results/`，以EXE位置定位，不受启动工作目录影响。

## 讲义与状态

- [PT.2-相机射线-几何求交与可见性](../../../笔记/path_tracing/PT.2-相机射线-几何求交与可见性.md)

课程完成与历史实测以[学习进度](../../../进度.md)及讲义为准；补写README不代表重新执行了所有实验。
