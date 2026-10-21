# CUDA 讲义索引

[返回笔记总目录](../README.md) · [CUDA 程序](../../sandbox/cuda/README.md) · [学习进度](../../进度.md)

目前本目录有 1 篇独立讲义。CUDA 主干已学范围还包括环境、编程模型、内存、并行算法等，具体记录在进度与程序索引中；此处不为尚无独立 Markdown 的课程创建空讲义。

## 现有主讲义

- [3.2 CUDA Streams](3.2-CUDA-Streams.md) — 流、异步提交、事件、依赖与计算/传输重叠。

## 接续阅读

- [粒子课程](../particles/README.md)：把 CUDA 数据交给 D3D12 绘制，并比较双缓冲与时间线。
- [E.1–E.3 互操作](../d3d12/README.md)：实例、动态顶点、双向 Fence 与多槽资源所有权。
- [PT.9 执行架构](../path_tracing/README.md)：BVH、Megakernel、Wavefront 与队列布局。

本机 CUDA 编译目标为 `sm_120`。构建入口和工作目录以 [sandbox README](../../sandbox/README.md) 及对应课程目录 README 为准。
