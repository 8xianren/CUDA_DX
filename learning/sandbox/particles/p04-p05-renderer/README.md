# P.4.2–P.5.2：静态、动态与双缓冲窗口

[返回线路索引](../README.md) · [讲义索引](../../../笔记/particles/README.md) · [全局学习进度](../../../进度.md)

本目录保留该组小实验的一份源码；按下表课号定位。旧 exe/cubin 是本机历史产物，换工具链或机器后先重编译，不作为源码验收证据。

| 文件 | 课程与职责 | 构建条件 |
|---|---|---|
| [d3d12_cuda_particles.cu](d3d12_cuda_particles.cu) | P.4.3：单缓冲 CUDA 更新→D3D12 绘制 | sm_120 / C++17；`-Libraries d3d12,dxgi,d3dcompiler,user32` |
| [d3d12_cuda_particles_double_buffered.cu](d3d12_cuda_particles_double_buffered.cu) | P.5.1–P.5.2：双份状态与两条 Fence | sm_120 / C++17；`-Libraries d3d12,dxgi,d3dcompiler,user32` |
| [d3d12_static_particles.cu](d3d12_static_particles.cu) | P.4.2：静态 SoA 粒子窗口 | sm_120 / C++17；`-Libraries d3d12,dxgi,d3dcompiler,user32` |
| [d3d12_static_particles.hlsl](d3d12_static_particles.hlsl) | 共享 VS/PS：三个窗口程序均从 exe 同目录加载 | 运行时 D3DCompile；`-Libraries d3d12,dxgi,d3dcompiler,user32` |

## 构建与运行

下面命令从**仓库根目录**执行。普通 CUDA 编译统一走 sandbox 构建器，它加载 VS2022 环境并面向 `sm_120`；可执行文件留在本课源码旁。按表中库参数编译其它同组文件。

```powershell
& learning/sandbox/build.ps1 learning/sandbox/particles/p04-p05-renderer/d3d12_cuda_particles.cu -Libraries d3d12,dxgi,d3dcompiler,user32 -NoRun
& learning/sandbox/particles/p04-p05-renderer/d3d12_cuda_particles.exe
```

## 结果与验证

程序主要将数值校验写到标准输出。需要保存新结果时，先建立本课 `results/`，并明确将日志重定向到该目录：

```powershell
New-Item -ItemType Directory -Force learning/sandbox/particles/p04-p05-renderer/results | Out-Null
# 在上述运行命令末尾加：
#  > learning/sandbox/particles/p04-p05-renderer/results/run.txt 2>&1
```

已有图像、文本和 Nsight 报告保留在 `results/history/`（如果本课有历史结果）；本次迁移回归写入 `results/organization-check/`。这些目录不混入源码。历史性能数字不能当作新硬件/新驱动的测量结果。课程验收以程序输出的数值比较和对应讲义为准；非零退出码应先排查，不继续宣称通过。

## 共享主线与窗口验证

三个窗口程序必须与 `d3d12_static_particles.hlsl` 同目录；代码已经按 exe 路径查找 shader，因此从仓库根目录启动仍有效。只保留一份共享 shader，不能在迁移时给每个课节复制分叉。

```powershell
& learning/sandbox/particles/p04-p05-renderer/d3d12_static_particles.exe --frames 30
& learning/sandbox/particles/p04-p05-renderer/d3d12_cuda_particles.exe --frames 30 --vsync 0 --fixed-substeps 2
& learning/sandbox/particles/p04-p05-renderer/d3d12_cuda_particles_double_buffered.exe --frames 30 --vsync 0 --fixed-substeps 2
```

动态档与双缓冲档的 `--fixed-substeps` 用于固定工作量比较；实时 accumulator 受实际帧间隔影响，不能直接比较总时间。P.5.3/P.5.4 仍按进度表保留待学状态，本次整理不将其标为已完成。

讲义：[P.4.2](../../../笔记/particles/P.4.2-D3D12静态SoA粒子.md)、[P.4.3](../../../笔记/particles/P.4.3-CUDA-D3D12动态粒子.md)、[P.5.1](../../../笔记/particles/P.5.1-双缓冲粒子流水线.md)、[P.5.2](../../../笔记/particles/P.5.2-Nsight时间线与性能对照.md)。
