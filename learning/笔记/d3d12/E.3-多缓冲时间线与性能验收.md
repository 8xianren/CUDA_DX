# E.3 多缓冲、时间线与性能验收

2026-10-21。本节完成E.1–E.3连续学习的最后一节。代码：[共享主线README](../../sandbox/d3d12/cuda-interop/README.md)；数据：[analysis.json](../../sandbox/d3d12/cuda-interop/results/e3/analysis.json)；图：[固定工作量](../../sandbox/d3d12/cuda-interop/results/e3/timing-comparison.png)、[GPU时间线](../../sandbox/d3d12/cuda-interop/results/e3/gpu-timeline.png)。

## 先从冲突推导缓冲数量

定义C_f为第f帧CUDA生产，G_f为第f帧D3D12消费。单缓冲有C_f→G_f→C_(f+1)，上一帧绘制结束前不能覆盖。若有N份独立数据，令槽位s=f mod N，那么本次覆盖的上一使用者是f-N，故约束变为G_(f-N)→C_f→G_f。f<N时本批第一次使用槽位，无上一帧。两条队列各自仍按顺序执行，并非任意重排。

双缓冲例：f0写A/G0读A；f1可写B，同时G0仍读A；f2写A前等G0而不是等G1。三缓冲则在f3才第一次复用A。多缓冲消除了不必要的数据地址冲突，提供重叠机会，但不保证驱动/硬件实际同时执行。

如果理想地假设CUDA与图形能真正独立并行、每段耗时恒定、没有交接成本，单缓冲稳态周期是C+G；两阶段流水线的稳态周期下界为max(C,G)，启动和收尾仍存在。第三个槽位不会把两阶段下界变成max(C,G)/2，它主要增加排队余量。实际上下文调度、共享执行单元、提交开销会破坏理想假设，必须实测。

## 槽位与Fence公式

代码buffer_bench.cpp以objects[s]和vertices[s]组成一份槽位；实例/动态VB同时受同一交接保护。ready仍仅由CUDA写，consumed仅由D3D队列写。批次序号基数sequence单调增加，不能在每批将Fence重置为0。

```cpp
slot = f % N;
value = sequence + f + 1;
wait = f >= N ? sequence + f - N + 1 : 0;
```

只有wait非零时向CUDA流提交consumed等待。然后记录CUDA起始事件、三个kernel、结束事件和ready signal；D3D队列等待ready，执行本帧命令列表，signal consumed=value。对应signal在跨API wait前已经入队。每批最后排空后，才复用同一组命令列表、查询索引和CUDA事件；初始化/验证资源不在热循环创建。

每槽逻辑320B实例+272B动态VB；两项committed分配各64KiB，因此1/2/3槽的共享底层分配为128/256/384KiB。不能只用592B×N来报告实际分配成本。静态glTF资源和离屏目标仍共用：目标只在同一DIRECT队列里顺序访问，不需要按CUDA槽位复制。

本课保留固定48份预录命令列表/allocator，测有限批次；不是窗口无限帧调度器。生产通常以有界帧资源环回收allocator，可能在CPU追上GPU时等待。数据槽位数、CPU在飞行帧数、交换链图像数是不同概念，不应绑成同一个数字。多缓冲也可能增加延迟，本课无Present，未测输入到显示延迟。

## 固定实验条件与负载含义

GPU RTX5070，驱动610.88，CUDA Toolkit13.3.33/sm_120；CPU Core Ultra7 265K，20核20逻辑处理器；Windows11 26200。VS2022/MSVC14.44、Release/O2、C++17/UTF-8，HLSL vs_5_1/ps_5_1 strict。具体硬件、命令、输入gltf/bin/shader/exe SHA256在results/e3。

每批48帧、1024×1024离屏，4个真实glTF实例，mesh0动态顶点。无交换链/无Present，VSync不适用，不能拿其吞吐当交互帧率。性能进程关闭Debug/GPU Validation；验证单独开启。

为可控改变瓶颈，在实际实例/顶点更新前增加16384个独立标量递推，在实际光栅PS增加固定次数递推。所有模拟输出都存储并由CPU检查，像素结果进入RT。额外标量递推不驱动顶点，不冒称真实角色模拟。每帧3个CUDA kernel依次为Simulate/Update/Deform，4个实际glTF draw。

| 档位标识 | 每标量CUDA子步 | 每覆盖像素PS迭代 |
|---|---:|---:|
| cuda-heavy | 4096 | 64 |
| graphics-heavy | 64 | 4096 |
| balanced（混合档） | 1024 | 1024 |

balanced只是混合参数名，不声称两边耗时相等。循环次数固定，不根据机器速度运行到某个墙钟时长。每进程2批预热+5批测量，三轮轮换1/2/3槽运行次序，总计9配置×15=135个实测批次。未锁频，记录min/max波动；无分析器计时与有分析器结构核对分开。

性能段不读回图像或动态顶点，只解析必要时间戳；最后另行绘制相同帧进行读回与图像hash检查。每帧时间戳Resolve仍有固定小开销，所有配置相同。验证模式24帧逐帧读回，224×256，PS附加迭代0，不与性能模式混作计时样本。

## 四种时间要分开解释

CPU steady_clock测提交循环、最终等待和整批wall；wall=本样本submit+final wait。CPU中间显式等待调用0，不表示CUDA/D3D提交函数从不在驱动里阻塞。各列分别取中位数，列中位数之和不一定等于wall中位数。

CUDA使用：

```cpp
cudaError_t cudaEventRecord(cudaEvent_t event, cudaStream_t stream);
cudaError_t cudaEventElapsedTime(float* ms, cudaEvent_t start, cudaEvent_t end);
```

event是创建时启用计时的事件，stream是生产者流；record排在GPU流内。起点在外部Fence等待之后，终点在三个kernel之后、ready信号之前。ElapsedTime输出毫秒，输入已经完成的起止事件。不把CPU调用cudaEventRecord的时间当GPU时间。事件间隔可能包含kernel之间的调度延迟，不能等同SM实际执行时间；本机多缓冲时此项增长就是反例。

D3D12时间戳接口：

```cpp
void EndQuery(ID3D12QueryHeap* pQueryHeap,
              D3D12_QUERY_TYPE Type, UINT Index);
void ResolveQueryData(ID3D12QueryHeap* pQueryHeap,
    D3D12_QUERY_TYPE Type, UINT StartIndex, UINT NumQueries,
    ID3D12Resource* pDestinationBuffer, UINT64 AlignedDestinationBufferOffset);
HRESULT GetTimestampFrequency(UINT64* pFrequency);
```

QueryHeap为TIMESTAMP类型、2×frames个索引；Type=TIMESTAMP，f帧写2f与2f+1。时间戳只用EndQuery，不使用BeginQuery。Resolve从StartIndex=2f取NumQueries=2个64位结果，写READBACK/COPY_DEST缓冲offset=2f×8（8B对齐）。GPU末尾Fence完成后才Map。frequency输出每秒tick数，dt_ms=1000×(end-begin)/frequency，不能拿原始tick当毫秒。

每帧起点在D3D queue wait之后的列表开头，终点在绘制/状态恢复之后、Resolve之前。d3d_sum是各帧区间总和；d3d_span是第一帧begin到最后帧end，包含中间队列等待/空隙，不等同活跃时间。CUDA事件和D3D timestamp没有天然共同零点，不能直接拿绝对值相减来证明重叠。

## 无分析器实测

下表均为48帧整批wall中位数，单位ms，15样本/配置：

| 工作量 | 单缓冲 | 双缓冲 | 三缓冲 |
|---|---:|---:|---:|
| CUDA较重 | 13.6182 | 7.2957 | 6.3200 |
| 图形较重 | 35.3764 | 31.7358 | 30.6746 |
| 混合档 | 18.2778 | 13.6977 | 12.3204 |

混合档细分中位数：

| 槽数 | CPU提交 | CPU末尾等待 | CUDA事件区间之和 | D3D时间戳区间之和 |
|---|---:|---:|---:|---:|
| 1 | 4.3256 | 14.2738 | 1.11411 | 5.90870 |
| 2 | 4.7452 | 8.7009 | 2.29238 | 6.04973 |
| 3 | 4.5838 | 7.7591 | 3.47136 | 6.10765 |

显然整批更快，并不要求每个区间都缩短。不能说“三缓冲让kernel快了三倍”，也不能用CUDA_sum+D3D_sum与wall之差直接推算重叠。

## NVTX + Nsight Systems统一时间线

采集命令使用trace=cuda,nvtx,dx12、dx12-gpu-workload=batch、禁用CPU sampling/context-switch；通过cudaProfilerStart/Stop只包围预热后的一个48帧混合批次。NVTX标注整批、48次frame enqueue和末尾CPU drain。NVTX是CPU注释区间，不是GPU执行区间；GPU对应记录来自CUPTI和DX12 workload表。

每个槽数的捕获范围都核对出144个kernel、48个D3D批次和50个NVTX区间；kernel名称严格按Simulate/Update/Deform重复。DX12 SQLite可能含捕获前的预热记录，分析器必须按NVTX测量范围过滤，不能取表的前48行。

逐帧验证C_f结束≤G_f开始，且f≥N时G_(f-N)结束≤C_f开始；全部通过。跨API交集直接由统一时钟区间求交得到：

| 槽数 | CUDA kernel区间总和 | D3D批次区间总和 | 两者交集 | 首操作至末操作 | 这些记录区间之外的空隙 |
|---|---:|---:|---:|---:|---:|
| 1 | .609468 | 6.028303 | 0 | 19.315398 | 12.677627 |
| 2 | .606427 | 6.095218 | 0 | 14.606127 | 7.904482 |
| 3 | .606492 | 6.204452 | 0 | 12.915582 | 6.104638 |

结论限于本次捕获：没有观察到CUDA kernel与D3D批次区间重叠；多缓冲的收益伴随工作间隙缩短，并非记录到同时执行。空隙不等于整张GPU空闲，可能有其他进程或未记录工作；不把调度现象硬归因于某个硬件单元。

保留工具警告：CPU调度信息缺失，以及NVTX/CUDA/OS runtime/DX12事件可能未全部采集。预期工作计数和依赖检查通过，使本例主工作序列有证据；这些警告仍限制对细小开销和完整系统行为的归因。按用户此前授权，不采Nsight Compute硬件计数器，分支/缓存/占用率等仍未验证。

## 内容正确性、失败路径与验收

1/2/3槽验证各检查14208实例/顶点字节、1375616像素、16384模拟值，0不匹配、Debug0，图像与模拟hash跨槽一致。三槽memcheck0错误/0泄漏。所有性能进程的末帧592字节、全部模拟值、图像有限性通过，末帧图像hash同工作量跨槽跨轮相同；profile输出也与perf相同。Fence日志逐批重放通过。E.1和E.2修改后的完整回归通过。

生命周期：GPU工作未结束时禁止事件、query、allocator和共享映射释放/复用；每批最终Fence以及CUDA同步检查完成后才复用。提交期间或最后审计提交失败在资源仍存活处退出进程，避免释放飞行资源；不假装实现引擎级设备丢失恢复。分析器查询SQLite采用只读URI，缺文件不会默默新建空数据库。

结果不等于“三缓冲永远最好”：这里额外128KiB从双到三缓冲带来有限批次吞吐收益；更大真实缓存、延迟目标、交换链节奏与生产负载可能改变选择。引擎常用GPU Scene/渲染图/帧资源环表达相同所有权约束，本课将它们显式展开并用合成负载控制实验。

## 复现与自测答案

仓库根目录依次运行：

```powershell
& learning/sandbox/d3d12/cuda-interop/verify_e3.ps1
& learning/sandbox/d3d12/cuda-interop/profile_e3.ps1
& learning/sandbox/d3d12/cuda-interop/analyze_e3.ps1
```

最后一条在课程build下建立独立Python环境，固定matplotlib3.10.7，不改系统Python包；版本清单随结果归档。Systems脚本使用本机2026.3.1安装路径。

1. 为什么三缓冲第f帧等f-3，而不是f-1？同槽上一次使用是f-3；等f-1会保留不必要串行约束。
2. 三缓冲必然并行吗？不，地址冲突减少只提供机会，本机捕获交集为0。
3. CUDA事件变长但wall变短矛盾吗？不，事件含调度间隔，整批还受交接空隙影响；应查统一时间线。

E.1–E.3按计划范围完成，未自动进入F或H。

资料：[D3D12 Queries](https://learn.microsoft.com/en-us/windows/win32/direct3d12/queries)、[GetTimestampFrequency](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12commandqueue-gettimestampfrequency)、[Nsight Systems User Guide](https://docs.nvidia.com/nsight-systems/UserGuide/index.html)。
