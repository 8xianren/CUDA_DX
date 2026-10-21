# P.3.1–P.3.3：积分、固定步、数据布局

[返回线路索引](../README.md) · [讲义索引](../../../笔记/particles/README.md) · [全局学习进度](../../../进度.md)

本目录保留该组小实验的一份源码；按下表课号定位。旧 exe/cubin 是本机历史产物，换工具链或机器后先重编译，不作为源码验收证据。

| 文件 | 课程与职责 | 构建条件 |
|---|---|---|
| [particle_fixed_timestep.cu](particle_fixed_timestep.cu) | P.3.2：固定步与边界碰撞 | sm_120 / C++17 |
| [particle_integrators.cu](particle_integrators.cu) | P.3.1：Euler/半隐式 Euler/Verlet | sm_120 / C++17 |
| [particle_layout_benchmark.cu](particle_layout_benchmark.cu) | P.3.3：AoS/SoA 对照 | sm_120 / C++17 |

## 构建与运行

下面命令从**仓库根目录**执行。普通 CUDA 编译统一走 sandbox 构建器，它加载 VS2022 环境并面向 `sm_120`；可执行文件留在本课源码旁。按表中库参数编译其它同组文件。

```powershell
& learning/sandbox/build.ps1 learning/sandbox/particles/p03-simulation/particle_fixed_timestep.cu -NoRun
& learning/sandbox/particles/p03-simulation/particle_fixed_timestep.exe
```

## 结果与验证

程序主要将数值校验写到标准输出。需要保存新结果时，先建立本课 `results/`，并明确将日志重定向到该目录：

```powershell
New-Item -ItemType Directory -Force learning/sandbox/particles/p03-simulation/results | Out-Null
# 在上述运行命令末尾加：
#  > learning/sandbox/particles/p03-simulation/results/run.txt 2>&1
```

已有图像、文本和 Nsight 报告保留在 `results/history/`（如果本课有历史结果）；本次迁移回归写入 `results/organization-check/`。这些目录不混入源码。历史性能数字不能当作新硬件/新驱动的测量结果。课程验收以程序输出的数值比较和对应讲义为准；非零退出码应先排查，不继续宣称通过。

布局实验的快速正确性入口是 `& learning/sandbox/particles/p03-simulation/particle_layout_benchmark.exe --verify-only`；无此参数会运行大数据性能基准。
