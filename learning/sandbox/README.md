# 学习程序总入口

[学习资料总入口](../README.md) · [全部程序与讲义目录](../资料导航.md) · [环境与构建](../环境与构建.md) · [当前进度](../进度.md)

当前综合程序是 [H 动态人物路径追踪 Demo](d3d12/dynamic-character/README.md)。按职责查看 [工程架构](d3d12/dynamic-character/ARCHITECTURE.md)；查原理和小实验时按下面线路进入。

|线路|内容与入口|
|---|---|
|[CUDA](cuda/README.md)|基础、算法、性能、Blackwell、库、调试与 Python 探针|
|[D3D12 / DXR](d3d12/README.md)|R 基础、C/D 资产、E 互操作、F 重建实验室、H 综合 Demo|
|[粒子](particles/README.md)|9.2 互操作地基与 P 系列模拟/渲染|
|[路径追踪](path_tracing/README.md)|PT.1–12、DXR/CUDA 积分器、ReSTIR 与辐射缓存|
|[公共路径辅助](common/README.md)|旧单文件程序的稳定结果路径|

2026-10-21 已完成本轮整体整理：旧 CUDA/粒子平铺文件归入 18 个课程目录，图形旧结果进入本课 `results/`，所有有源码的课程目录都有 README。共享工程仍保留一份实现。迁移清单与验证范围见[整理记录](../归档/整理记录/2026-10-21/README.md)。

## 使用方式

F.1–F.10连续课程使用[aa-reconstruction](d3d12/aa-reconstruction/README.md)，按职责拆分场景、资源、后处理、SDK适配及独立帧生成窗口。质量序列与关闭调试后的GPU成本分开采集，原始浮点图像保留本机、数值汇总和SVG比较图随源码保存。

以下命令从**仓库根目录**执行。`build.ps1` 定位源文件后在其旁生成 exe；CMake 共享工程使用各自脚本。具体 shader 宏、依赖、参数和验证步骤以课程 README 为准。

```powershell
& learning/sandbox/build.ps1 learning/sandbox/cuda/00-01-foundations/hello.cu
& learning/sandbox/build.ps1 learning/sandbox/d3d12/r01-r08-mesh/d3d12_mesh_input_layout.cu -NoRun
& learning/sandbox/build.ps1 learning/sandbox/particles/p04-p05-renderer/d3d12_static_particles.cu -NoRun
& learning/sandbox/build.ps1 learning/sandbox/path_tracing/pt01-radiometry/pt1_radiometry.cu
& learning/sandbox/d3d12/dynamic-character/build.ps1
```

## 后续课程目录约定

2026-10-14学习者明确要求：以下为所有后续课程的默认规则，覆盖CUDA、D3D12/DXR、粒子、路径追踪以及新增线路。

```text
learning/sandbox/<线路>/<课节或共享主线>/
├─ README.md          # 课节、文件职责、构建/运行/验证及笔记入口
├─ 源码与shader       # 按实际职责拆分；复杂示例可以再设src/
├─ 验证与预览脚本
└─ results/
   └─ <课节>/        # 共享主线分节归档；独立单节可直接写入results/
```

- 先查线路索引再新建目录。独立实验按课节命名，共享演进程序使用稳定的主线目录；不为了每节单独归档而复制整套实现。
- 源码按实际职责组织，例如宿主管理、shader、数学/积分、CPU参考验证，避免所有层次挤进一个文件；小示例不强制增加无用层级。
- 所有新生成的图像、日志、数值读回和性能报告进入本课`results/`。程序和脚本直接定位该目录；明确输出基准，避免随启动工作目录变化散落文件。构建产物保留在本课目录内，当前`build.ps1`仍在源文件旁生成exe。
- 课程README写明命令从哪里执行、文件职责、参数/变体、结果路径、验收方法和笔记链接；线路README作为课程索引，不堆放结果文件。
- 讲义仍在`learning/笔记/<线路>/`，以课节编号命名，并链接到代码与结果；代码目录反向链接讲义。不为归档另复制一套笔记。
- 新增或扩展课程时同步更新线路索引、笔记和进度。目录迁移同时修改依赖、资源/结果路径和运行命令，并验证受影响程序。保留有教学用途的旧实验，明确标记用途。
- 本规则约束自编教学材料；不搬动NVIDIA官方教程。未整理的旧线路在涉及时逐步归档，单纯更新规则不触发全库迁移。


## 历史迁移工具

`lesson-path-map.json` 与 `organize-lessons.ps1` 记录 2026-10-14 的首次迁移，仅供审计；不要当作日常构建步骤反复运行。本次增量映射位于 [CUDA/粒子迁移表](cuda/organization-map.json) 和[图形结果迁移表](../归档/整理记录/2026-10-21/graphics-path-map.json)。
