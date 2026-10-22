# D3D12 / DXR 讲义索引

[返回笔记总目录](../README.md) · [程序目录](../../sandbox/d3d12/README.md) · [学习进度](../../进度.md)

本目录收录 77 篇讲义与实验记录。按本轮学习顺序阅读：**R 基础与 DXR → C 资产导入 → D 场景上传 → PT 积分器 → E CUDA 互操作 → H 动态角色整合 → F 抗锯齿与重建 → G 体渲染/NeRF/3DGS**。PT 内容见[路径追踪索引](../path_tracing/README.md)。当前整合程序为 [dynamic-character](../../sandbox/d3d12/dynamic-character/README.md)，模块职责见[架构文档](../../sandbox/d3d12/dynamic-character/ARCHITECTURE.md)。

下面是学习导航，不是新的完成声明；验收范围与未验证项以各节正文和进度记录为准。正文中的“下一节”“尚未完成”保留授课当时语境。

## R.0–R.7：光栅渲染器基础

[共享网格程序](../../sandbox/d3d12/r01-r08-mesh/)；着色器知识按需配合[补充课 1–5](../shaders/README.md)。

- [R.0 D3D12渲染器整体流程](R.0-D3D12渲染器整体流程.md)
- [R.1 D3D12顶点缓冲与InputLayout](R.1-D3D12顶点缓冲与InputLayout.md)
- [R.2 D3D12索引缓冲与DrawIndexedInstanced](R.2-D3D12索引缓冲与DrawIndexedInstanced.md)
- [R.3 CPU矩阵与CBV](R.3-CPU矩阵与CBV.md)
- [R.3 完整逐步帧流程](R.3-完整逐步帧流程.md) — R.3 的逐帧流程补充，先读矩阵与 CBV 主讲义。
- [R.4 D3D12深度缓冲与深度测试](R.4-D3D12深度缓冲与深度测试.md)
- [R.5 D3D12纹理-SRV-Sampler与UV](R.5-D3D12纹理-SRV-Sampler与UV.md)
- [R.5.2 D3D12-AlphaBlend与透明绘制](R.5.2-D3D12-AlphaBlend与透明绘制.md)
- [R.5.3 D3D12不透明与透明双PSO](R.5.3-D3D12不透明与透明双PSO.md)
- [R.5.4 D3D12-sRGB与线性颜色空间](R.5.4-D3D12-sRGB与线性颜色空间.md)
- [R.5.5 D3D12-MipMap过滤与LOD](R.5.5-D3D12-MipMap过滤与LOD.md)
- [R.5.6 D3D12材质-AlphaMode与渲染队列](R.5.6-D3D12材质-AlphaMode与渲染队列.md)
- [R.6 D3D12实例化网格](R.6-D3D12实例化网格.md)
- [R.7 D3D12渲染器最小架构与测试](R.7-D3D12渲染器最小架构与测试.md)

## R.8a–R.12：DXR 执行与直接光

从能力查询、BLAS/TLAS 到 Shader Table，再进入有限阴影射线和面积光。各节独立程序入口在 [D3D12 程序索引](../../sandbox/d3d12/README.md)。

- [R.8a DXR能力查询与执行前提](R.8a-DXR能力查询与执行前提.md)
- [R.9 BLAS三角形几何与构建资源](R.9-BLAS三角形几何与构建资源.md)
- [R.10 TLAS实例变换与glTF节点对应](R.10-TLAS实例变换与glTF节点对应.md)
- [R.11 第一部分-最小DXR管线与ShaderTable](R.11-第一部分-最小DXR管线与ShaderTable.md)
- [R.11 第二部分-不同HitGroup与LocalRootArguments](R.11-第二部分-不同HitGroup与LocalRootArguments.md)
- [R.11 第三部分-DXR窗口输出与退出验收](R.11-第三部分-DXR窗口输出与退出验收.md)
- [R.11 第四部分-Geometry与RayType的Hit表寻址](R.11-第四部分-Geometry与RayType的Hit表寻址.md)
- [R.11 收束-资源绑定与程序选择](R.11-收束-资源绑定与程序选择.md) — 四部分之后的概念收束与复习。
- [R.12 第一部分-有限阴影射线与点光源直接光](R.12-第一部分-有限阴影射线与点光源直接光.md)
- [R.12 第二部分-矩形面积光NEE与CPU对照](R.12-第二部分-矩形面积光NEE与CPU对照.md)

## R.13：当前矩阵相机与完整显示主线

先读约定，再从数学推导进入 [R.13 共享渲染器](../../sandbox/d3d12/r13-renderer/README.md)。相机数学验证在 [r13-01-02-camera-math](../../sandbox/d3d12/r13-01-02-camera-math/)。当前主线以此组讲义为准。

- [R.13 重启计划与相机约定](R.13-重启计划与相机约定.md)
- [R.13.1 2-View与Projection到世界射线](R.13.1-2-View与Projection到世界射线.md)
- [R.13.3 矩阵相机接入DXR与帧资源](R.13.3-矩阵相机接入DXR与帧资源.md)
- [R.13.4 从命中约束推导位置与法线](R.13.4-从命中约束推导位置与法线.md)
- [R.13.5 Lambert矩形灯NEE与线性光照图](R.13.5-Lambert矩形灯NEE与线性光照图.md)
- [R.13.6 像素采样与线性HDR累积](R.13.6-像素采样与线性HDR累积.md)
- [R.13.7 历史有效性与重置](R.13.7-历史有效性与重置.md)
- [R.13.8a SDR显示变换与sRGB编码契约](R.13.8a-SDR显示变换与sRGB编码契约.md)
- [R.13.8b GPU显示通道与窗口Present](R.13.8b-GPU显示通道与窗口Present.md)
- [R.13.8c 窗口Resize与历史生命周期](R.13.8c-窗口Resize与历史生命周期.md)

## R.13 历史对照

以下是重启之前的基向量相机实验，保留用于比较参数化与诊断方法，不接替上面的矩阵主线。对应 [r13-legacy-camera](../../sandbox/d3d12/r13-legacy-camera/)。

- [R.13 第一部分-针孔相机与几何属性诊断](R.13-第一部分-针孔相机与几何属性诊断.md)

## C.1–C.6：资产、数据布局与 CPU 导入

C/D 共享一份 [gltf-scene](../../sandbox/d3d12/gltf-scene/README.md) 实现。先分清文件格式、导入库对象和自有 CPU 数据，再讨论 GPU 上传。

- [C.1 glTF对象模型与渲染数据对应](C.1-glTF对象模型与渲染数据对应.md)
- [C.2 glTF与GLB容器和Assimp加载](C.2-glTF与GLB容器和Assimp加载.md)
- [C.2 Assimp接入测试记录](C.2-Assimp接入测试记录.md) — C.2 的环境接入与验证记录，主讲义为前一篇。
- [C.3 accessor布局与自有CPU网格](C.3-accessor布局与自有CPU网格.md)
- [C.4 共享网格与节点世界变换](C.4-共享网格与节点世界变换.md)
- [C.5 材质纹理与颜色空间](C.5-材质纹理与颜色空间.md)
- [C.6 支持范围与导入健壮性](C.6-支持范围与导入健壮性.md)

## D.1–D.4：GPU 场景与提交边界

接续 C 线路，仍使用 [gltf-scene](../../sandbox/d3d12/gltf-scene/README.md)。D 之后进入 [PT.6–PT.8 与 PT.10](../path_tracing/README.md)，形成共享积分器和显示后端。

- [D.1 CPU数据到GPU资源与上传生命周期](D.1-CPU数据到GPU资源与上传生命周期.md)
- [D.2 节点世界变换与共享BLAS实例](D.2-节点世界变换与共享BLAS实例.md)
- [D.3 命中材质与纹理采样验证](D.3-命中材质与纹理采样验证.md)
- [D.4 解析器资源与命令提交边界](D.4-解析器资源与命令提交边界.md)

## E.1–E.3：CUDA 与 D3D12 交接

程序入口：[cuda-interop](../../sandbox/d3d12/cuda-interop/README.md)。所有权、双向 Fence 和多槽调度分开验证；多缓冲不自动等于跨 API 并行。

- [E.1 实例数据与双向交接](E.1-实例数据与双向交接.md)
- [E.2 动态顶点缓存与写入边界](E.2-动态顶点缓存与写入边界.md)
- [E.3 多缓冲时间线与性能验收](E.3-多缓冲时间线与性能验收.md)

## H.1–H.7：模块化动态角色 PT Demo

程序入口：[dynamic-character](../../sandbox/d3d12/dynamic-character/README.md)；[原始实施计划](../../H阶段-动态角色路径追踪Demo实施计划.md)。先看架构，再按资产 → 动画 → 仿真 → 输入 → 渲染 → 历史 → 验收阅读。

- [H.1 资产体检与绑定空间](H.1-资产体检与绑定空间.md)
- [H.2 姿势采样混合与CUDA蒙皮](H.2-姿势采样混合与CUDA蒙皮.md)
- [H.3 固定步长与角色状态机](H.3-固定步长与角色状态机.md)
- [H.4 输入快照与自由相机](H.4-输入快照与自由相机.md)
- [H.5 动态DXR与模块边界](H.5-动态DXR与模块边界.md)
- [H.6 变形重投影与有界时域滤波](H.6-变形重投影与有界时域滤波.md)
- [H.7 整合验收与性能边界](H.7-整合验收与性能边界.md)
- [H.7 画质修正与程序天空](H.7-画质修正与程序天空.md) — H.7 后续视觉修正：720p、平滑法线、程序天空/太阳与新质量验收。原 H.7 的小尺寸性能数字属于原测试配置，不能当作新版默认画质的帧时间。

## F.1–F.10：抗锯齿、重建、超分与帧生成

程序入口：[aa-reconstruction](../../sandbox/d3d12/aa-reconstruction/README.md)；[模块与所有权](../../sandbox/d3d12/aa-reconstruction/ARCHITECTURE.md)。这是独立可控光栅实验室，复用C/D低层资源，不把实验成本冒充H的FPS。真实SDK接入为NIS、FSR、XeSS与FidelityFX帧生成；DLSS/Streamline学习接口契约，未宣称执行。

- [F.1 MSAA与Alpha-to-Coverage](F.1-MSAA与AlphaToCoverage.md)
- [F.2 离屏HDR与后处理资源流](F.2-离屏HDR与后处理资源流.md)
- [F.3 FXAA边缘方向搜索](F.3-FXAA边缘方向搜索.md)
- [F.4 时域重建输入契约](F.4-时域重建输入契约.md)
- [F.5 历史重投影与拒绝](F.5-历史重投影与拒绝.md)
- [F.6 动态分辨率与空间超分](F.6-动态分辨率与空间超分.md)
- [F.7 FidelityFX官方超分接入](F.7-FidelityFX官方超分接入.md)
- [F.8 DLSS/Streamline/XeSS输入契约](F.8-DLSS_Streamline_XeSS输入契约.md)
- [F.9 官方帧生成与显示节奏](F.9-官方帧生成与显示节奏.md)
- [F.10 固定序列质量与性能评测](F.10-固定序列质量与性能评测.md)

## G.1–G.10：体渲染、NeRF与三维高斯

[共享实验室](../../sandbox/d3d12/neural-rendering/README.md) · [模块和资源契约](../../sandbox/d3d12/neural-rendering/ARCHITECTURE.md)。课程与代码/真实结果双向关联；G3/G8硬件计数器本次获批略过，其他验收完整保留。

- [G.1-发射吸收体渲染方程](G.1-发射吸收体渲染方程.md)
- [G.2-CUDA三维纹理体渲染与共享输出](G.2-CUDA三维纹理体渲染与共享输出.md)
- [G.3-体渲染步长跳空与性能实测](G.3-体渲染步长跳空与性能实测.md)
- [G.4-NeRF的数据与表示](G.4-NeRF的数据与表示.md)
- [G.5-NeRF采样与实时化路径](G.5-NeRF采样与实时化路径.md)
- [G.6-高斯数据与投影推导](G.6-高斯数据与投影推导.md)
- [G.7-分桶前缀和与稳定排序](G.7-分桶前缀和与稳定排序.md)
- [G.8-Tile光栅与共享内存](G.8-Tile光栅与共享内存.md)
- [G.9-训练系统与资产格式](G.9-训练系统与资产格式.md)
- [G.10-表示集成与跨API同步](G.10-表示集成与跨API同步.md)
