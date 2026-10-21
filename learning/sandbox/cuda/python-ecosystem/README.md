# 5.6、9.5：Python GPU 生态

[返回线路索引](../README.md) · [讲义索引](../../../笔记/cuda/README.md) · [全局学习进度](../../../进度.md)

本目录保留该组小实验的一份源码；按下表课号定位。旧 exe/cubin 是本机历史产物，换工具链或机器后先重编译，不作为源码验收证据。

| 文件 | 课程与职责 | 构建条件 |
|---|---|---|
| [cudf_status.py](cudf_status.py) | 9.5.3：报告 cuDF/RAPIDS 环境可用性 | Python（依赖见下文） |
| [cupy_custom_kernel.py](cupy_custom_kernel.py) | 9.5.1：RawKernel 调用自定义 CUDA | Python（依赖见下文） |
| [cupy_demo.py](cupy_demo.py) | 5.6：CuPy 数组、矩阵乘与同步计时 | Python（依赖见下文） |
| [numba_demo.py](numba_demo.py) | 5.6/9.5.2：Numba kernel 与模拟器 | Python（依赖见下文） |

## 构建与运行

下面命令从**仓库根目录**执行。普通 CUDA 编译统一走 sandbox 构建器，它加载 VS2022 环境并面向 `sm_120`；可执行文件留在本课源码旁。按表中库参数编译其它同组文件。

```powershell
python learning/sandbox/cuda/python-ecosystem/cudf_status.py
```

## 结果与验证

程序主要将数值校验写到标准输出。需要保存新结果时，先建立本课 `results/`，并明确将日志重定向到该目录：

```powershell
New-Item -ItemType Directory -Force learning/sandbox/cuda/python-ecosystem/results | Out-Null
# 在上述运行命令末尾加：
#  > learning/sandbox/cuda/python-ecosystem/results/run.txt 2>&1
```

已有图像、文本和 Nsight 报告保留在 `results/history/`（如果本课有历史结果）；本次迁移回归写入 `results/organization-check/`。这些目录不混入源码。历史性能数字不能当作新硬件/新驱动的测量结果。课程验收以程序输出的数值比较和对应讲义为准；非零退出码应先排查，不继续宣称通过。

CuPy/Numba 依赖各自兼容的 Python/CUDA 包环境，不能仅因本机装了 CUDA 就认定包可导入；`cudf_status.py` 只报告支持情况。先执行 `python .../cudf_status.py` 查看环境。Numba 的 CUDASIM 只能验证逻辑，不代表 GPU 时间。
