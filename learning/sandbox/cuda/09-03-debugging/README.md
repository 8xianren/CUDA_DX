# 9.3：Sanitizer 与设备断言

[返回线路索引](../README.md) · [讲义索引](../../../笔记/cuda/README.md) · [全局学习进度](../../../进度.md)

本目录保留该组小实验的一份源码；按下表课号定位。旧 exe/cubin 是本机历史产物，换工具链或机器后先重编译，不作为源码验收证据。

| 文件 | 课程与职责 | 构建条件 |
|---|---|---|
| [compute_sanitizer_demo.cu](compute_sanitizer_demo.cu) | 9.3.1：shared race 与 fixed 对照 | sm_120 / C++17 |
| [device_assert_demo.cu](device_assert_demo.cu) | 9.3.3：device assert 与修复 | sm_120 / C++17 |
| [sanitizer_tools_demo.cu](sanitizer_tools_demo.cu) | 9.3.2：memcheck/synccheck/initcheck 负例及修复 | sm_120 / C++17 |

## 构建与运行

下面命令从**仓库根目录**执行。普通 CUDA 编译统一走 sandbox 构建器，它加载 VS2022 环境并面向 `sm_120`；可执行文件留在本课源码旁。按表中库参数编译其它同组文件。

```powershell
& learning/sandbox/build.ps1 learning/sandbox/cuda/09-03-debugging/compute_sanitizer_demo.cu -NoRun
& learning/sandbox/cuda/09-03-debugging/compute_sanitizer_demo.exe fixed
```

## 结果与验证

程序主要将数值校验写到标准输出。需要保存新结果时，先建立本课 `results/`，并明确将日志重定向到该目录：

```powershell
New-Item -ItemType Directory -Force learning/sandbox/cuda/09-03-debugging/results | Out-Null
# 在上述运行命令末尾加：
#  > learning/sandbox/cuda/09-03-debugging/results/run.txt 2>&1
```

已有图像、文本和 Nsight 报告保留在 `results/history/`（如果本课有历史结果）；本次迁移回归写入 `results/organization-check/`。这些目录不混入源码。历史性能数字不能当作新硬件/新驱动的测量结果。课程验收以程序输出的数值比较和对应讲义为准；非零退出码应先排查，不继续宣称通过。

这些实验故意包含错误路径：常规验证只运行 `fixed` 版本。`compute_sanitizer_demo.exe fixed` 是 race 修复；`sanitizer_tools_demo.exe memcheck fixed`（或 `synccheck/initcheck fixed`）验证对应修复；`device_assert_demo.exe fixed` 避免主动触发设备断言。去掉 fixed 是课堂负例，不能要求它零错误。
