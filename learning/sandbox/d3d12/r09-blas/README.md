# R.9 BLAS 构建

基础教学实验；当前综合Demo见[dynamic-character](../../d3d12/dynamic-character/README.md)。

## 文件职责

|文件|职责|
|---|---|
|[dxr_blas_build.cu](dxr_blas_build.cu)|宿主与本课验收入口|

## 构建与运行

以下命令从仓库根目录执行，目标为RTX5070 / sm_120。

```powershell
& learning/sandbox/build.ps1 learning/sandbox/d3d12/r09-blas/dxr_blas_build.cu -NoRun
& learning/sandbox/d3d12/r09-blas/dxr_blas_build.exe
```

构建产物当前生成在源码旁；无需重复保存到另一课程目录。 本课主要以控制台PASS/错误消息验收；需要保存日志时写入本目录`results/`。

## 讲义与状态

- [R.9-BLAS三角形几何与构建资源](../../../笔记/d3d12/R.9-BLAS三角形几何与构建资源.md)

课程完成与历史实测以[学习进度](../../../进度.md)及讲义为准；补写README不代表重新执行了所有实验。
