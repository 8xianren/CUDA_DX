# CUDA 课程大纲（对齐官方编程指南 + 仓库代码）

本大纲以 **NVIDIA 官方《CUDA Programming Guide》**（https://docs.nvidia.com/cuda/cuda-programming-guide/index.html ，下称"指南 §x"）的章节体系为骨架，融合本仓库 `accelerated-computing-hub` 的可运行代码与练习。
教学时一次只讲一小节，每节给出：核心要点 + **指南阅读**（官方对应章节）+ **仓库材料**（真实代码/notebook）。讲完更新 `learning/进度.md`。

---

## 官方指南 → 本课程阶段 映射总表

| 官方指南 Part | 官方章节 | 对应本课程阶段 |
|---|---|---|
| **Part 1** 引言与编程模型 | §1.1 Introduction、§1.2 Programming Model、§1.3 The CUDA platform | **阶段 0** 认知与环境 |
| **Part 2** 用 CUDA 编程 | §2.1 Intro CUDA C++、§2.2 Intro CUDA Python、§2.3 SIMT Kernels、§2.4 Tile Kernels、§2.5 Async、§2.6 Unified/System Memory、§2.7 NVCC | **阶段 1 + 2 + 3** 核心模型/算法/异步 |
| **Part 3** 进阶 CUDA | §3.1 Advanced APIs、§3.2 Advanced Kernels、§3.3 Driver API、§3.4 Multi-GPU、§3.5 Feature Tour | **阶段 4 + 5** 内核进阶/多GPU |
| **Part 4** CUDA 特性 | §4.1 Unified Memory … §4.20 Driver Entry Point（CUDA Graphs/Cooperative Groups/Graphics Interop/Dynamic Parallelism 等） | **阶段 5** 进阶与生态（按需深挖） |
| **Part 5** 技术附录 | §5.1 Compute Capabilities、§5.3 C++ Support、§5.4 Language Extensions、§5.7 Memory Model、§5.8 Execution Model | **全程查阅手册**（不单独排课） |

> 学习顺序：阶段 0→5 顺序推进。指南 Part 1–3 跟课同步读；Part 4/5 当作"需要时翻"的参考。

---

## 阶段 0 · 认知与环境　〔指南 Part 1〕

- **0.1 GPU 为什么能做通用计算**：吞吐 vs 延迟、SIMD/SIMT、延迟隐藏。
  - 指南：§1.1 Introduction、§1.2 Programming Model
  - 仓库：`Accelerated_Python_User_Guide/notebooks/Chapter_01_GPU_Computing_Basics.ipynb`
- **0.2 CUDA 平台全貌**：驱动 / Driver API / Runtime API / 上层库 / nvcc 的分层。
  - 指南：§1.3 The CUDA platform
- **0.3 环境搭建**：装 CUDA Toolkit（含 nvcc），验证 `nvcc --version`/`nvidia-smi`，理解 `-arch=sm_120`。
  - 指南：§2.7 NVCC: The NVIDIA CUDA Compiler；§5.1 Compute Capabilities
  - 材料：`learning/README.md`（本机 Windows + RTX 5070 步骤）
- **0.4 第一个程序 Hello GPU**：`__global__`、`<<<grid,block>>>`、`cudaDeviceSynchronize`、编译运行。
  - 指南：§2.1 Intro to CUDA C++

## 阶段 1 · 编程模型核心　〔指南 §2.1、§2.3、§2.6、§5.7、§5.8〕

- **1.1 执行模型**：grid/block/thread 三层，`threadIdx/blockIdx/blockDim/gridDim`，多维。
  - 指南：§2.3 Writing SIMT Kernels；§5.8 Execution model
  - 仓库：`tutorials/cuda-cpp/notebooks/03.02-Kernels/03.02.01-Kernels.ipynb`
- **1.2 SIMT 与 warp**：32 线程一束、warp divergence、occupancy。
  - 指南：§5.1 Compute Capabilities；§2.3 SIMT Kernels
- **1.3 线程到数据的映射**：`i = blockIdx.x*blockDim.x+threadIdx.x`、grid-stride loop、边界判断。
  - 仓库：`tutorials/cuda-cpp/notebooks/03.02-Kernels/Sources/`
- **1.4 内存模型**：global/shared/local/register/constant 的位置与作用域。
  - 指南：§5.7 CUDA C++ Memory Model
  - 仓库：`tutorials/cuda-cpp/notebooks/01.06-Memory-Spaces/01.06.01-Memory-Spaces.ipynb`
- **1.5 内存管理**：`cudaMalloc/cudaMemcpy/cudaFree`、Unified Memory（`cudaMallocManaged`）。
  - 指南：§2.6 Unified and System Memory；§4.1 Unified Memory
  - 仓库：`tutorials/cuda-cpp/notebooks/01.06-Memory-Spaces/Sources/heat-2D-explicit-memory-spaces.cpp`
- **1.6 错误处理**：返回码、`cudaGetLastError`、同步 vs 异步错误。
  - 仓库：`tutorials/cuda-cpp/notebooks/02.03-Streams/`（async-errors 图示）

## 阶段 2 · 并行算法思维（CUDA Made Easy）　〔指南 §2.1〕

- **2.1 串行 vs 并行**：reduce/scan/map/transform/reduce-by-key 的并行直觉。
  - 仓库：`tutorials/cuda-cpp/notebooks/01.05-Serial-vs-Parallel/01.05.01-Serial-vs-Parallel.ipynb`
- **2.2 用高层算法加速**：Thrust / CUB / CCCL，先用库再造轮子。
  - 仓库：`tutorials/cuda-cpp/notebooks/01.01-Introduction/01.01.01-CUDA-Made-Easy.ipynb`
- **2.3 执行空间与执行策略**：host/device 执行、`par`/`par_unseq`。
  - 仓库：`tutorials/cuda-cpp/notebooks/01.02-Execution-Spaces/01.02.01-Execution-Spaces.ipynb`
- **2.4 扩展算法**：自定义 functor、iterator、transform 输出。
  - 仓库：`tutorials/cuda-cpp/notebooks/01.03-Extending-Algorithms/Sources/`
- **2.5 词汇类型**：`span`/`mdspan`/`pair`。
  - 指南：§5.3 C++ Language Support
  - 仓库：`tutorials/cuda-cpp/notebooks/01.04-Vocabulary-Types/01.04.01-Vocabulary-Types.ipynb`

## 阶段 3 · 性能与异步　〔指南 §2.5〕

- **3.1 异步执行**：核函数启动异步、host/device 重叠。
  - 指南：§2.5 Asynchronous Execution
  - 仓库：`tutorials/cuda-cpp/notebooks/02.02-Asynchrony/02.02.01-Asynchrony.ipynb`
- **3.2 CUDA Streams**：多流并发、依赖、计算/拷贝重叠。
  - 指南：§4.3 Stream-Ordered Memory Allocator（关联）
  - 仓库：`tutorials/cuda-cpp/notebooks/02.03-Streams/02.03.01-Streams.ipynb`、`Sources/streams.cpp`
- **3.3 Pinned Memory**：页锁定内存、staging 机制。
  - 仓库：`tutorials/cuda-cpp/notebooks/02.04-Pinned-Memory/02.04.01-Pinned.ipynb`
- **3.4 性能分析工具**：Nsight Systems / Nsight Compute、NVTX 打点。
  - 仓库：`tutorials/cuda-cpp/notebooks/03.02-Kernels/03.02.04-Dev-Tools.ipynb`、`02.02-Asynchrony/Sources/nvtx3.hpp`

## 阶段 4 · 编写自定义内核　〔指南 §2.3、§3.2、§4.4、§4.9〕

- **4.1 写第一个 kernel**：从库下沉到手写核函数，何时该手写。
  - 指南：§2.3 Writing SIMT Kernels；§3.2 Advanced Kernel Programming
  - 仓库：`tutorials/cuda-cpp/notebooks/03.02-Kernels/03.02.01-Kernels.ipynb`
- **4.2 原子操作**：data race、`atomicAdd`，直方图案例。
  - 仓库：`tutorials/cuda-cpp/notebooks/03.03-Atomics/03.03.01-Histogram.ipynb`、`Sources/atomic.cpp`
- **4.3 同步**：`__syncthreads()`、block 内协作。
  - 指南：§4.9 Asynchronous Barriers（进阶）
  - 仓库：`tutorials/cuda-cpp/notebooks/03.04-Synchronization/03.04.01-Sync.ipynb`
- **4.4 共享内存优化**：用 shared memory 降低 global 访问，优化直方图。
  - 仓库：`tutorials/cuda-cpp/notebooks/03.05-Shared-Memory/03.05.01-Shared.ipynb`、`Sources/ach.cuh`
- **4.5 协作算法**：Cooperative Groups、warp 级原语、block reduce。
  - 指南：§4.4 Cooperative Groups
  - 仓库：`tutorials/cuda-cpp/notebooks/03.06-Cooperative-Algorithms/03.06.01-Cooperative.ipynb`、`Sources/block-sum.cpp`

## 阶段 5 · 进阶与生态　〔指南 Part 3 + Part 4〕

- **5.1 CUDA Graphs**：把一串操作录制成图减少启动开销。指南：§4.2 CUDA Graphs
- **5.2 多 GPU**：指南：§3.4 Programming Systems with Multiple GPUs
- **5.3 与图形 API 互操作**（游戏开发者重点）：CUDA↔OpenGL/D3D/Vulkan。指南：§4.19 CUDA Interoperability with APIs
- **5.4 动态并行 / 高级特性巡览**：指南：§4.18 Dynamic Parallelism、§3.5 A Tour of CUDA Features（按兴趣挑 §4.x 深挖）
- **5.5 Tile 编程模型**（了解，需 Blackwell）：指南：§2.4 Writing Tile Kernels；仓库 `tutorials/cuda-tile/notebooks/01__cutile_python_intro__vector_add.ipynb`
- **5.6 Python 生态**：CuPy、Numba kernel、cuDF。指南：§2.2 Intro to CUDA Python
  - 仓库：`Accelerated_Python_User_Guide/notebooks/Chapter_05_CUDA_Kernels_with_Numba.ipynb`、`Chapter_04_Scientific_Computing_with_CuPy.ipynb`

---

# 深化篇（阶段 6–9）：主干走完后按需深挖

> 说明：阶段 0–5 是"能写出正确、够快的 CUDA"的主干。阶段 6–9 面向"写出**接近硬件极限**的 CUDA + 打通生态/图形"，把主干里浅尝的点补厚。仓库多数没有对应 notebook，以官方文档（编程指南 + **Best Practices Guide**）+ 本地 `learning/sandbox/` 实测 demo 为主。每节仍按「概念→类比→代码→实测→小结」，能测就测。

## 阶段 6 · 内存与访存深入　〔指南 §5.7、Best Practices〕

- **6.1 访存合并 coalescing 完整规则**：warp 内 32 线程访问如何被合并成内存事务；cache line（128B）、对齐、跨步/散乱访问代价；**AoS vs SoA** 布局。实测：连续 vs 跨步 vs 随机访问带宽对比。
- **6.2 常量内存与只读缓存**：`__constant__`、constant cache 广播机制、`__ldg`/`__restrict__` 只读路径。适用场景。
- **6.3 纹理内存 / 表面内存（游戏开发者重点）**：texture object、硬件插值/寻址模式/归一化坐标、空间局部性缓存；surface 读写。与图形纹理的关系。
- **6.4 内存模型与栅栏**：`__threadfence`/`__threadfence_block`/`__threadfence_system`、`volatile`、`cuda::atomic` 的 `memory_order` 全谱与 `thread_scope` 全谱；acquire/release 范式。实测一个用 fence 的 flag 通信。
- **6.5 共享内存进阶**：bank conflict 深入（32-bank、broadcast、padding 消冲突）、动态共享内存布局、`cudaFuncAttributePreferredSharedMemoryCarveout`（L1/shared 配比）。实测矩阵转置带/不带 padding。

## 阶段 7 · 性能工程方法论　〔Best Practices Guide 全本〕

- **7.1 occupancy 深入与计算**：寄存器/共享内存/block 数如何限制每 SM 驻留 warp；`__launch_bounds__`、`cudaOccupancyMaxActiveBlocksPerMultiprocessor` API、occupancy calculator；occupancy 不是越高越好。实测调 block 尺寸看占用/性能。
- **7.2 Roofline 与算术强度**：memory-bound vs compute-bound 判定，arithmetic intensity（FLOP/Byte），有效带宽/有效算力测量。用 `ncu` 指标定位瓶颈类型。
- **7.3 warp 分支与 divergence**：SIMT 重聚、predication、如何重排数据/分支减少 divergence。实测 divergent vs 规整分支。
- **7.4 指令级优化**：ILP、循环展开（`#pragma unroll`）、math intrinsics（`__fmul_rn`/`__sinf`）与 `--use_fast_math`、FP32/FP64/FP16 吞吐差异与精度权衡。
- **7.5 Nsight Compute（`ncu`）深度剖析**：单 kernel 的 SOL、内存/计算吞吐、warp stall 原因、source-level 分析。本机可装 `ncu`（winget `Nvidia.Nsight.Compute`）。

## 阶段 8 · 进阶执行特性与底层　〔指南 Part 3/4 + §5.4〕

- **8.1 动态并行**：kernel 内部再启动 kernel（`<<<>>>` from device）、device-side stream/sync、适用与开销。指南：§4.18 Dynamic Parallelism。
- **8.2 grid 级协作**：cooperative groups 的 grid group、`cudaLaunchCooperativeKernel`、grid.sync() 跨 block 同步（单次 kernel 内做全局规约/迭代）。指南：§4.4。
- **8.3 编译流程与 PTX/SASS**：nvcc 各阶段、`-arch`/`-code`/虚拟架构、fatbin/JIT；读 PTX（`-ptx`）与 SASS（`cuobjdump`/`nvdisasm`）、内联 PTX asm（`asm volatile`）。指南：§2.7、§5.4。
- **8.4 Driver API**：Runtime vs Driver API 区别；context、module 加载、`cuLaunchKernel`；何时需要 Driver API（动态加载 kernel、精细 context 控制）。指南：§3.3。
- **8.5 架构差异与新特性巡览**：Tensor Core（WMMA/MMA、混合精度）、TMA（张量内存加速器）、thread block cluster 与分布式共享内存、async copy（`cp.async`/`memcpy_async`）；Ampere→Hopper→Blackwell 关键变化。本机为 Blackwell / sm_120；具体API支持按当前Toolkit和课程实测核对。

## 阶段 9 · 生态、库与图形互操作　〔指南 Part 4〕

- **9.1 CUDA 库全景**：cuBLAS/cuDNN/cuSPARSE/cuRAND/cuFFT/nvJPEG/CUTLASS 各自定位与选型；device 端 Dx 库（cuBLASDx/cuFFTDx）。何时用库而非手写。
- **9.2 图形 API 互操作（游戏开发者重点）**：CUDA ↔ OpenGL/D3D11/D3D12/Vulkan 的资源共享（`cudaGraphicsResource`、external memory/semaphore）、CUDA 计算写入被图形管线直接渲染、同步机制。典型场景：CUDA 做粒子/流体/后处理，图形 API 渲染。
- **9.3 调试与正确性工具**：`compute-sanitizer`（memcheck/racecheck/synccheck/initcheck）、`cuda-gdb`、断言与错误处理体系化。实测用 racecheck 抓一个数据竞争。
- **9.4 数值与浮点**：IEEE 行为、`fma`、精度与可复现性、混合精度策略；仓库 `tutorials/floating-point-emulation/` 教程。
- **9.5 Python 生态深化**：CuPy 自定义 kernel、Numba `@cuda.jit`、cuDF/RAPIDS；与 C++ 路线的对应。（并入/延伸 5.6）

> 学习顺序建议：主干 0–5 走完后，游戏方向优先 6.3 纹理 + 9.2 图形互操作 + 7.x 性能方法论；通用高性能方向优先 6.1/6.4 + 7 全部 + 8.5。

---

## 图形附加路线 · 路径追踪（R.7 后）

> 完整分节、依赖和验收标准以 `learning/学习计划.md` 的 PT 阶段为准；完成情况记录在
> `learning/进度.md`。这条路线在 R.7 小型渲染器主线结束后立即开始，随后回到 C.1
> 学习 glTF。首版使用程序生成场景，采用 CPU 参考 + CUDA 实现，不以 glTF、DXR 或
> OptiX 为前置条件。

- **PT.1 辐射度量学、立体角与渲染方程**：Radiometry/Photometry、通量、强度、辐照度、辐亮度、单位与余弦投影。
- **PT.2 相机射线、几何求交与可见性**：相机射线、Sphere/Triangle/AABB、最近命中、重心坐标和数值稳健性。
- **PT.3 蒙特卡洛积分、随机变量与 PDF**：期望、无偏估计、方差、收敛、均匀/分层/重要性采样和可复现 RNG。
- **PT.4 Lambert BRDF 与余弦加权采样**：切线空间、半球采样，以及 `Li * BRDF * cos(theta) / pdf` 每一项。
- **PT.5 直接光照与 NEE**：点光/面积光、阴影射线、可见性、面积域到立体角域 PDF 转换。
- **PT.6 多重重要性采样**：BSDF Sampling、Light Sampling、Balance/Power Heuristic 和 delta 事件。
- **PT.7 多次反弹与俄罗斯轮盘赌**：路径吞吐量、发光累积、固定深度截断和无偏随机终止的区别。
- **PT.8 金属、介质与微表面 BRDF**：反射/折射、Fresnel、全反射、GGX、Smith 遮蔽和能量验证。
- **PT.9 BVH 与 CUDA 执行架构**：暴力求交基线、BVH、Megakernel、Wavefront 队列、compaction 和 Nsight 分析。
- **PT.10 D3D12 集成与评测**：线性 HDR 渐进累积、history reset、Tone Mapping、sRGB、降噪输入、External Fence 和误差/性能评测。
- **PT.11 ReSTIR**：Reservoir、时间/空间复用、可见性与 Jacobian；对照 UE5 `r.Lumen.ReSTIRGather` 原型，不把它当成 Path Tracer。
- **PT.12 辐射缓存与 NRC**：对照 UE5 `LumenRadianceCache` 与 NVIDIA Neural Radiance Cache 原理；教学用哈希/探针缓存，不宣称实现 UE5 NRC。

实现边界：光线追踪是射线生成、遍历和求交的一类方法；路径追踪是蒙特卡洛求解渲染
方程的具体算法；DXR/OptiX 是可用于加速或组织执行的 API/框架。教学中不得混称三者。
俄罗斯轮盘赌存活路径必须除以存活概率；固定最大反弹深度不能当作同一机制。CUDA 部分
必须同时解释每像素 Megakernel 与 Wavefront 队列的适用条件，以实测数据决定取舍。
ReSTIR 和 NRC 放在无偏积分器之后：先能测偏差，再讨论复用与缓存。UE5 对照以本机
`C:\xf\engine\unreal\UnrealEngine` 为准：Lumen ≠ Path Tracer ≠ NVIDIA NRC。

---

## 图形附加路线 · 抗锯齿、时域重建与超分

2026-10-22：F.1–F.10已完成声明范围的连续教学与验收，入口`learning/sandbox/d3d12/aa-reconstruction/README.md`，十节讲义位于`learning/笔记/d3d12/F.*`。实际执行NIS、FSR、XeSS与官方帧生成；DLSS/Streamline是接口对照。F实验室仍独立于H人物PT，不用F离屏GPU成本声称H的端到端FPS；当前未完成项以`learning/进度.md`为准。

> 完整分节、依赖和验收标准以 `learning/学习计划.md` 的阶段 F 为准；完成情况记录在 `learning/进度.md`。这条路线建立在小型 D3D12 渲染器之上，不属于 CUDA 编程模型本身，但会复用 GPU 资源状态、队列同步、Fence 和性能分析能力。

- **F.1 MSAA 与 Alpha-to-Coverage**：多采样颜色/深度资源、PSO sample count、coverage、Resolve。
- **F.2 离屏渲染与后处理框架**：HDR Color Target、RTV/SRV、全屏三角形、资源 ping-pong。
- **F.3 FXAA**：单帧空间边缘检测与滤波；理解低成本与细节软化/时域闪烁限制。
- **F.4 时域输入契约**：Jitter、Motion Vector、Depth、历史资源及 Camera Cut/Resize reset。
- **F.5 教学版 TAA**：历史重投影、拒绝、邻域裁剪、权重、ghosting 与 disocclusion。
- **F.6 动态分辨率与空间超分基线**：内部/输出分辨率、LOD、UI 分辨率、NIS 等空间方法。
- **F.7 FSR 官方 SDK**：按当前 FidelityFX SDK 文档集成，核对运动矢量、深度、曝光与遮罩约定。
- **F.8 DLSS/Streamline/XeSS**：比较官方 SDK 输入契约、能力查询、生命周期和失败回退。
- **F.9 帧生成与延迟**：真实帧/生成帧、Present、UI 合成、帧节奏和输入延迟。
- **F.10 质量与性能评测**：以帧序列和固定相机路径检查闪烁、拖影、遮挡显露与成本。

实现边界：MSAA、FXAA、教学版 TAA 在当前 D3D12 渲染器中亲手实现；FSR、DLSS、XeSS 和商业帧生成使用官方 SDK，不自行仿造算法核心。教学中必须明确区分抗锯齿、超分辨率和帧生成。

---

## 图形与神经表示附加路线 · 体渲染、NeRF 与 3DGS

> 完整分节、依赖和验收标准以 `learning/学习计划.md` 的阶段 G 为准；完成情况记录在 `learning/进度.md`。默认在 D3D12 网格渲染器和 CUDA/D3D12 互操作主线之后开始。

- **G.1 发射-吸收体渲染方程**：射线、密度、Alpha、透射率、离散积分与前向合成。
- **G.2 CUDA 稠密体数据 Ray Marcher**：每像素一线程、三维纹理采样、包围盒求交、共享输出纹理。
- **G.3 体渲染质量与性能**：步长、抖动、early termination、空空间跳过、occupancy grid 与 Nsight 分析。
- **G.4 NeRF 数据与表示**：相机射线、位置编码、MLP 输出密度/辐射、可微体渲染和训练损失。
- **G.5 NeRF 采样与实时化**：分层采样、occupancy grid、哈希编码、混合精度及成熟库边界。
- **G.6 3DGS 数据模型与投影**：均值、尺度/旋转、协方差、球谐颜色及二维椭圆投影。
- **G.7 3DGS 分桶与排序**：裁剪、tile overlap、prefix sum、radix sort 和 tile ranges。
- **G.8 3DGS Tile Splat**：shared memory 分批、每像素高斯权重、排序 Alpha 合成和提前终止。
- **G.9 训练与资产格式**：可微渲染、densification/pruning、相机数据和 PLY 高斯属性。
- **G.10 D3D12 集成与评测**：Render Pass、颜色/深度/同步契约，以及画质、速度、显存和可编辑性对照。

实现边界：教学版体渲染与 3DGS 前向渲染核心亲手实现；完整 NeRF/3DGS 训练先使用 PyTorch、tiny-cuda-nn 或可信上游实现，再拆解关键 CUDA 算子。必须明确体渲染是方法类别、NeRF 是隐式神经场、3DGS 是显式高斯表示；3DGS 的排序合成与通用 OIT 有联系，但不能视为同一个问题或直接等价。

---

## 全程参考（指南 Part 5 技术附录，遇到再查）

- §5.1 Compute Capabilities（你的卡 = sm_120）｜§5.2 环境变量｜§5.3 C++ 支持
- §5.4 C/C++ 语言扩展（`__global__`/`__device__`/`<<<>>>` 等语法权威定义）
- §5.5 浮点计算｜§5.6 设备端可调用 API/Intrinsics｜§5.7 内存模型｜§5.8 执行模型
