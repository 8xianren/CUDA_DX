# CUDA_DX

个人 CUDA / D3D12 / 路径追踪学习仓库。

从[学习资料总入口](learning/README.md)进入；查找程序用[完整目录](learning/资料导航.md)，后续画质与水体计划见[优化路线](learning/规划/渲染器后续优化路线.md)。

新增[F.1–F.10抗锯齿、重建与帧生成实验室](learning/sandbox/d3d12/aa-reconstruction/README.md)：含十节讲义、官方SDK恢复脚本、固定序列质量与GPU性能记录。H动态角色Demo仍是当前综合应用，F的功能在独立实验室验收。

新增[G.1–G.10体渲染、NeRF与3DGS实验室](learning/sandbox/d3d12/neural-rendering/README.md)：十节讲义、真实训练、CPU/CUDA对照、预训练资产/相机和D3D12共享纹理验收；硬件计数器按用户明确授权跳过。

本仓库**不是** [NVIDIA accelerated-computing-hub](https://github.com/NVIDIA/accelerated-computing-hub) 的镜像。官方教程仍在本地克隆里跟踪 NVIDIA `origin`；这里只放学习材料：

| 路径 | 内容 |
|---|---|
| `learning/笔记/` | 课堂笔记（CUDA、D3D12、粒子、路径追踪、着色器） |
| `learning/进度.md` / `learning/学习计划.md` | 进度与大纲 |
| `learning/sandbox/` | 可编译的教学程序（源码；不含 exe） |
| `AGENTS.md` | 教学约定与本机环境 |
| `.agents/skills/cuda-tutor/` | 导师技能 |
| [codex-chat-migration/](codex-chat-migration/README.md) | 可检索的课程聊天快照与新电脑恢复说明 |

## 本机编译

Windows + PowerShell。GPU：RTX 5070（Blackwell，`sm_120`）。

```powershell
cd learning/sandbox
.\build.ps1 cuda\00-01-foundations\hello.cu
.\build.ps1 d3d12\r01-r08-mesh\d3d12_mesh_input_layout.cu -NoRun
.\build.ps1 path_tracing\pt02-ray-geometry\pt2_ray_geometry.cu
```

旧网格示例的HLSL须与exe同目录；其它程序按各课README指定shader目录。细节见[构建说明](learning/环境与构建.md)。

## 和 NVIDIA 仓库的关系

本地工作副本同时做两件事：

1. `origin` → `https://github.com/NVIDIA/accelerated-computing-hub.git`，继续 `git fetch` 跟踪官方教程。
2. `cuda-dx` → `https://github.com/8xianren/CUDA_DX.git`，只推本仓库这些学习文件。

不要把 NVIDIA 的 `tutorials/` 整库镜像到这里。
