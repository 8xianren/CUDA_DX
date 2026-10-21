# 9.2：D3D12/CUDA 互操作地基

[返回线路索引](../README.md) · [讲义索引](../../../笔记/particles/README.md) · [全局学习进度](../../../进度.md)

本目录保留该组小实验的一份源码；按下表课号定位。旧 exe/cubin 是本机历史产物，换工具链或机器后先重编译，不作为源码验收证据。

| 文件 | 课程与职责 | 构建条件 |
|---|---|---|
| [d3d12_cuda_external_memory.cu](d3d12_cuda_external_memory.cu) | 9.2.2：共享 buffer 与 CUDA 映射 | sm_120 / C++17；`-Libraries d3d12,dxgi,d3dcompiler,user32` |
| [d3d12_cuda_external_semaphore.cu](d3d12_cuda_external_semaphore.cu) | 9.2.3：外部 timeline Fence 交接 | sm_120 / C++17；`-Libraries d3d12,dxgi,d3dcompiler,user32` |
| [d3d12_cuda_external_texture.cu](d3d12_cuda_external_texture.cu) | 9.2.4：共享纹理、surface 与 row pitch | sm_120 / C++17；`-Libraries d3d12,dxgi,d3dcompiler,user32` |
| [d3d12_cuda_luid.cu](d3d12_cuda_luid.cu) | 9.2.1：按 LUID 配对同一物理 GPU | sm_120 / C++17；`-Libraries d3d12,dxgi,d3dcompiler,user32` |

## 构建与运行

下面命令从**仓库根目录**执行。普通 CUDA 编译统一走 sandbox 构建器，它加载 VS2022 环境并面向 `sm_120`；可执行文件留在本课源码旁。按表中库参数编译其它同组文件。

```powershell
& learning/sandbox/build.ps1 learning/sandbox/particles/09-02-interop/d3d12_cuda_external_memory.cu -Libraries d3d12,dxgi,d3dcompiler,user32 -NoRun
& learning/sandbox/particles/09-02-interop/d3d12_cuda_external_memory.exe
```

## 结果与验证

程序主要将数值校验写到标准输出。需要保存新结果时，先建立本课 `results/`，并明确将日志重定向到该目录：

```powershell
New-Item -ItemType Directory -Force learning/sandbox/particles/09-02-interop/results | Out-Null
# 在上述运行命令末尾加：
#  > learning/sandbox/particles/09-02-interop/results/run.txt 2>&1
```

已有图像、文本和 Nsight 报告保留在 `results/history/`（如果本课有历史结果）；本次迁移回归写入 `results/organization-check/`。这些目录不混入源码。历史性能数字不能当作新硬件/新驱动的测量结果。课程验收以程序输出的数值比较和对应讲义为准；非零退出码应先排查，不继续宣称通过。
