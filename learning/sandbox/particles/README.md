# CUDA / D3D12 粒子项目

[返回 sandbox](../README.md) · [讲义索引](../../笔记/particles/README.md) · [学习进度](../../进度.md)

2026-10-21 将历史平铺文件按课节/共享主线归档。先选课程目录，再打开其 README；源码、构建条件、运行命令、结果与讲义链接都在本课内。

| 课程目录 | 内容 |
|---|---|
| [09-02-interop](09-02-interop/README.md) | 9.2：D3D12/CUDA 互操作地基 |
| [p02-headless](p02-headless/README.md) | P.2：无窗口共享粒子 |
| [p03-simulation](p03-simulation/README.md) | P.3.1–P.3.3：积分、固定步、数据布局 |
| [p04-p05-renderer](p04-p05-renderer/README.md) | P.4.2–P.5.2：静态、动态与双缓冲窗口 |

## 使用约定

- 课程 README 的命令统一从仓库根目录执行，普通编译通过 `learning/sandbox/build.ps1`，目标为 `sm_120`。特殊 Driver/动态并行入口在本课中说明。
- exe/cubin/PTX 是可重建的本机产物；结果进入本课 `results/`，旧图片/报告在 `results/history/`，不删除历史证据。
- 本次整理只改变组织与必要资源定位，不改变过去课程的完成状态，也不重新宣称历史性能数据。
- 9.2 互操作是 P 系列的前置；P.4/P.5 共用一个 shader，单/双缓冲用于比较，不复制成多套课程工程。
- P.4.1 清屏基础位于 [D3D12 window-basics](../d3d12/window-basics/README.md)。
