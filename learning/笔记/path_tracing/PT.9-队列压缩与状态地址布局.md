# PT.9 队列压缩与状态地址布局

2026-10-21。[共享代码与命令](../../sandbox/path_tracing/cuda-path-tracer/README.md)。前接[样本并行控制与Nsight时间线](PT.9-样本并行控制与Nsight时间线.md)。本节用真实GPU队列快照推导访问地址，不把地址模型冒充Nsight硬件流量；Compute计数器权限仍待用户操作，PT.9尚未验收完成。

## 上节自测答案

1. 50%理论occupancy只表示按block尺寸和资源需求计算的最大驻留warp比例，不意味着一半线程在做有效路径工作。实际网格有多少block、队列有多少有效项、warp遇到什么分支，都属于不同问题。
2. CPU提交kernel与GPU执行能够重叠，所以CPU launch API区间不能直接加到GPU kernel时间上；排队、等待和执行要按时间线分析。
3. 相同随机数保证每条样本的随机输入相同，但浮点累加顺序仍影响舍入。本课固定样本归并顺序，以免将调度带来的浮点变化误判为路径算法变化。

## 先区分三个空间

游戏里的实体列表可以连续保存entityId，但entityId指向的组件可能分散。Wavefront有相同区别：queue[slot]连续，只能证明“索引表连续”，不能证明states[queue[slot]]连续。

```text
执行线程： slot 0, 1, 2, 3, ...
索引队列： id   4, 9, 17, 80, ...  （示意，不是某份采集数据）
路径池：   states[4], states[9], states[17], states[80], ...
```

slot是本层任务位置；stateId是稳定样本身份；字节地址由数组布局和stateId共同决定。压缩只搬4B编号，没有搬88B状态对象。稳定身份保证重排不改变pixel/sample对应随机序列，但代价是读取状态需要间接寻址（先读编号，再按编号取数据）。

## 从实际布局推导地址

程序用sizeof/offsetof静态断言核对布局，用实际cudaMalloc指针模32检查基址对齐：

|PathState<float>字段|字节数|起始偏移|
|---|---:|---:|
|ray：origin、direction、tmin、tmax|32|0|
|beta|12|32|
|radiance|12|44|
|previousPosition|12|56|
|previousPdf|4|68|
|pixel/sample/depth|12|72|
|alive与尾部填充|1+3|84|

合计88B。ShadowTask是32B ray、12B contribution、1B valid和3B填充，共48B。填充属于C++结构体布局，不能和数据压缩编码混为一谈。

AoS（Array of Structures，结构体数组）将同一路径的字段放在一起；若一个warp的线程各读取一个origin.x，队列编号q_i对应地址：

`a_i = B + 88*q_i + 0`。

SoA（Structure of Arrays，按字段分数组）假设为每个字段单独建立数组，则`originX[q_i]`地址变成：

`a_i = Bx + 4*q_i`。

这只改变布局，没有改变q_i稀疏性。再假设真的把origin.x按slot打包到本层队列，则地址是`Bd + 4*i`。第三种模型还需要搬运数据、保持身份映射、在后续阶段维护一致性；这些成本不在本节地址覆盖计算中。SoA与dense均为比较模型，未声称已实现对应渲染后端。

## 32B地址段模型

按照NVIDIA对现代CUDA全局访存合并的说明，warp的访问可按覆盖的32B段理解。本节只考虑一次4B标量读取、对齐基址、每个逻辑有效lane参与同一读取，定义：

`segment_i = floor(a_i / 32)`，`C_warp = unique(segment_i).size()`。

4B对齐的float不会跨32B边界，因此这个单字段模型不需额外计跨段。满warp连续32个float共128B，对齐时覆盖4段；若从第1个float偏移开始，则覆盖5段。线程把同一组地址反序读取不会改变段集合。若编号间隔8，则SoA地址间隔32B，32lane覆盖32段。

AoS的88B跨度大于32，所以不同路径的origin.x必在不同段；32lane对应32段。这里只对“同一标量指令的地址集合”作推导：实际编译器可能使用其他加载宽度，读取其他字段会复用段，跨warp会共享缓存，DRAM请求又受缓存命中影响。因此不能从4段对32段推导8倍带宽或8倍渲染加速。

参考：[NVIDIA合并访存说明](https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/index.html#coalesced-access-to-global-memory)。

## 真实GPU快照如何取得

`queue_layout_audit.cu`复用WaveGenerate/Intersect/Shade/Shadow/Resolve：生成或上一层完成后读ray队列，Shade完成后读shadow队列。所有读取前调用`cudaStreamSynchronize(stream)`并检查成功，CPU不会观察到正在写入的半成品队列。

核心读取API原型（省略平台修饰符）：

```cpp
cudaError_t cudaMemcpy(void* dst, const void* src, size_t count, cudaMemcpyKind kind);
```

dst为宿主vector.data()；src是device队列指针；count为有效项数量×sizeof(uint32_t)，单位字节；kind为cudaMemcpyDeviceToHost。仅在数量非0时调用，避免空vector指针操作。复制不转移分配所有权：DeviceBuffer仍拥有GPU数组，vector拥有宿主副本。前面的stream同步检查异步执行错误，cudaMemcpy返回值检查复制错误。同步完成后才检查CPU副本并写文件。

每层验证ID在范围内、无重复、ray指向alive且depth匹配的状态、pixel/sample对应稳定身份、shadow指向valid任务。最后每层队列数对照路径统计，总数对照射线统计，输出对照Megakernel。文件为小端uint32有效前缀，queues.csv保存count/capacity/stride/offset，Python检查文件长度与ID集合。

诊断执行插入了同步和读回，跨warp原子入队顺序也可能随调度改变。因此这份快照是一次真实有效执行，不宣称逐项复现上一节基准进程的队列顺序，更不能用诊断程序计时比较性能。

## gallery实际结果与推导结果

初始容量N=589824，后续ray队列数量与前节统计一致。每个非空逻辑warp读取一个origin.x时覆盖的32B段数如下；最后不足32lane的warp也计入平均：

|深度|有效ray数|当前AoS模型|相同ID的SoA模型|按slot打包模型|
|---|---:|---:|---:|---:|
|0|589824|32.000|4.000|4.000|
|1|439815|31.998|4.991|4.000|
|2|138387|31.997|12.418|4.000|
|3|14074|31.986|27.623|4.000|
|4|4456|31.829|30.243|3.979|
|5|1499|31.894|31.213|4.000|
|6|533|31.353|31.176|3.941|

深度0编号连续，SoA模型覆盖少；后来存活ID稀疏，改成SoA仍可能让同一warp读取许多地址段。这证明“队列压紧”和“状态字段连续”是独立条件，不能用前者推出后者。近32的段数也不是已证明缓存全部miss。

![地址覆盖模型](../../sandbox/path_tracing/cuda-path-tracer/results/queue-layout/address-coverage.png)

有效项压缩到前缀后，深度6只有17个逻辑warp含有效工作，533/(17×32)≈97.98%的这些lane有效；但整个固定网格仍有589824线程，533/589824≈0.09037%。这两个比例分母不同，均不是硬件occupancy，也不能表示整个kernel期间的实际活跃lane平均值。

当前内存组织是按职责分数组（states、stats、hits、shadow等），每个数组元素内部仍AoS。hits按slot写，而states与shadow按stateId查，所以不能笼统称所有数组都同样连续。商用实现可以选择更紧凑字段、按材质/方向重排、SoA或搬运紧凑任务；各方案都需计入写回、维护和同步成本，仍需实测决定。

## 验收与复现

结果目录`results/queue-layout/`；gallery保存每层ray/shadow原始ID快照、manifest、对照结果和图像；empty覆盖空队列；sanitizer为小尺寸CPU对照与memcheck。地址模型另有连续、反序、稀疏、尾warp、空、偏移等7个解析断言。

工作目录仓库根：

```powershell
& ./learning/sandbox/path_tracing/cuda-path-tracer/verify_queue_layout.ps1
# 已有完整快照时，仅重做CPU地址模型与图：
python ./learning/sandbox/path_tracing/cuda-path-tracer/analyze_queue_layout.py
```

实际验收全部通过：gallery完整快照与Mega逐RGB差0，1188588条路径查询和536510条阴影查询逐层核对一致；空场景468条初始射线后全部队列为空。quick gallery CPU double最大归一化差7.42492517611e-8，1023条路径/489条阴影查询；memcheck 0错误、0泄漏，7个解析地址检查通过。

本节没有改变渲染主线、没有取得硬件缓存/分支计数。PT.9剩余硬件归因等待既有Compute权限问题解决，不把本节模型当作替代验收。下一节直接回答：1）为什么反序读取32个连续float仍只覆盖4段？2）为什么SoA不能保证稀疏stateId访问连续？3）如果搬运路径状态到紧凑队列，除了读更连续，还必须比较哪些成本？


## 接续自测答案与阻塞记录

1. 反序读取不改变地址集合，所以同一个32B对齐的连续32-float区间仍覆盖4段；合并访存关注参与线程请求的地址集合，不要求lane编号按地址升序。
2. SoA把字段跨度改为4B，但地址仍为base+4*stateId。编号若相隔8，地址就相隔32B，连续队列slot仍可能访问32个段。
3. 真正搬运状态到紧凑队列需要增加读取、写入、分配/容量管理、身份映射与阶段同步；还要比较是否影响后续归并、缓存复用和总时间，不能只比较某一个字段的读取。

2026-10-21接续核对：results/execution下没有ncu报告，未发现ncu或execution_bench采集进程；现有probe.txt明确ERR_NVGPUCTRPERM。同一权限问题已连续三个目标回合未解除，其间已完成独立时间线和真实队列布局工作。按既定先完成PT.9再进入PT.11/PT.12的顺序，当前剩余硬件测量需要用户管理员采集或允许GPU性能计数器访问。目标记为blocked（不是完成，也不是用户请求暂停）。恢复后先读取新报告，再完成硬件归因和PT.9验收，之后继续PT.11与PT.12。
