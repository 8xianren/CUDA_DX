# PT.9 CUDA 求交与执行架构主线

本目录承接 DXR Path Tracer 后的 CUDA 对照课程。当前完成 CPU 中位数二叉 BVH、CUDA 暴力/BVH 最近命中验证、Lambert/面光源 NEE/Power MIS/RR Megakernel 与 CPU double 小图参考，以及分阶段 Wavefront/原子压缩/确定性归并；样本级控制组与Nsight Systems已完成，Compute硬件计数器因权限未取得，用户已授权跳过，PT.9按调整范围结束（后文保留历史验收过程）。

讲义：[PT.9-从最近命中到CUDA-BVH](../../../笔记/path_tracing/PT.9-从最近命中到CUDA-BVH.md)。

第二小节：[PT.9-CUDA路径状态与Megakernel](../../../笔记/path_tracing/PT.9-CUDA路径状态与Megakernel.md)。

第三小节：[PT.9-Wavefront队列与路径压缩](../../../笔记/path_tracing/PT.9-Wavefront队列与路径压缩.md)。

|文件|职责|
|---|---|
|`geometry.h`|显式 Triangle/Node/Ray/Hit 布局，CPU/CUDA 共用 slab、三角形、暴力与栈式 BVH 遍历|
|`scene_io.h`|本课小端版本化二进制场景，数量/范围/身份检查|
|`scene_export.cpp`|复用已有 Assimp/CpuScene/WorldTriangles，把 PT.8 gallery 导出为世界三角形；只保存材质基础/发光因子|
|`bvh_build.h`|CPU 最长中心轴/中位数分组、叶子最多4图元，树结构和覆盖验证|
|`cuda_support.h`|CUDA 分配、上传/读回、stream/event 的单一所有权与错误检查|
|`bvh_reference.h`|独立 double 平面/Gram 求交参考，固定随机射线和解析场景|
|`bvh_verify.cu`|128线程/block，GPU 暴力/BVH 对照、12组 slab、CPU审计、坏输入拒绝和计时|
|`verify_bvh.ps1`|构建 CPU 导出器、导出场景、sm_120 编译、完整运行与 quick memcheck|
|`path_math.h`|float/double向量代数、固定路径身份的无状态随机维度、余弦采样和Power权重|
|`path_integrator.h`|配置、路径/阴影任务状态、相机射线、单顶点着色、逐像素完整积分；可由后续Wavefront复用|
|`path_host.h`|灯表、配置/材质约束、独立double平面/Gram求交、CPU参考、22三角形盒室、线性PFM/预览PPM输出|
|`path_gpu.cuh`|GPU场景所有权、每像素一线程Megakernel、事件计时与完成后读回|
|`path_verify.cu`|五种CPU/GPU配置、解析发光/黑色、RR保留NEE、block变体、分批样本与两场景出图|
|`verify_paths.ps1`|sm_120编译、完整路径验收、quick memcheck|
|`analyze_paths.py`|PFM误差复核、GPU图像、CPU/GPU差异图和逐深度活跃路径曲线|
|`path_checks.h`|CPU/Megakernel/Wavefront共享的逐像素误差、路径摘要和计数验收|
|`wavefront.cuh`|固定stateId的路径池、双射线索引队列、命中记录、阴影队列；warp参与线程聚合原子压缩、分阶段kernel、固定顺序归并|
|`wavefront_verify.cu`|20组压缩集合/溢出保护、11种渲染配置、CPU/Mega对照、倒序入队/block/样本偏移检查|
|`verify_wavefront.ps1`|构建、完整验收、quick memcheck与synccheck|
|`analyze_wavefront.py`|线性PFM逐值一致性复核、队列有效项/网格容量图与后端并排预览|

从仓库根目录运行：

```powershell
& .\learning\sandbox\path_tracing\cuda-path-tracer\verify_bvh.ps1
```

依赖现有 PT.8 资产 `../dxr-path-tracer/results/pt08/gallery.gltf` 及其关联文件。脚本使用已有 `d3d12/gltf-scene` CMake 工程/Assimp 和 `learning/sandbox/build.ps1`，不重新解析另一套 glTF，也不读取 DXR 不透明 BLAS 内部格式。CMake 导出器是 Release；CUDA 宿主构建沿用 build.ps1，未额外开启 MSVC 优化，不能据此评价优化后的 CPU 构建性能。

从仓库根目录单独编译、运行（要求已有导出数据）：

```powershell
& .\learning\sandbox\build.ps1 path_tracing\cuda-path-tracer\bvh_verify.cu -NoRun
$lesson = Join-Path (Get-Location) 'learning/sandbox/path_tracing/cuda-path-tracer'
& "$lesson/bvh_verify.exe" "$lesson/results/bvh/gallery.meshbin" "$lesson/results/bvh/manual" full
& compute-sanitizer --tool memcheck --leak-check full --error-exitcode 1 "$lesson/bvh_verify.exe" "$lesson/results/bvh/gallery.meshbin" "$lesson/results/bvh/manual-sanitizer" quick
```

程序参数：导出的 meshbin、输出目录、`full` 或 `quick`。完整模式8197条 gallery 射线/512条CPU独立审计；quick为129/64，解析场景仍全部运行。结果直接写 `results/bvh/`：`bvh.csv`、`metadata.txt`、构建/运行/导出日志、`memcheck.txt`；sanitizer数据在其子目录，不能拿插桩时间当性能。

验收：最近ID全相同；GPU BVH/暴力的距离归一化差<1e-5；CPU double差<3e-5、重心差<.003；所有结构/栈错误计数0。坏子索引、环、重复图元、零方向在CPU拒绝。闭区间端点、±0、平行、退化、空树、.001/1000缩放、重叠与首命中负对照均覆盖。具体结果见讲义。

边界：CPU构建、静态世界三角形、双面几何，不含 alpha 可见性；float Möller–Trumbore 不是 watertight 实现；包围盒采用当前尺度的保守外扩，不宣称所有浮点输入都严格稳健。导出的材质因子不是 PT.8 完整 PBR/纹理/玻璃材质。GPU 64项私有遍历栈已报告512B local memory；未据此推断实际访存瓶颈，留给 Nsight。

## Megakernel运行与验收

工作目录仍是仓库根目录；先执行过BVH脚本，确保`results/bvh/gallery.meshbin`存在：

```powershell
& .\learning\sandbox\path_tracing\cuda-path-tracer\verify_paths.ps1
```

完整CPU参考使用31×17、8spp，K0/K1/K4、MIS/RR/BSDF-only共五组，CPU保留double射线/代数并用平面+Gram暴力求交，GPU使用float/BVH；共同积分代数不构成完全独立的积分器实现。逐像素检查线性RGB归一化差<2e-4、离散路径哈希与计数一致；哈希是摘要，不是逐顶点轨迹日志。64/128/256 block RGB完全一致；4+4样本对8样本误差<2e-6。解析恒定Le/黑色、RR不能删除当前NEE任务、非法深度与零SPP均通过。

完整模式另输出144×96/128spp/K8盒室和192×96/32spp/K6 gallery。后者把导出base因子解释为Lambert反射率，忽略金属/粗糙度/玻璃/纹理，并非PT.8完整材质的CUDA移植。大图未逐路径CPU审计，CSV误差字段写-1代表未测，不是零误差。quick模式13×9/4spp保留上述小图/解析/调度检查，跳过大图。

结果直接进入`results/megakernel/`：`paths.csv`含路径/阴影射线、逐深度活跃数、RR终止数、误差和GPU中位时间；`metadata.txt`含布局/寄存器/local；`*.pfm`保留线性float；`*.ppm`仅为Reinhard+sRGB预览。memcheck日志与插桩CSV在独立子目录。

图像分析依赖NumPy/Matplotlib/Pillow。本机Python3.14已在本课build目录安装依赖，未更改系统包；首次复现可运行：

```powershell
python -m pip install --target .\learning\sandbox\path_tracing\cuda-path-tracer\build\python-deps matplotlib
python .\learning\sandbox\path_tracing\cuda-path-tracer\analyze_paths.py
```

安装和执行须用同一Python版本。分析生成`gpu-images.png`、`cpu-gpu.png`、`active-paths.png`和`analysis.json`。依赖只供绘图，不参与CUDA构建或正确性验收。

执行边界：每像素顺序求和多个样本，固定最大散射K≤16，黑色环境，灯三角形等概率选择，固定1e-4米级偏移；阴影当前复用closest求交，未加入any-hit优化。没有动态场景、全glTF材质移植或GPU显示；Wavefront见下节。Megakernel初次验收报告83寄存器/624B local/0静态shared，不能直接据此宣布性能瓶颈。

## Wavefront运行与验收

上段为Megakernel小节当时的范围与资源记录；本小节已补齐Wavefront，当前统一诊断哈希后的Megakernel为86寄存器/624B local，历史图像与积分公式保持。

从仓库根目录执行：

```powershell
& .\learning\sandbox\path_tracing\cuda-path-tracer\verify_wavefront.ps1
python .\learning\sandbox\path_tracing\cuda-path-tracer\analyze_wavefront.py
```

依赖同一`results/bvh/gallery.meshbin`。结果在`results/wavefront/`，含`wavefront.csv`、逐深度`queues.csv`、`attributes.csv`、完整/插桩日志、PFM/PPM和PNG。memcheck、synccheck分别写独立子目录；`megakernel-regression/`保存共享诊断改动后的旧验证器完整回归，不覆盖上一节历史记录。

full包含五组31×17×8 CPU double对照，以及1×1×1/K16、7×5×3/非零sampleOffset、空场景、解析发光、144×96×128盒室和192×96×32 gallery。所有11配置与Megakernel线性RGB逐值相同、路径摘要/计数一致；大图CPU误差字段-1表示未测。每层队列数量与每路径深度统计互相核对。反转初始队列、64/128/256 block、4+4对8样本通过。20组整数选择集合检查覆盖1/31/32/33/129输入和零/全/交替/稀疏选择；129项挤入容量1时仅写1项，报告128次越界，未越界写入。quick缩小主验证图为13×9×4且跳过两大图；memcheck零错误/零泄漏，synccheck零错误。

设计：一个初始像素样本对应固定stateId，所有样本并行；双射线队列只传uint32 ID，命中记录按当前槽位连续写，阴影任务按stateId存放。相邻阶段在同一nonblocking stream排序，不在每深度CPU读回计数。各深度交/着色/阴影仍启动最大容量网格，超出device计数的线程退出；数据已压紧不代表网格缩小。最终按原sample顺序归并，禁止浮点atomicAdd改变累加顺序。

工作区精确为256N+144B（N=W×H×SPP），不含场景和104B/像素输出；gallery约144MiB，盒室约432MiB。N最多4,194,304，超限在分配前拒绝。当前使用按职责分数组、数组元素内部AoS布局；未做字段级SoA优化。显式kernel启动数2+3(K+1)，另有一次异步计数清零。完整测量1预热/3次中位，包含整条Wavefront链路但不含分配/上传/读回，不把诊断初测当作正式Nsight归因。

本节结束时的接续要求（样本控制组与Systems现已在第四小节完成）：加入“一线程一样本的Megakernel”控制并行粒度，再用Nsight核对分支、访存、队列和launch成本。当前像素Megakernel串行SPP而Wavefront并行SPP，不能把初测的全部加速归因于阶段拆分。PT.9保持未完成。


## 第四小节：样本并行控制与执行时间线

讲义：[PT.9-样本并行控制与Nsight时间线](../../../笔记/path_tracing/PT.9-样本并行控制与Nsight时间线.md)。

|文件|职责|
|---|---|
|`sample_megakernel.cuh`|一线程一样本完整路径、104B样本结果、固定顺序归并控制组|
|`execution_bench.cu`|三后端逐值检查、block控制、CPU quick、3预热/9轮轮换计时、profiler范围、理论occupancy|
|`verify_execution.ps1`|sm_120编译、三场景独立计时与quick memcheck|
|`profile_execution.ps1`|Systems捕获/SQLite导出或Compute full/raw导出；不修改驱动权限|
|`analyze_execution.py`|原始CSV/SQLite核对、保留采集警告、计时图与执行时间线|

工作目录仓库根；先有本目录BVH验收产生的gallery.meshbin：

```powershell
& ./learning/sandbox/path_tracing/cuda-path-tracer/verify_execution.ps1
& ./learning/sandbox/path_tracing/cuda-path-tracer/profile_execution.ps1 -Tool Systems
python ./learning/sandbox/path_tracing/cuda-path-tracer/analyze_execution.py
# 硬件计数器权限满足后才执行Compute采集
& ./learning/sandbox/path_tracing/cuda-path-tracer/profile_execution.ps1 -Tool Compute
```

结果在`results/execution/`：cornell/gallery/empty的checks、timings、attributes、metadata；memcheck；nsys-pixel/sample/wave原始报告与SQLite；timing-summary.csv、timeline.csv、analysis.json及两张分析图。软件trace探针nsys-sw-wave保留作诊断，不混入主表。Python绘图复用本课build/python-deps。

盒室pixel/sample/wave中位27.265663/12.756128/16.542400ms，gallery40.751873/10.546560/9.595648ms；三后端RGB差0，CPU quick最大归一化差3.39992e-7，memcheck0错误/0泄漏。旧Mega完整回归和历史PFM逐字节对照通过。Systems记录预期1/2/23个kernel、顺序正确；报告仍警告可能遗漏CUDA事件，不能宣称全量完整捕获。Compute拒绝ERR_NVGPUCTRPERM，硬件分支/访存和实际occupancy分析待权限解除，PT.9仍未完成。


## 第五小节：队列压缩与状态地址布局

讲义：[PT.9-队列压缩与状态地址布局](../../../笔记/path_tracing/PT.9-队列压缩与状态地址布局.md)。

|文件|职责|
|---|---|
|`queue_layout_audit.cu`|复用实际Wave阶段，逐层同步读回有效stateId前缀，验证身份/深度/有效性/唯一性与最终图像|
|`analyze_queue_layout.py`|检查原始u32长度/集合，比较当前AoS、假设同ID SoA、假设按slot字段的单标量32B地址段覆盖|
|`verify_queue_layout.ps1`|sm_120构建、完整gallery/空场景、quick CPU与memcheck、地址模型分析|

工作目录仓库根；依赖本目录已有results/bvh/gallery.meshbin：

```powershell
& ./learning/sandbox/path_tracing/cuda-path-tracer/verify_queue_layout.ps1
python ./learning/sandbox/path_tracing/cuda-path-tracer/analyze_queue_layout.py
```

结果写入`results/queue-layout/`，按gallery/empty/sanitizer分组。每层原始小端uint32编号是ray-d.u32/shadow-d.u32，queues.csv给出数量/容量/结构跨度；checks.txt记录Mega/CPU误差，address-model.csv与analysis.json保存计算，address-coverage.png为分析图。Python复用build/python-deps。

完整gallery与Mega逐RGB相同，1188588路径/536510阴影查询逐层一致；空场景/尾warp正常。quick CPU最大归一化差7.42492517611e-8、memcheck0错误/0泄漏。模型7个解析检查通过。诊断插入了同步和读回，不用于性能计时；SoA与按slot打包仅为地址模型，未实现或测量这些渲染后端，不包含重排成本。硬件访存/分支分析仍等待Compute计数器权限，不能用地址覆盖替代。


2026-10-21用户明确授权跳过PT.9剩余Nsight Compute硬件计数器分析；已完成内容保留，分支效率/缓存命中/实际访存指标标为跳过、未验证，不作硬件归因。原权限阻塞解除为课程范围调整，按此范围结束PT.9并进入PT.11。
