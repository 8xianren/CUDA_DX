# CUDA 基础与深化课程

[返回 sandbox](../README.md) · [讲义索引](../../笔记/cuda/README.md) · [学习进度](../../进度.md)

2026-10-21 将历史平铺文件按课节/共享主线归档。先选课程目录，再打开其 README；源码、构建条件、运行命令、结果与讲义链接都在本课内。

| 课程目录 | 内容 |
|---|---|
| [00-01-foundations](00-01-foundations/README.md) | 0–1：环境与编程模型 |
| [02-parallel-algorithms](02-parallel-algorithms/README.md) | 2：Thrust/CUB/CCCL 算法 |
| [03-streams-profiling](03-streams-profiling/README.md) | 3：异步、流与时间线 |
| [04-custom-kernels](04-custom-kernels/README.md) | 4：自定义内核与协作 |
| [05-advanced-execution](05-advanced-execution/README.md) | 5.1、5.2、5.4：Graph、多 GPU、动态并行 |
| [06-memory-access](06-memory-access/README.md) | 6：访存、栅栏、共享内存与排布 |
| [07-performance](07-performance/README.md) | 7：性能工程与指令 |
| [08-02-grid-sync](08-02-grid-sync/README.md) | 8.2：全网格协作 |
| [08-03-04-driver](08-03-04-driver/README.md) | 8.3–8.4：PTX/SASS 与 Driver API |
| [08-05-blackwell](08-05-blackwell/README.md) | 8.5：架构能力、Tensor Core、TMA 与 Cluster |
| [09-01-libraries](09-01-libraries/README.md) | 9.1：cuBLAS、cuBLASLt 与 cuFFT |
| [09-03-debugging](09-03-debugging/README.md) | 9.3：Sanitizer 与设备断言 |
| [09-04-numerics](09-04-numerics/README.md) | 9.4：浮点、归约可复现性与混合精度 |
| [python-ecosystem](python-ecosystem/README.md) | 5.6、9.5：Python GPU 生态 |

## 使用约定

- 课程 README 的命令统一从仓库根目录执行，普通编译通过 `learning/sandbox/build.ps1`，目标为 `sm_120`。特殊 Driver/动态并行入口在本课中说明。
- exe/cubin/PTX 是可重建的本机产物；结果进入本课 `results/`，旧图片/报告在 `results/history/`，不删除历史证据。
- 本次整理只改变组织与必要资源定位，不改变过去课程的完成状态，也不重新宣称历史性能数据。
- [organization-map.json](organization-map.json) 保存 CUDA 与粒子两线路全部 old→new 路径。
- [organization-groups.json](organization-groups.json) 是课程组与源文件的机器可读目录。
- [verify_organization.ps1](../../tools/verify_organization.ps1) 重编译并运行迁移涉及的代表性 CUDA、Driver、互操作和粒子窗口验证，按课程保存日志。

## 本次迁移验证

2026-10-21：RTX 5070 / `sm_120` 下 **32 个构建/运行案例通过**，覆盖各 CUDA 课程组代表、三种库、修复版调试例、全部粒子程序、Driver/动态并行特殊构建，以及三个无需 GPU Python 包的探针。窗口例均运行 12 帧；Driver 从仓库根目录启动并成功加载新目录的 cubin。完整明细见 [summary.json](results/organization-check/summary.json)，逐课日志在各目录的 `results/organization-check/`。

```powershell
# 从仓库根目录运行；脚本内部按自身位置定位源码与结果。
& learning/tools/verify_organization.ps1
```

本次没有重新运行所有旧性能基准，也没有重新验证 CuPy/Numba/cuDF 的包安装兼容性；原有环境边界仍以对应讲义和探针为准。
