# PT.9 从最近命中到 CUDA BVH

2026-10-21。代码与运行入口：[cuda-path-tracer](../../sandbox/path_tracing/cuda-path-tracer/README.md)。本节只完成求交加速；PT.9整章仍进行中。后续顺序是 CUDA 积分与 CPU 图像参考、Megakernel/Wavefront、Nsight，之后自动进入PT.11/PT.12。

## 1. 上节三题答案

CUDA事件测到的工作位于D3D队列等待外部消费者的时间段内，不能再加到包含该等待的整段GPU时间上，否则重复计时。23.625MiB是384×192图像批次/历史/共享包的逻辑大小，不包含几何、加速结构、纹理、OIDN、驱动分配，也不是进程峰值显存。低SPP时降噪减少噪声的收益可能盖过偏差；高SPP原始估计方差已经降低，滤波造成的偏差/细节损失可能主导总误差，所以不是所有SPP都更好。

## 2. 先定义问题，不先选树

射线 r(t)=o+t d；三角形内部点 p(u,v)=a+u(b-a)+v(c-a)。约束为 u≥0、v≥0、u+v≤1、tmin≤t≤tmax。查询要找所有合法交点中最小的t，返回稳定三角形ID与重心坐标；没有交点返回Invalid。方向单位化时t等于沿射线的距离；一般方向只保证t是参数。

输入数组顺序不是距离顺序。负对照先放z=5再放z=2的三角形，射线从(.25,.25,0)沿+z，最近命中应为ID1/t2，遇到首个图元就返回会得到ID0/t5。阴影any-hit只关心给定区间内是否存在遮挡，可提前终止；当前closest查询不能照搬。

N个三角形、R条射线暴力查询需N×R次三角形测试。gallery有63496个三角形、8197条射线，共520476712次。BVH的目的，是证明某些图元不可能命中后整组排除；不修改BRDF/PDF/MIS，也不是降低SPP。

## 3. 三角形约束如何求解

令e1=b-a、e2=c-a、s=o-a，则 s+t d=u e1+v e2。记p=d×e2、D=e1·p。

两边点乘p：d·p=e2·p=0，因此u=s·p/D。再令q=s×e1；由原式叉乘e1得到q=t(e1×d)-v(e1×e2)。点乘d得到q·d=vD；点乘e2得到q·e2=tD，因此 v=d·q/D、t=e2·q/D。

D=0表示退化或精确平行，本节拒绝。D正负都允许，因此不做背面剔除。解出u/v/t以后再检查内部与有限区间约束。代码：`geometry.h:52`。精确相同float t选择较小原始ID，不使用宽容差把略远的交点当作相同距离。

这是Möller–Trumbore形式。本实现不是watertight求交器：后者强调相邻三角形共享边在浮点运算下也保持一致覆盖。接近退化、极端尺度和公共边的通用稳健求交，不由本节有限测试证明。

## 4. 为什么包围盒能排除三角形

AABB是轴对齐包围盒，三个坐标轴各有[min,max]约束。若一组三角形全部在盒内，射线完全不穿盒子，就不可能碰到其中三角形；穿盒只说明存在候选，不能当作实际几何命中。像游戏的碰撞宽阶段先用包围体排除，再用精确形状检查。

对轴i，要求 li≤oi+t di≤hi。di>0直接除；di<0除后不等号反向。因此非零方向给出near_i=min((li-oi)/di,(hi-oi)/di)、far_i=max(...)。所有轴与原射线区间必须同时成立：

```text
entry = max(tmin, near_x, near_y, near_z)
exit  = min(tmax, currentClosest, far_x, far_y, far_z)
可进入 ⇔ entry ≤ exit
```

slab指一对平行平面夹出的无限厚片；盒子是三片的交集。若di=±0，坐标恒等oi：oi在[li,hi]外则整条射线拒绝，否则该轴不增加t限制。明确处理避免面上0×∞变NaN。使用闭区间，切到边/角或恰好碰到tmax不应在宽阶段丢失。

手算：盒[-1,1]^3，o=(0,0,5)，d=(0,0,-1)。x/y满足平行包含；z给出4≤t≤6。若tmax=3则不相交，tmax=4则交集仅t=4，仍算进入。`geometry.h:40`与`bvh_verify.cu:19`对12组CPU/GPU解析结果严格核对。

叶盒先取三顶点坐标min/max，再按2e-6×(1+最大绝对坐标)外扩，父盒取子图元盒的并集。外扩会增加假阳性与工作量，但有助避免当前尺度的舍入误差造成漏候选；它不是任意输入上的数学保证。

## 5. 从一层分组到二叉树

每个三角形计算中心(a+b+c)/3。在当前集合选中心范围最长轴，按中心坐标取中位数，把图元个数分成两半；中心相同按原ID打破平局。≤4个图元停止成为叶子。内部节点存两子节点索引和全部后代的包围盒。代码：`bvh_build.h:16`。

必须区分“图元集合不重叠”与“包围盒不重叠”：本构建每个三角形恰好属于一个叶子，但不同叶子的盒子可以重叠。中位数确保每次减少图元数量和较浅树高，不能确保射线只走一边。

gallery实测32767节点/16384叶子，根深度0，最大深度14。100个完全重叠的三角形仍可建出深度5的平衡树，但对穿过公共盒子的射线，无法靠分组排除图元。本测试3条真命中加1条(.8,.8)穿盒却在三角形外的射线，各测试100个图元，总400次。平衡树不意味着每条查询O(log N)，最坏仍O(N)。

SAH（表面积启发式）估计一次分裂的遍历/求交代价，尝试用更合适的空间分组换取少访问节点；LBVH按空间编码便于并行构建。当前中位数基线用于把正确性与遍历机制讲清，后续性能段再用数据判断优化方向。参照[PBRT BVH](https://www.pbr-book.org/4ed/Primitives_and_Intersection_Acceleration/Bounding_Volume_Hierarchies)。

## 6. 数据排布和稳定身份

|数据|字节|布局和所有权|
|---|---:|---|
|Triangle|64|a.xyz/instance、b.xyz/primitive、c.xyz/material各16B；最后16B为id和padding|
|Node|32|lower.xyz/first各前16B，upper.xyz/second后16B|
|order元素|4|叶子范围内存原Triangle下标；只重排它，不改变Triangle身份|
|Ray|32|origin.xyz/tmin、direction.xyz/tmax|
|Hit|16|t/u/v/id|
|Result|32|Hit，加boxes/triangles/stackMax/error四个uint|

内部节点first/second是左右索引；叶子second高位LeafBit=0x80000000，低位为count，first是order起点。叶子读取triangles[order[first+j]]。数量限制保证索引不使用标志位。没有CPU指针上传给GPU。

CPU vector拥有构建存储，DeviceBuffer拥有cudaMalloc分配；复制到GPU后是独立存储。GPU遍历时nodes/order/triangles/rays只读，一线程写一个result。节点1,048,544B，order253,984B，三角形4,063,744B；不把这些部分相加当成进程总显存。

导出器复用CpuScene与世界变换，静态实例展开成世界三角形，因而牺牲实例几何共享；与DXR BLAS共享局部几何/TLAS实例有差别。本课要显式控制CUDA求交结构，并非重现驱动的BLAS布局，也未调用RT Core求交。当前材质只保存基础/发光因子，不宣称移植了纹理/GGX/玻璃。

## 7. near-first遍历怎样保证最近命中

`geometry.h:68`使用每射线独立LIFO栈，元素{nodeIndex,entry}共8B。先测试根盒；弹节点时，若entry>当前最近t即可剪枝；叶子求交更新最近t；内部节点测试两个子盒，先压远者再压近者，让近者先弹出。

这里“近”是盒子入口近，不保证盒内实际三角形近。例如A盒entry=1、真实交点t=8；B盒entry=2、真实交点t=3。先处理A后得到8，还必须处理B。只有B的entry>8才能排除。由于平局按较小ID选择，entry==当前t也要保留，因此比较是>而非≥。

最大树深度小于64，深度优先二叉遍历的待处理栈最多深度+1；仍保留运行时容量检查，溢出返回error=5，不能冒充miss。CPU还检查所有节点可达/无环/不重复、父盒含子盒、叶子包含顶点、图元恰好一次。四类坏输入在送GPU前拒绝。

64×8=512B每线程栈。本机cudaFuncGetAttributes报告48寄存器、512B local、0B静态shared。local是线程私有访问空间，不是shared，也不保证在寄存器；本次确实有local分配。但512B是容量，不代表每条射线都读写512B，也不足以直接推断访存瓶颈/占用率。Nsight留到执行架构比较时。

## 8. CUDA API、提交顺序和失败路径

```cpp
cudaError_t cudaMalloc(void** devPtr, size_t size);
cudaError_t cudaMemcpy(void* dst, const void* src, size_t count, cudaMemcpyKind kind);
cudaError_t cudaDeviceSynchronize(void);
cudaError_t cudaStreamCreateWithFlags(cudaStream_t* stream, unsigned int flags);
cudaError_t cudaStreamSynchronize(cudaStream_t stream);
cudaError_t cudaEventCreate(cudaEvent_t* event);
cudaError_t cudaEventRecord(cudaEvent_t event, cudaStream_t stream = 0);
cudaError_t cudaEventSynchronize(cudaEvent_t event);
cudaError_t cudaEventElapsedTime(float* ms, cudaEvent_t start, cudaEvent_t end);
cudaError_t cudaGetLastError(void);
cudaError_t cudaFree(void* devPtr);
```

devPtr是接收device地址的CPU变量地址，size/count都按字节；Memcpy的dst/src是对应地址、kind明确HtoD或DtoH。StreamCreate输出句柄，cudaStreamNonBlocking不与传统默认流建立隐式排序。普通vector是pageable主机内存；同步Memcpy HtoD返回时可能仅完成到暂存内存的搬运，不能假设nonblocking stream已经可读。初始化后显式DeviceSynchronize，再开始warmup/计时。[官方同步语义](https://docs.nvidia.com/cuda/cuda-runtime-api/api-sync-behavior.html)。

每个模式先warmup一次并StreamSynchronize；三个正式轮次各在同一stream记录begin event→launch→end event，EventSynchronize(end)后读取毫秒差，取中位数。EventCreate默认可计时；ElapsedTime的输出ms是float，start/end指定区间。结束同步后才DtoH读取结果；DtoH返回后CPU才验收。上传、CPU构建、读回均不在kernel时间内。

`TraceKernel<true><<<groups,128,0,stream>>>(triangles,triangleCount,nodes,nodeCount,order,rays,rayCount,output)`中groups=(R+127)/128，128线程/block，0为动态shared字节，stream规定提交队列。输入参数分别是三角形数组/数量、节点数组/数量、索引数组、射线数组/数量、结果数组；线程i≥R立刻返回，8197不是128倍数正好覆盖尾部检查。

launch异步返回，用GetLastError查启动配置等错误；EventSynchronize/StreamSynchronize/DeviceSynchronize检查异步执行失败。所有被调用API的错误转为带操作名异常，main输出错误并返回1；正常路径完成GPU后才由RAII释放device/stream/event。析构不抛异常，不把当前简单退出写成设备错误恢复方案。无跨线程通信，所以无需原子操作或__syncthreads。

## 9. 验证方法和本机结果

RTX5070/sm_120，Toolkit13.3.33。完整8197条射线含相机、外部朝场景、内部随机方向、轴向有限线段四类，固定种子20261021。GPU暴力和BVH比较全部ID与距离；独立double参考先与平面求交，再解Gram矩阵重心坐标，避免仅把同一浮点函数搬到CPU称作独立验证。

Gram方程：令q=o+td-a，A=e1·e1、B=e1·e2、C=e2·e2，满足A u+B v=e1·q、B u+C v=e2·q；分母AC-B²。代码`bvh_reference.h:13`。512条审计ID全部一致，最大距离归一化差|tGPU-tCPU|/(1+|tCPU|)=3.12310049e-7，重心差2.74567392e-5。

解析测试另含单三角形、空树、退化、.001/1000比例、100重叠、首命中错误。gallery命中4182条、BVH三角形测试56725次、盒测试446771次、最大实际栈12；暴力三角形测试520476712次。平均每条6.9202次三角形测试与54.5042次盒测试。三角形测试减少约9175倍不等于耗时减少同样倍数，因为BVH新增盒求交/栈/散乱访存/分支。

同步修正后复测：暴力29.054464ms，BVH .169120ms，约171.80倍；CPU建树437.232ms。权威逐次GPU时间在[完整CSV](../../sandbox/path_tracing/cuda-path-tracer/results/bvh/bvh.csv)和[运行日志](../../sandbox/path_tracing/cuda-path-tracer/results/bvh/run.txt)；只是一次初始化后1预热/3测量的教学诊断，不作稳健跨机器性能结论。CPU建树沿用未额外开启MSVC优化的宿主构建，建树耗时也只记录，不评价生产构建器性能。

quick模式129条射线/64条CPU审计通过Compute Sanitizer memcheck，0错误/0字节泄漏，所有解析测试保留。插桩时间不与普通时间混用。不同模块的验证证据各有边界：一致性测试支持当前样本，不能证明通用浮点几何永不漏交；sanitizer也不能证明最近命中数学正确。

## 10. 动手与下一步

仓库根目录执行`learning/sandbox/path_tracing/cuda-path-tracer/verify_bvh.ps1`，脚本重建并把结果写到本课results/bvh；详细命令见目录README。可先手算单位盒t区间，再对照12组解析测试。

下节直接回答并继续：①为什么A盒入口比B近，仍不能在A命中后返回？②为什么树很平衡，100个重叠三角形仍可能全部测试？③为什么512B线程私有栈不能直接说成512B寄存器？然后把已验证的求交器接入CUDA路径状态和CPU图像参考。当前没有完整CUDA出图、Wavefront或Nsight报告，PT.9不勾选完成。
