# CUDA_DX

个人 CUDA / D3D12 / 路径追踪学习仓库。

本仓库**不是** [NVIDIA accelerated-computing-hub](https://github.com/NVIDIA/accelerated-computing-hub) 的镜像。官方教程仍在本地克隆里跟踪 NVIDIA `origin`；这里只放学习材料：

| 路径 | 内容 |
|---|---|
| `learning/笔记/` | 课堂笔记（CUDA、D3D12、粒子、路径追踪、着色器） |
| `learning/进度.md` / `learning/学习计划.md` | 进度与大纲 |
| `learning/sandbox/` | 可编译的教学程序（源码；不含 exe） |
| `AGENTS.md` | 教学约定与本机环境 |
| `.agents/skills/cuda-tutor/` | 导师技能 |

## 本机编译

Windows + PowerShell。GPU：RTX 5070（Blackwell，`sm_120`）。

```powershell
cd learning/sandbox
.\build.ps1 cuda\hello.cu
.\build.ps1 d3d12\r02-r08-mesh\d3d12_mesh_input_layout.cu -NoRun
.\build.ps1 path_tracing\pt02-ray-geometry\pt2_ray_geometry.cu
```

HLSL 必须和对应 exe 同目录。细节见 `learning/sandbox/README.md`。

## 和 NVIDIA 仓库的关系

本地工作副本同时做两件事：

1. `origin` → `https://github.com/NVIDIA/accelerated-computing-hub.git`，继续 `git fetch` 跟踪官方教程。
2. `cuda-dx` → `https://github.com/8xianren/CUDA_DX.git`，只推本仓库这些学习文件。

不要把 NVIDIA 的 `tutorials/` 整库镜像到这里。
