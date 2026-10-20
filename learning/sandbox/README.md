# sandbox 分类

2026-10-14：D3D12/DXR与PT.1–5已按课程子目录整理，入口分别为[d3d12目录索引](d3d12/README.md)和[路径追踪目录索引](path_tracing/README.md)。R.13共享主线的结果放在其`results/r13-04`和`results/r13-05`。`lesson-path-map.json`保存本次131个文件的新旧路径，`organize-lessons.ps1`保留可审计的迁移步骤。CUDA与粒子线路本次未迁移。

`build.ps1` 仍放在本目录。编译时把源文件写成子目录相对路径，可执行文件会生成在源文件旁边。

## 后续课程目录约定

2026-10-14学习者明确要求：以下为所有后续课程的默认规则，覆盖CUDA、D3D12/DXR、粒子、路径追踪以及新增线路。

```text
learning/sandbox/<线路>/<课节或共享主线>/
├─ README.md          # 课节、文件职责、构建/运行/验证及笔记入口
├─ 源码与shader       # 按实际职责拆分；复杂示例可以再设src/
├─ 验证与预览脚本
└─ results/
   └─ <课节>/        # 共享主线分节归档；独立单节可直接写入results/
```

- 先查线路索引再新建目录。独立实验按课节命名，共享演进程序使用稳定的主线目录；不为了每节单独归档而复制整套实现。
- 源码按实际职责组织，例如宿主管理、shader、数学/积分、CPU参考验证，避免所有层次挤进一个文件；小示例不强制增加无用层级。
- 所有新生成的图像、日志、数值读回和性能报告进入本课`results/`。程序和脚本直接定位该目录；明确输出基准，避免随启动工作目录变化散落文件。构建产物保留在本课目录内，当前`build.ps1`仍在源文件旁生成exe。
- 课程README写明命令从哪里执行、文件职责、参数/变体、结果路径、验收方法和笔记链接；线路README作为课程索引，不堆放结果文件。
- 讲义仍在`learning/笔记/<线路>/`，以课节编号命名，并链接到代码与结果；代码目录反向链接讲义。不为归档另复制一套笔记。
- 新增或扩展课程时同步更新线路索引、笔记和进度。目录迁移同时修改依赖、资源/结果路径和运行命令，并验证受影响程序。保留有教学用途的旧实验，明确标记用途。
- 本规则约束自编教学材料；不搬动NVIDIA官方教程。未整理的旧线路在涉及时逐步归档，单纯更新规则不触发全库迁移。

```powershell
.\build.ps1 cuda\hello.cu
.\build.ps1 d3d12\r01-r08-mesh\d3d12_mesh_input_layout.cu -NoRun
.\build.ps1 particles\d3d12_static_particles.cu
.\build.ps1 path_tracing\pt01-radiometry\pt1_radiometry.cu
```

| 目录 | 内容 |
|---|---|
| `cuda/` | CUDA 基础、性能、库、sanitizer、Python 探针 |
| `d3d12/` | 小型网格渲染器：窗口清除、VB/IB、材质、实例化 |
| `particles/` | CUDA↔D3D12 粒子、External Memory/Fence、Nsight 记录 |
| `path_tracing/` | 路径追踪验收程序（PT.1 起） |

新版 R.13：`d3d12/r13-01-02-camera-math/r13_camera_math.cu` 是 R.13.1–2 的 CPU 数学验证；`d3d12/r13-renderer/dxr_view_pipeline.cu`、`dxr_view.hlsl`、`dxr_view_reference.h` 是 R.13.3 起的矩阵相机 DXR 主线。先用 DXC `-T lib_6_3` 编译 HLSL，再用 build.ps1 `-NoRun` 编译宿主，运行时传入 DXIL 路径。详细命令和实测见 `../笔记/d3d12/R.13.3-矩阵相机接入DXR与帧资源.md`。
