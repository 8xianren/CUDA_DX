# 0–1：环境与编程模型

[返回线路索引](../README.md) · [讲义索引](../../../笔记/cuda/README.md) · [全局学习进度](../../../进度.md)

本目录保留该组小实验的一份源码；按下表课号定位。旧 exe/cubin 是本机历史产物，换工具链或机器后先重编译，不作为源码验收证据。

| 文件 | 课程与职责 | 构建条件 |
|---|---|---|
| [device_info.cu](device_info.cu) | 0.3/1.1：查询设备与执行限制 | sm_120 / C++17 |
| [error_handling.cu](error_handling.cu) | 1.6：启动与执行错误检查 | sm_120 / C++17 |
| [hello.cu](hello.cu) | 0.4：打印线程身份，验证设备代码启动 | sm_120 / C++17 |
| [image_2d.cu](image_2d.cu) | 1.3：二维索引与线性地址 | sm_120 / C++17 |
| [memory_spaces.cu](memory_spaces.cu) | 1.4：global/shared/local 数据范围 | sm_120 / C++17 |
| [unified_memory.cu](unified_memory.cu) | 1.5：统一内存分配与同步 | sm_120 / C++17 |
| [vector_add.cu](vector_add.cu) | 1.1：一维线程索引与边界检查 | sm_120 / C++17 |
| [volume_3d.cu](volume_3d.cu) | 1.3：三维索引与线性地址 | sm_120 / C++17 |
| [warp_layout.cu](warp_layout.cu) | 1.2：warp 与线程编号 | sm_120 / C++17 |

## 构建与运行

下面命令从**仓库根目录**执行。普通 CUDA 编译统一走 sandbox 构建器，它加载 VS2022 环境并面向 `sm_120`；可执行文件留在本课源码旁。按表中库参数编译其它同组文件。

```powershell
& learning/sandbox/build.ps1 learning/sandbox/cuda/00-01-foundations/device_info.cu -NoRun
& learning/sandbox/cuda/00-01-foundations/device_info.exe
```

## 结果与验证

程序主要将数值校验写到标准输出。需要保存新结果时，先建立本课 `results/`，并明确将日志重定向到该目录：

```powershell
New-Item -ItemType Directory -Force learning/sandbox/cuda/00-01-foundations/results | Out-Null
# 在上述运行命令末尾加：
#  > learning/sandbox/cuda/00-01-foundations/results/run.txt 2>&1
```

已有图像、文本和 Nsight 报告保留在 `results/history/`（如果本课有历史结果）；本次迁移回归写入 `results/organization-check/`。这些目录不混入源码。历史性能数字不能当作新硬件/新驱动的测量结果。课程验收以程序输出的数值比较和对应讲义为准；非零退出码应先排查，不继续宣称通过。
