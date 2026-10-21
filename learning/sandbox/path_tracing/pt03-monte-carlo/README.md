# PT.3 蒙特卡洛

基础教学实验；当前综合Demo见[dynamic-character](../../d3d12/dynamic-character/README.md)。

## 文件职责

|文件|职责|
|---|---|
|[pt3_monte_carlo.cu](pt3_monte_carlo.cu)|宿主与本课验收入口|

## 构建与运行

以下命令从仓库根目录执行，目标为RTX5070 / sm_120。

```powershell
& learning/sandbox/build.ps1 learning/sandbox/path_tracing/pt03-monte-carlo/pt3_monte_carlo.cu -NoRun
& learning/sandbox/path_tracing/pt03-monte-carlo/pt3_monte_carlo.exe
```

构建产物当前生成在源码旁；无需重复保存到另一课程目录。 本课主要以控制台PASS/错误消息验收；需要保存日志时写入本目录`results/`。

## 讲义与状态

- [PT.3-PT.5-补课-重要性采样到面积光](../../../笔记/path_tracing/PT.3-PT.5-补课-重要性采样到面积光.md)
- [PT.3-蒙特卡洛积分-随机变量与PDF](../../../笔记/path_tracing/PT.3-蒙特卡洛积分-随机变量与PDF.md)

课程完成与历史实测以[学习进度](../../../进度.md)及讲义为准；补写README不代表重新执行了所有实验。
