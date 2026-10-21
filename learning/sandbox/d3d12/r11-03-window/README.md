# R.11.3 DXR 窗口输出

基础教学实验；当前综合Demo见[dynamic-character](../../d3d12/dynamic-character/README.md)。

## 文件职责

|文件|职责|
|---|---|
|[dxr_window.hlsl](dxr_window.hlsl)|GPU shader|
|[dxr_window_pipeline.cu](dxr_window_pipeline.cu)|宿主与本课验收入口|

## 构建与运行

以下命令从仓库根目录执行，目标为RTX5070 / sm_120。

```powershell
dxc -T lib_6_3 -Fo learning/sandbox/d3d12/r11-03-window/dxr_window.dxil learning/sandbox/d3d12/r11-03-window/dxr_window.hlsl
& learning/sandbox/build.ps1 learning/sandbox/d3d12/r11-03-window/dxr_window_pipeline.cu -NoRun
& learning/sandbox/d3d12/r11-03-window/dxr_window_pipeline.exe learning/sandbox/d3d12/r11-03-window/dxr_window.dxil 2
```

构建产物当前生成在源码旁；无需重复保存到另一课程目录。 图像写入本目录`results/`，以EXE位置定位，不受启动工作目录影响。

## 讲义与状态

- [完整讲义索引](../../../笔记/d3d12/README.md)

课程完成与历史实测以[学习进度](../../../进度.md)及讲义为准；补写README不代表重新执行了所有实验。
