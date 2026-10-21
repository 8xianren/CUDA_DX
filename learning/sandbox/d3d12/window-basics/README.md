# D3D12 窗口与清屏

基础教学实验；当前综合Demo见[dynamic-character](../../d3d12/dynamic-character/README.md)。

## 文件职责

|文件|职责|
|---|---|
|[d3d12_window_clear.cu](d3d12_window_clear.cu)|宿主与本课验收入口|

## 构建与运行

以下命令从仓库根目录执行，目标为RTX5070 / sm_120。

```powershell
& learning/sandbox/build.ps1 learning/sandbox/d3d12/window-basics/d3d12_window_clear.cu -NoRun
& learning/sandbox/d3d12/window-basics/d3d12_window_clear.exe --frames 2
```

构建产物当前生成在源码旁；无需重复保存到另一课程目录。 本课主要以控制台PASS/错误消息验收；需要保存日志时写入本目录`results/`。

## 讲义与状态

- [R.0-D3D12渲染器整体流程](../../../笔记/d3d12/R.0-D3D12渲染器整体流程.md)

课程完成与历史实测以[学习进度](../../../进度.md)及讲义为准；补写README不代表重新执行了所有实验。
