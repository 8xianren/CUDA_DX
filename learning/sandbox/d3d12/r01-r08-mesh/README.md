# R.1–R.8 网格渲染器

基础教学实验；当前综合Demo见[dynamic-character](../../d3d12/dynamic-character/README.md)。

## 文件职责

|文件|职责|
|---|---|
|[d3d12_mesh_input_layout.cu](d3d12_mesh_input_layout.cu)|宿主与本课验收入口|
|[d3d12_mesh_input_layout.hlsl](d3d12_mesh_input_layout.hlsl)|GPU shader|

## 构建与运行

以下命令从仓库根目录执行，目标为RTX5070 / sm_120。

```powershell
& learning/sandbox/build.ps1 learning/sandbox/d3d12/r01-r08-mesh/d3d12_mesh_input_layout.cu -NoRun
& learning/sandbox/d3d12/r01-r08-mesh/d3d12_mesh_input_layout.exe --frames 2 --no-vsync
```

构建产物当前生成在源码旁；无需重复保存到另一课程目录。 HLSL由程序运行时加载，必须与EXE同目录。 本课主要以控制台PASS/错误消息验收；需要保存日志时写入本目录`results/`。

## 讲义与状态

- [R.1-D3D12顶点缓冲与InputLayout](../../../笔记/d3d12/R.1-D3D12顶点缓冲与InputLayout.md)
- [R.2-D3D12索引缓冲与DrawIndexedInstanced](../../../笔记/d3d12/R.2-D3D12索引缓冲与DrawIndexedInstanced.md)
- [R.3-CPU矩阵与CBV](../../../笔记/d3d12/R.3-CPU矩阵与CBV.md)
- [R.3-完整逐步帧流程](../../../笔记/d3d12/R.3-完整逐步帧流程.md)
- [R.4-D3D12深度缓冲与深度测试](../../../笔记/d3d12/R.4-D3D12深度缓冲与深度测试.md)
- [R.5-D3D12纹理-SRV-Sampler与UV](../../../笔记/d3d12/R.5-D3D12纹理-SRV-Sampler与UV.md)
- [R.5.2-D3D12-AlphaBlend与透明绘制](../../../笔记/d3d12/R.5.2-D3D12-AlphaBlend与透明绘制.md)
- [R.5.3-D3D12不透明与透明双PSO](../../../笔记/d3d12/R.5.3-D3D12不透明与透明双PSO.md)
- [R.5.4-D3D12-sRGB与线性颜色空间](../../../笔记/d3d12/R.5.4-D3D12-sRGB与线性颜色空间.md)
- [R.5.5-D3D12-MipMap过滤与LOD](../../../笔记/d3d12/R.5.5-D3D12-MipMap过滤与LOD.md)
- [R.5.6-D3D12材质-AlphaMode与渲染队列](../../../笔记/d3d12/R.5.6-D3D12材质-AlphaMode与渲染队列.md)
- [R.6-D3D12实例化网格](../../../笔记/d3d12/R.6-D3D12实例化网格.md)
- [R.7-D3D12渲染器最小架构与测试](../../../笔记/d3d12/R.7-D3D12渲染器最小架构与测试.md)

课程完成与历史实测以[学习进度](../../../进度.md)及讲义为准；补写README不代表重新执行了所有实验。
