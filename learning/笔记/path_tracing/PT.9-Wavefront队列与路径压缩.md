# PT.9 Wavefront队列与路径压缩

2026-10-21。代码与命令：[cuda-path-tracer](../../sandbox/path_tracing/cuda-path-tracer/README.md)。本节完成Wavefront正确性与初步计时，Nsight归因和并行粒度控制仍待下一节；PT.9尚未完成。

## 1. 上节答案

RR终止只影响后续反弹，当前顶点已经生成的ShadowTask应照常完成，否则直接光也被随机删掉。队列压缩改变槽位，不改变像素/样本身份；必须保留pixel/sample/depth才能生成相同随机样本。活跃路径少不等于硬件效率同比例提高，warp分歧、不同路径长度、寄存器/local、访存、调度和启动成本都影响耗时。

## 2. 要解决的问题与等价约束

把一个线程的长路径循环拆成批量阶段，类似引擎任务系统把“先做所有碰撞查询，再做相关求解”组织成工作列表。必须保持原渲染方程、样本、每路径发光/NEE/BSDF/RR顺序以及最终样本求和顺序。阶段拆分允许把大量相同类型工作放在一起，但要付出队列存储/搬运、压缩和更多kernel启动。

初始路径数N=W×H×SPP。固定身份stateId=pixel×SPP+localSample；pixel=stateId/SPP，sample=sampleOffset+stateId%SPP。路径状态始终存在states[stateId]，队列只存ID。槽位是当前调度位置，不参与随机数。

流程：Generate→[Intersect→Shade/压缩→Shadow]重复K+1层→Resolve。Intersect的输出hits[slot]与当前rayQueue[slot]对应；miss用Invalid ID表达，仍由Shade消费并终止。下一层读另一条射线队列，第一条可被重写，形成ping-pong双缓冲。

## 3. 从谓词到压缩地址

设输入有效标记f=[1,0,1,1,0,1]。稳定压缩可以计算exclusive prefix sum：P_i=Σ_{j<i}f_j，得到[0,1,1,2,3,3]。每个f_i=1的元素写到out[P_i]，输出为原ID[0,2,3,5]，计数4。scan方法保留输入顺序。

本节使用原子预留，允许不同线程组之间改变顺序。最简单是slot=atomicAdd(counter,1)，每个有效项得到唯一旧值，因此不会写同一槽位。为了降低同一计数器竞争，当前一起参与的warp线程先汇总有效位，再一次预留连续区间。

`wavefront.cuh:11`：participating=__activemask()；chosen=__ballot_sync(participating,selected)。chosen第j位为1表示lane j需要输出，m=__popc(chosen)。leader=__ffs(chosen)-1选最低有效lane；leader执行base=atomicAdd(counter,m)，广播base。每个selected线程的局部rank=popc(chosen & ((1u<<lane)-1))，写slot=base+rank。若chosen=0，整组不预留。

例如lane0/2/3有效、旧counter=10，则一次预留3项后counter=13，三者分别写10/11/12。其他warp可能先预留，也可能后预留，因此队列总体顺序不确定。此处只要求集合正确，不要求跨warp稳定排序。独立线程调度可能让同一个warp分多组参与，正确性不依赖每warp恰好一次原子。

|API/内建函数|参数、返回值与约束|
|---|---|
|`unsigned __activemask()`|当前参与执行线程的32bit位掩码，不假定尾warp有32条有效输入|
|`unsigned __ballot_sync(unsigned mask,int predicate)`|mask中参与线程同步投票，返回predicate为真的lane位集合；参与者须按相应mask执行同一调用|
|`int __popc(unsigned x)`|x中1的数量，用于组大小和局部rank|
|`int __ffs(int x)`|最低1位的1-based位置；x=0返回0，因此先处理空chosen|
|`T __shfl_sync(unsigned mask,T value,int srcLane,int width=32)`|参与线程从srcLane读取寄存器值；本节广播leader的base，mask包含全部participating线程|
|`unsigned atomicAdd(unsigned* address,unsigned value)`|原子读改写计数，返回修改前旧值；本节只对uint队列计数/错误计数使用|

算法与[NVIDIA warp聚合原子说明](https://developer.nvidia.com/blog/cuda-pro-tip-optimized-filtering-warp-aggregated-atomics/)一致；编译器也可能自动聚合某些简单原子，不宣称手写形式普遍更快。

## 4. 两个输出谓词与容量证明

一次Shade最多产生一个继续路径和一个阴影任务。分别使用path.alive和shadow.valid压缩，不能用前者过滤后者。RR终止后alive=false但shadow.valid仍可能true。两条队列各自capacity=N即可容纳最坏情况，不能把两种任务塞进共享容量N却不重新证明界限。

同一深度，每个输入stateId恰好出现一次；每个输出谓词最多写该ID一次，所以后续同类阶段每个ID仍只有一个写者。WaveShadow写对应state.radiance时，不与WaveShade并发；同一个ID没有两条阴影任务。RGB不需要atomicAdd。

实际写之前检查slot<capacity，越界则增加错误计数。正常算法有容量证明，运行检查仍用于捕捉程序缺陷。独立压缩测试故意让129个有效项写容量1，只允许第一个成功，其余报告128次错误，memcheck不出现越界。

## 5. 存储布局、所有权与代价

|分配|每初始样本字节|访问方式|
|---|---:|---|
|PathState<float>|88|按稳定stateId读写，ray/beta/L/previous PDF等字段属于同一结构体|
|PathStats|92|每样本诊断，独占写；最后按像素归并|
|PathHit<float>|16|Intersect按当前slot写、Shade按相同slot读|
|ShadowTask<float>|48|按stateId存储射线和冻结的NEE贡献|
|两条射线索引队列|8|两个uint32数组交替读写|
|阴影索引队列|4|有效shadow的stateId|
|合计|256|另有全局144B计数结构|

总工作区256N+144B，不含104B/像素最终输出、场景几何/BVH和驱动开销。gallery N=589824，工作区150995088B≈144.000137MiB；盒室N=1769472，452984976B≈432.000137MiB。容量上限4,194,304路径，乘法先用uint64检查，在分配前拒绝超限。

这是按职责分数组、数组内元素AoS布局；没有做state各字段独立数组的SoA。只移动4B ID节省压缩搬运，但后续读取states[id]可能分散，不能将“队列连续”直接等同于“所有状态读取都合并访问”。

WaveStorage拥有全部cudaMalloc分配；WaveView只借用device地址，不拥有资源。所有阶段和最终读回完成后才释放。CPU场景上传完成仍由DeviceScene初始化同步保证。

## 6. 原子计数增加不代表元素已经发布完成

预留时先atomicAdd，随后才写队列元素。若另一个并发消费者只观察counter，就可能看见数量增加却读到尚未写好的元素。原子计数不是完整的生产者/消费者发布协议。

本实现用kernel边界与同一stream排序解决：Shade完整结束后才执行Shadow和下一层Intersect。所有计数与队列写入在后续kernel读取前完成，不需要CPU在每层等待，也不需要让消费者忙等。

新调用：`cudaError_t cudaMemsetAsync(void* devPtr,int value,size_t count,cudaStream_t stream=0)`。devPtr是WaveCounts地址，value=0按字节填充，count=144字节，stream与Generate/Intersect等相同。清零→Generate写初始N→各阶段顺序执行。CPU预先提交所有K+1层，不在中间DtoH读回计数。

`WaveIntersect(PathView,WaveView,unsigned depth)`读rays[depth]，写hits；`WaveShade(PathView,RenderConfig,WaveView,unsigned depth)`读hits并写rays[depth+1]/shadows[depth]；`WaveShadow(PathView,WaveView,unsigned depth)`消费阴影队列并加L；`WaveResolve(WaveView,RenderConfig,PixelResult*)`按原sample顺序求和。参数View按值传递地址/数量，depth为当前层，不含CPU容器。

默认128线程/block，动态shared=0。当前三种逐层kernel始终使用ceil(N/threads)网格，在入口以slot>=deviceCount退出。因此队列数据已经压紧，但启动网格没有缩小，空队列仍有启动成本。Resolve只启动像素数对应网格。显式应用kernel数2+3(K+1)，不含异步清零的底层实现和event。

![有效队列与容量](../../sandbox/path_tracing/cuda-path-tracer/results/wavefront/queue-capacity.png)

## 7. 确定性归并与共享基线修正

Wavefront同时执行多个样本，每样本分别存L和诊断。Resolve由一个线程负责一个像素，严格按sample=0..SPP-1累加，再除SPP，所以顺序与像素Megakernel相同；不使用不确定顺序的浮点atomicAdd。

诊断哈希也改为先形成每样本摘要，再按sample顺序合并。Megakernel继续直接累计原计数，只额外保留一个32bit合并哈希，避免额外复制92B诊断结构。积分和随机样本没有改变；旧path_verify完整重编译/运行，解析RR、五种CPU参考、block/分批和大图全部通过，日志在megakernel-regression。

当前kernel属性：Megakernel86寄存器/624B local；Generate32/0；Intersect48/512；Shade98/0；Shadow48/512；Resolve60/0；静态shared均0。这说明不同阶段资源需求不同，但不能直接由寄存器数推断实际占用率或性能瓶颈。

## 8. 本机验收与初测

20组压缩集合：输入1/31/32/33/129，各自零/全/交替/稀疏选择；下载后排序与CPU集合严格相同，无重复/遗漏。容量1的129输入负对照按预期保护。

11种完整渲染配置包括K0/K1/K4 MIS/RR/BSDF-only五组31×17×8，以及单路径K16、奇数尺寸/3spp/offset19/seed29、空场景、解析发光、两张大图。所有Wavefront/Mega线性RGB逐值完全一致，路径摘要/计数一致；CPU double小图最大归一化差3.65607e-7，未排除像素。反转初始队列和block64/128/256全部RGB逐值一致。4+4对8样本差7.87501e-8。

每层rayCounts与逐样本active[depth]相等，shadowCounts总和与每样本阴影计数相等，下一队列不大于当前输入，K+1队列为零。quick memcheck0错误/0泄漏，synccheck0错误；后者检查本节warp同步使用，不能独自证明所有全局内存算法无竞争，唯一写者与stream顺序仍需逻辑保证。

|场景|Mega ms|Wave ms|Wave显式launch|
|---|---:|---:|---:|
|31×17×8，K4 RR|1.15235|.284000|17|
|单路径，K16|.071328|.564064|53|
|空场景105样本，K4|.009984|.134496|17|
|盒室144×96×128，K8|27.1517|16.2844|29|
|gallery192×96×32，K6|41.0164|9.88819|23|

以上为RTX5070/sm_120本轮1预热+3测量中位。Wave区间包含清零、生成、全部阶段和归并，排除分配/上传/读回；插桩时间独立保存，不混入表格。大图CPU误差-1表示未测，不能用它声称CPU逐路径一致。

关键混杂因素：像素Megakernel在线程内串行SPP，Wavefront并行所有N样本。因此本表是这两份具体实现的结果，不能证明所有加速来自拆kernel；诊断字段也有执行/内存开销。下一节增加“一线程一样本的Megakernel”对照，控制并行粒度，再用Nsight核对分支、队列访存、活跃线程和launch时间线。固定容量网格/空队列的成本也需测量后再决定是否改变调度，不预设Wavefront总是更快。

![两后端同图](../../sandbox/path_tracing/cuda-path-tracer/results/wavefront/backend-images.png)

## 9. 继续课程

运行入口`verify_wavefront.ps1`，可视化`analyze_wavefront.py`，全部结果在results/wavefront，详细参数/依赖见README。[PBRT Wavefront实现](https://www.pbr-book.org/4ed/Wavefront_Rendering_on_GPUs/Path_Tracer_Implementation)提供生产级多材质/介质等更复杂队列的参考，本课仍是Lambert、固定K/epsilon、静态几何和黑环境。

下节先答：①atomicAdd返回槽位后，为什么不能让并发消费者只看counter就读取？②为什么同一深度的继续路径队列和阴影队列需要两个独立谓词？③Wavefront初测更快，为什么还需要样本级Megakernel控制组？随后进入Nsight与PT.9收束，不等待用户继续。
