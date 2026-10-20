# CUDA 学习路线图（个人版）

> 这是为你（游戏开发者、C/C++ 基础、CUDA 初学者）定制的学习手册。
> 配套：AI 导师技能 `cuda-tutor`。想上课时直接说「**开始上课**」或「**继续上 X.Y 节**」。
>
> 学习材料推送到 [CUDA_DX](https://github.com/8xianren/CUDA_DX.git)。NVIDIA 官方教程仍由本地 `origin` 跟踪，不镜像到 CUDA_DX。

---

## 一、本机环境速查

| 项目 | 现状 |
|------|------|
| 系统 | Windows，PowerShell |
| CPU | Intel Core Ultra 7 265K |
| 显卡 | NVIDIA GeForce RTX 5070（**Blackwell，计算能力 `sm_120`**，12GB） |
| 驱动 | 591.86，`nvidia-smi` 报 CUDA 13.1 |
| 编译器 `nvcc` | CUDA Toolkit 13.3；日常用 `learning/sandbox/build.ps1` |
| Tile 教程 | `tutorials/cuda-tile/` 本机可跑（Blackwell） |

---

## 二、环境搭建（按需，第一次写 C++ 内核前做）

1. 下载安装 **CUDA Toolkit**（建议与驱动匹配的 12.x/13.x）：
   https://developer.nvidia.com/cuda-downloads （选 Windows → x86_64 → 11/10 → exe[local]）
2. Toolkit 自带 MSVC 集成；也可单独装 **Visual Studio**（含 "使用 C++ 的桌面开发"）以提供 `cl.exe`。
3. 安装后**新开 PowerShell**验证：

```powershell
nvcc --version      # 看到 release 版本号即成功
nvidia-smi          # 看到 RTX 5070
```

4. 日常编译用 sandbox 脚本（默认 `-arch=sm_120`）：

```powershell
cd learning\sandbox
.\build.ps1 cuda\hello.cu
```

> 不想本地装环境？可用云端 **NVIDIA Brev** 或 **Google Colab** 跑仓库里的 notebook（README 顶部每个 notebook 都有 Colab 徽章链接）。

---

## 三、学习路线（六个阶段）

详见 AI 导师技能里的完整大纲 `.cursor/skills/cuda-tutor/curriculum.md`。概览：

- **阶段 0 · 认知与环境**：GPU 为何能算、CUDA 平台全貌、装 Toolkit、Hello GPU
- **阶段 1 · 编程模型核心**：grid/block/thread、SIMT 与 warp、内存模型、内存管理、错误处理
- **阶段 2 · 并行算法思维**：reduce/scan/transform、Thrust/CUB/CCCL、执行空间、词汇类型
- **阶段 3 · 性能与异步**：streams、pinned memory、计算与传输重叠、Nsight、NVTX
- **阶段 4 · 编写自定义内核**：kernel、原子操作、同步、共享内存、协作组
- **阶段 5 · 进阶与生态**：CUDA Graphs、多 GPU、图形 API 互操作、Tile 模型、Python 生态

**建议顺序**：0 → 1 → 2 → 3 → 4 → 5。每节按「概念 → 类比 → 代码 → 动手 → 小结」推进，一次只学一小节。

---

## 四、本仓库材料地图

后续所有课程采用“线路 → 课节或共享主线 → 结果目录”的组织方式，详见 [sandbox目录约定](sandbox/README.md#后续课程目录约定)。源码、shader和验证脚本归入所属课程目录，结果写入`results/`，目录README说明各文件职责、运行命令并链接对应讲义。讲义继续统一保存在`learning/笔记/<线路>/`。每节结束同步更新目录索引与进度。

| 路径 | 内容 |
|------|------|
| `tutorials/cuda-cpp/notebooks/` | **核心**：现代 CUDA C++ 教程（01 算法 / 02 异步流 / 03 内核），每节含 `Sources/` 示例与 `Solutions/` 答案 |
| `tutorials/cuda-tile/` | Tile 编程模型（需 Blackwell，仅了解） |
| `tutorials/stdpar/` | C++ 标准并行 |
| `tutorials/accelerated-python/`、`tutorials/nvmath-python/` | 加速 Python |
| `Accelerated_Python_User_Guide/notebooks/` | Python GPU 计算 12 章（CuPy、Numba、cuDF…） |
| `docs/` | Brev 云端部署文档 |

---

## 五、关键官方文档

- CUDA 编程指南（主参考）：https://docs.nvidia.com/cuda/cuda-programming-guide/index.html
- CUDA C++ 最佳实践：https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/index.html
- Runtime API：https://docs.nvidia.com/cuda/cuda-runtime-api/index.html
- CUDA C++ 视频课：https://www.youtube.com/playlist?list=PL5B692fm6--vWLhYPqLcEu6RF3hXjEyJr

---

## 六、学习进度

进度记录在 `learning/进度.md`（开始第一节后由导师自动创建/更新）。

完整的后续计划（包括 D3D12 网格渲染器、glTF/GLB 解析器和 CUDA 接入）见 [`learning/学习计划.md`](学习计划.md)。教学实现若与商业引擎常见做法不同，计划第 2 节要求对照说明，避免把 demo 当成生产方案。
