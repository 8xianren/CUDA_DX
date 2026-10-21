# PT.9 样本并行控制与 Nsight 时间线

2026-10-21。代码：[cuda-path-tracer](../../sandbox/path_tracing/cuda-path-tracer/README.md)。前接[Wavefront队列与路径压缩](PT.9-Wavefront队列与路径压缩.md)。本节完成控制实验与 Systems 时间线；Compute 硬件计数器受驱动权限限制，PT.9 尚未完成。

## 上节自测答案

1. `atomicAdd(count,n)`分配互不重叠的槽位，不等于后续payload已经写好。计数更新早于普通store时，同kernel消费者不能只看count就安全读取。本课以同stream的kernel结束/后继kernel开始作为阶段边界，消费者在生产者完成后运行。
2. `alive`表示是否继续下一段路径；`shadow.valid`表示当前顶点是否产生待验证的直接光贡献。RR终止下一段不能删除已经形成的当前NEE估计。两个条件分别压缩进ray和shadow队列。
3. 原像素Mega串行处理SPP，Wave并行处理全部样本，两种改变同时发生。必须增加一线程一样本、完整路径仍在同一kernel的控制组，才能避免把样本并行收益全归给阶段拆分。

## 从计算问题推导线程映射

每个像素的有限样本估计是 `L[p]=(1/S) sum_s F(p,s)`。本课的样本由`pixel,sample,seed,depth,dimension`确定；固定场景下不同样本之间没有读写依赖。原实现每个像素线程依次计算全部F，数学上并不要求这种串行顺序。

令P=W×H，N=P×S。构造一维索引`id=p*S+s`，因此`p=id/S`、`s=id%S`；全局样本编号再加`sampleOffset`。一个线程负责一个id，仍在同一个kernel内走完整条路径。最后另一个kernel按s升序归并像素。这类似把每个像素的一串独立任务展开到作业系统，再固定顺序收集结果。

实现见`sample_megakernel.cuh:7`，共用积分见`path_integrator.h:109`。`IntegrateSample`与旧`IntegratePixel`共用相同几何、着色和随机维度，未新写一套“看起来相同”的积分器。

为什么不直接`atomicAdd(pixelColor, sampleColor)`？浮点加法不满足结合律，调度改变相加顺序会改变舍入；而且同像素样本争用相同原子位置。本课用一个像素线程严格按原顺序累加，让差异来源更可控。归并仍需计算、读写内存，不能算免费。

## 布局、所有权与同步

|后端|完整路径并行粒度|中间工作区|gallery kernel数|
|---|---|---|---:|
|pixel|一线程一像素，循环SPP|无额外样本池|1|
|sample|一线程一样本，完整路径|104N字节|2|
|wave|一线程处理一个有效队列项的一阶段|256N+144字节|23|

工作区不包括场景与104P字节公共输出。104B的PixelResult含RGB与诊断统计，不是只有12B颜色。gallery有589824条初始路径，样本池61341696B=58.5MiB，Wave工作区150995088B≈144MiB。盒室初始路径1769472，样本池175.5MiB、Wave约432MiB。

宿主`DeviceBuffer`/`WaveStorage`拥有分配，kernel只借用指针。三种工作区在测量前都已分配并同时驻留，避免分配开销混入，但这不是各后端单独运行的进程显存峰值。调用者验证N≤4194304、合法SPP/K/尺寸；同一nonblocking stream内先SampleMegakernel再SampleResolve，归并读取时前者已完成。宿主等stream/event完成后读回和释放。`cudaGetLastError`检查启动错误，异步执行错误在后续同步处检查，错误统一抛异常并报告失败。

这个控制组也增加了样本结果写回和归并，因此不是只改一个参数的纯实验；它足以反驳“旧加速完全来自阶段拆分”，不能精确拆解每种成本的独立百分比。

## 先验证，再测性能

`execution_bench.cu`先执行三个后端，逐像素检查RGB、路径摘要与统计；再测64/256线程的样本Mega；quick模式与CPU double参考比较。所有变体通过后，3轮预热、9轮正式测量，轮换后端先后顺序。CUDA event包围完整GPU提交链，包括Wave计数清零和所有阶段，不包含场景构建、分配、上传和读回。

宿主chrono记录提交开始到event等待结束的时间，包含CPU提交和等待。它与GPU区间重叠，二者不能相加。9轮min/max是观察范围，不是统计置信区间，尤其微小任务容易受调度抖动影响。

本机RTX5070/48SM，sm_120，驱动610.88，Toolkit13.3.33。以下为无profiler独立GPU事件中位数，单位ms：

|场景|pixel|sample|wave|
|---|---:|---:|---:|
|盒室144×96×128，K8|27.265663|12.756128|16.542400|
|gallery192×96×32，K6|40.751873|10.546560|9.595648|
|空场景7×5×3，K4|0.011840|0.015008|0.104192|

![三后端独立计时](../../sandbox/path_tracing/cuda-path-tracer/results/execution/timing-comparison.png)

盒室中Wave比sample耗时高约29.7%；gallery中Wave比sample耗时低约9.0%，不是旧pixel对Wave看起来的约4倍全部来自拆分。空场景几乎没有路径计算，固定阶段和调度开销仍存在，Wave更慢。不能据空场景单次差值反推出普适的每次launch成本。

验收：三场景RGB差严格为0、路径统计/摘要一致；盒室8974546次查询，gallery1725098次。quick CPU最大归一化差3.39992e-7，memcheck 0错误/0泄漏。旧Megakernel完整回归通过；新pixel图与上一节Wavefront验收中的pixel图文件逐字节相同。

## 捕获范围与关键API

本节新增使用的Runtime API原型（省略平台修饰符）：

```cpp
cudaError_t cudaProfilerStart(void);
cudaError_t cudaProfilerStop(void);
cudaError_t cudaOccupancyMaxActiveBlocksPerMultiprocessor(
    int* numBlocks, const void* func, int blockSize, size_t dynamicSMemSize);
```

Start/Stop无参数，控制活动profiler的采集；它们不代替GPU完成同步。代码在预热后Start，提交一次指定后端，`cudaStreamSynchronize(stream)`成功后Stop，再读回验证。所有返回值交给CheckCuda。脚本要求`--capture-range=cudaProfilerApi`，所以初始化与预热不进入目标范围。当前工具Start自身耗时约0.77—0.93秒，是采集启动开销，不能算作渲染帧耗时。

occupancy函数的`numBlocks`是宿主输出指针，`func`是已编译的kernel，`blockSize`为每block线程数（本课128），`dynamicSMemSize`为每block动态shared字节数（本课0）。结果是受寄存器/shared/线程等资源限制的理论可驻留block数；不是实际有用线程比例。当前设备每SM最多1536线程，理论占用率按`blocks*128/1536`计算。

|kernel|每线程寄存器|每线程local B|理论blocks/SM|理论占用率|
|---|---:|---:|---:|---:|
|pixel Mega|86|624|5|41.67%|
|sample Mega|76|624|6|50.00%|
|SampleResolve|48|0|10|83.33%|
|WaveGenerate|32|0|12|100%|
|WaveIntersect|48|512|10|83.33%|
|WaveShade|98|0|4|33.33%|
|WaveShadow|48|512|10|83.33%|
|WaveResolve|60|0|8|66.67%|

local是线程私有地址空间，不能仅凭名字当作片上内存；这里求交栈有local分配，但512B并不等于每条光线固定发生512B DRAM传输。缓存、访问次数和路径相关。理论occupancy上限也不能推出实际occupancy、分支效率或性能因果；WaveShade甚至比Mega理论上限低。

## Nsight Systems真正记录到什么

三份gallery报告分别检查到1、2、23个预期kernel，名称/顺序正确，kernel属于同一stream且不重叠。Wave有1次memset；范围内没有记录到memcpy。23=Generate+7×(Intersect+Shade+Shadow)+Resolve，K6意味着深度0…6都要处理；最后一层仍处理发光，但不再散射。

|后端|kernel总时长ms|首kernel开始至末kernel结束ms|CPU launch API总区间ms|
|---|---:|---:|---:|
|pixel|40.686877|40.686877|0.068468|
|sample|10.597771|10.599851|0.083933|
|wave|9.761737|9.819625|0.165364|

![gallery时间线](../../sandbox/path_tracing/cuda-path-tracer/results/execution/kernel-timeline.png)

这是另一个进程中单次被采集执行，不与9轮独立中位数混作同一测量。Wave kernel之间间隙共0.057888ms；它不等于CPU launch耗时，因为CPU提交可与GPU执行重叠。Wave前面的memset时长0.000288ms不包含在“首kernel至末kernel”这一列内，独立event基准则包含清零。

有效路径深度0→6由589824降到533，但本课Intersect/Shade/Shadow都固定launch4608×128线程，并用device count早退。压缩减少有效负载，尚未缩小网格。深度6的Shade/Shadow分别仍有0.006656/0.002912ms，阴影队列为0仍启动。Generate+Resolve合计1.053974ms，是分阶段执行实际支付的成本之一。

**采集限制必须保留**：三份Systems报告的DIAGNOSTIC_EVENT均有“Not all CUDA events might have been collected.”；额外`--trace=cuda-sw`探针仍有同样警告。预期kernel数量/顺序吻合，不等于证明所有CUDA API事件都完整。分析脚本保留警告，不能据此报告完整无遗漏的系统时序。

Compute探针被ERR_NVGPUCTRPERM拒绝，尚未取得分支、local/global访存、缓存命中、实际occupancy等硬件计数。已向用户请求管理员采集或在NVIDIA App允许计数器访问；没有擅自修改驱动设置。当前不能把“分支发散减少”或“带宽受限”写成实测结论，PT.9整章仍未验收。

商业路径追踪器会按着色成本、材质分布和硬件执行机制选择调度，并减少队列状态、诊断字段或使用更复杂的任务分配；本课固定容量网格、完整诊断记录、软件BVH用来隔离和解释机制，不是商业渲染器性能结论，也不是RT Core基准。

## 动手与后续验收

工作目录仓库根：

```powershell
& ./learning/sandbox/path_tracing/cuda-path-tracer/verify_execution.ps1
& ./learning/sandbox/path_tracing/cuda-path-tracer/profile_execution.ps1 -Tool Systems
python ./learning/sandbox/path_tracing/cuda-path-tracer/analyze_execution.py
# 只有驱动计数器权限已满足时，才执行下一条；无需重跑上面的正确性验证。
& ./learning/sandbox/path_tracing/cuda-path-tracer/profile_execution.ps1 -Tool Compute
```

results/execution保存原始timings/checks/attributes/metadata、memcheck、三份Systems原始报告与SQLite、分析CSV/JSON和图片。软件trace探针单独保留nsys-sw-wave，不混入正式表格。

下一小节补齐硬件计数器，联系活跃路径、AoS访问与实际warp执行，而不是先认定Wavefront获胜。自测：1）50%理论occupancy等于一半线程在做有效工作吗？2）为什么CPU launch时间不能直接加到GPU kernel总时间？3）保持同样随机数后，为什么仍固定样本归并顺序？后续直接给答案并继续，不等待用户作答。

参考：[Nsight Systems采集范围](https://docs.nvidia.com/nsight-systems/UserGuide/index.html)、[Nsight Compute分析机制](https://docs.nvidia.com/nsight-compute/ProfilingGuide/index.html)、[NVIDIA计数器权限说明](https://developer.nvidia.com/nvidia-development-tools-solutions-err_nvgpuctrperm-permission-issue-performance-counters)。Runtime原型核对本机CUDA13.3的cuda_runtime_api.h:4453与cuda_profiler_api.h:102/123。
