# 6：访存、栅栏、共享内存与排布

[返回线路索引](../README.md) · [讲义索引](../../../笔记/cuda/README.md) · [全局学习进度](../../../进度.md)

本目录保留该组小实验的一份源码；按下表课号定位。旧 exe/cubin 是本机历史产物，换工具链或机器后先重编译，不作为源码验收证据。

| 文件 | 课程与职责 | 构建条件 |
|---|---|---|
| [bank_conflict.cu](bank_conflict.cu) | 6.5：共享内存 bank 冲突 | sm_120 / C++17 |
| [coalescing.cu](coalescing.cu) | 6.1：stride/offset 与访存合并 | sm_120 / C++17 |
| [constant_mem.cu](constant_mem.cu) | 6.2：常量广播和地址发散 | sm_120 / C++17 |
| [gob_swizzle.py](gob_swizzle.py) | 补充：公开历史 GOB 排布示意，不能据此推断本机物理排布 | Python（依赖见下文） |
| [swizzle_layout.py](swizzle_layout.py) | 补充：线性与 Morton 编码示意 | Python（依赖见下文） |
| [texture_demo.cu](texture_demo.cu) | 6.3：纹理对象与二维插值 | sm_120 / C++17 |
| [threadfence_reduce.cu](threadfence_reduce.cu) | 6.4：内存栅栏与最后 block 归约 | sm_120 / C++17 |
| [transpose_bank.cu](transpose_bank.cu) | 6.5/7.5：矩阵转置与 padding | sm_120 / C++17 |

## 构建与运行

下面命令从**仓库根目录**执行。普通 CUDA 编译统一走 sandbox 构建器，它加载 VS2022 环境并面向 `sm_120`；可执行文件留在本课源码旁。按表中库参数编译其它同组文件。

```powershell
& learning/sandbox/build.ps1 learning/sandbox/cuda/06-memory-access/bank_conflict.cu -NoRun
& learning/sandbox/cuda/06-memory-access/bank_conflict.exe
```

## 结果与验证

程序主要将数值校验写到标准输出。需要保存新结果时，先建立本课 `results/`，并明确将日志重定向到该目录：

```powershell
New-Item -ItemType Directory -Force learning/sandbox/cuda/06-memory-access/results | Out-Null
# 在上述运行命令末尾加：
#  > learning/sandbox/cuda/06-memory-access/results/run.txt 2>&1
```

已有图像、文本和 Nsight 报告保留在 `results/history/`（如果本课有历史结果）；本次迁移回归写入 `results/organization-check/`。这些目录不混入源码。历史性能数字不能当作新硬件/新驱动的测量结果。课程验收以程序输出的数值比较和对应讲义为准；非零退出码应先排查，不继续宣称通过。
