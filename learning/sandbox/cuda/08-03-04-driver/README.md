# 8.3–8.4：PTX/SASS 与 Driver API

[返回线路索引](../README.md) · [讲义索引](../../../笔记/cuda/README.md) · [全局学习进度](../../../进度.md)

本目录保留该组小实验的一份源码；按下表课号定位。旧 exe/cubin 是本机历史产物，换工具链或机器后先重编译，不作为源码验收证据。

| 文件 | 课程与职责 | 构建条件 |
|---|---|---|
| [asm_demo.cu](asm_demo.cu) | 8.3：设备模块，观察 FMA/SFU 指令；没有 main | 本课 `build.ps1` |
| [driver_api.cpp](driver_api.cpp) | 8.4：手动 context/module/kernel/内存生命周期 | 本课 `build.ps1` |
| [pred_demo.cu](pred_demo.cu) | 8.3：设备模块，观察谓词化；没有 main | 本课 `build.ps1` |

## 构建与运行

下面命令从**仓库根目录**执行。普通 CUDA 编译统一走 sandbox 构建器，它加载 VS2022 环境并面向 `sm_120`；可执行文件留在本课源码旁。按表中库参数编译其它同组文件。

```powershell
& learning/sandbox/cuda/08-03-04-driver/build.ps1
```

## 结果与验证

程序主要将数值校验写到标准输出。需要保存新结果时，先建立本课 `results/`，并明确将日志重定向到该目录：

```powershell
New-Item -ItemType Directory -Force learning/sandbox/cuda/08-03-04-driver/results | Out-Null
# 在上述运行命令末尾加：
#  > learning/sandbox/cuda/08-03-04-driver/results/run.txt 2>&1
```

已有图像、文本和 Nsight 报告保留在 `results/history/`（如果本课有历史结果）；本次迁移回归写入 `results/organization-check/`。这些目录不混入源码。历史性能数字不能当作新硬件/新驱动的测量结果。课程验收以程序输出的数值比较和对应讲义为准；非零退出码应先排查，不继续宣称通过。

`build.ps1` 先生成 `asm_demo.cubin/.ptx` 和 `pred_demo.cubin`，再编译 Driver 宿主。宿主默认从 **exe 同目录** 加载 cubin；可传入第一个参数指定别的模块。缺少模块会明确失败，不再依赖启动工作目录。反汇编观察可用 `cuobjdump -sass <cubin>`。
