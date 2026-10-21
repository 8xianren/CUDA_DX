# R.12.2 面积光 NEE

基础教学实验；当前综合Demo见[dynamic-character](../../d3d12/dynamic-character/README.md)。

## 文件职责

|文件|职责|
|---|---|
|[dxr_area.hlsl](dxr_area.hlsl)|GPU shader|
|[dxr_area_pipeline.cu](dxr_area_pipeline.cu)|宿主与本课验收入口|
|[dxr_area_reference.h](dxr_area_reference.h)|CPU参考 / 共享定义|

## 构建与运行

以下命令从仓库根目录执行，目标为RTX5070 / sm_120。

```powershell
dxc -T lib_6_3 -Fo learning/sandbox/d3d12/r12-02-area/dxr_area.dxil learning/sandbox/d3d12/r12-02-area/dxr_area.hlsl
& learning/sandbox/build.ps1 learning/sandbox/d3d12/r12-02-area/dxr_area_pipeline.cu -NoRun
& learning/sandbox/d3d12/r12-02-area/dxr_area_pipeline.exe learning/sandbox/d3d12/r12-02-area/dxr_area.dxil
```

构建产物当前生成在源码旁；无需重复保存到另一课程目录。 本课主要以控制台PASS/错误消息验收；需要保存日志时写入本目录`results/`。

本实验验证 8 组场景，每组 4096 个灯面样本；GPU 执行主/阴影 TraceRay，CPU 在 Fence 后比较逐样本结果与面积积分。预期八组 PASS、visibility_mismatch=0、Debug0/0、Fence1/1；不输出路径追踪窗口图。

## 讲义与状态

- [完整讲义索引](../../../笔记/d3d12/README.md)

课程完成与历史实测以[学习进度](../../../进度.md)及讲义为准；补写README不代表重新执行了所有实验。
