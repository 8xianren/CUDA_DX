# PT.10：降噪窗口、分段计时与整章验收

2026-10-21。本节完成PT.10既定范围，下一章按授权进入PT.9 CUDA BVH与执行架构。代码沿用[dxr-path-tracer](../../sandbox/path_tracing/dxr-path-tracer/README.md)，结果直接保存[results/pt10-final](../../sandbox/path_tracing/dxr-path-tracer/results/pt10-final/)。

## 1. 前节自测答案

一半样本命中n=(0,0,1)、另一半miss，平均法线特征为(0,0,0.5)。每个命中法线是单位向量，平均特征是像素统计量，再归一化会丢失覆盖/混合信息。

共享HANDLE只让D3D/CUDA访问同一底层存储，不能保证生产者已经完成。D3D资源barrier负责其访问状态和依赖，External Fence负责跨API的执行先后，二者都需要。

降噪结果是依赖邻域和模型的重建值，不是新增的独立路径样本。把它按原来的sample count写回历史，再与新路径平均，会改变估计器并混入重建偏差。当前物理history持续保存原始线性样本均值，降噪只写单独的output平面。

## 2. 从显示需求推出回接位置

前节的CUDA输出还需要回到窗口。约束为：像素着色器读取output之前，CUDA必须已经完成；最后Present之后才能安全退役窗口资源。故显示必须进入外部消费者回接列表，排在D3D queue.Wait(done)之后。

```text
D3D：DXR→累积→打包→COMMON→Signal(ready)
CUDA：Wait(ready)→OIDN→audit→Signal(done)
D3D：Wait(done)→COMMON到PIXEL_SHADER_RESOURCE
     全屏三角形读取output平面→Back Buffer
     复制实际Back Buffer作验收→恢复资源状态
     复制HDR/metadata作验收→Present→本地Fence
CPU：只在末尾等Fence，再读取验收数据
```

窗口输出的源地址是`sharedGPUAddress + 4*width*height*16`。pixel stride16、row stridewidth*16；shader从这个根SRV基址读取RGB。原始、仅颜色OIDN、带guides OIDN都写同一个output平面，因此显示不需要知道消费者内部实现。

`common/window_display.h:99`的record接口新增两个默认参数：sourceState（旧调用默认UAV，本次COMMON）和byteOffset（旧调用默认0，本次第四平面偏移）。它检查DWORD对齐与整个有效字节范围，进入PS SRV后Draw，结束恢复sourceState。旧R.13和PT.10原始history显示仍用同一个实现。没有CPU读回后再上传图像的显示捷径。

`path_final.cpp:91`中的show调用`PathInterop::Run`，提供recordDisplay回调与present回调。前者只录制命令，后者在回接列表Execute后调用Present。本地Fence排在Present之后；它同时覆盖CUDA消费、D3D显示和读回。

资源退役还有一个容易忽略的层次：GPU执行结束后，CPU侧已关闭的command list可能仍保留Back Buffer引用。为了让ResizeBuffers可以释放旧buffer，`path_interop.cpp:130`在Fence完成后Reset回接allocator/list，再关闭空列表。必须先等GPU结束再清引用，不能只靠“函数返回”判断资源可释放。

本次真实窗口10阶段：原始32spp、带guides、仅颜色、曝光+1、641×359、321×481、最小化恢复、相机改变、内部127×65、手动reset。前7阶段保持同一32spp/gen1 history逐位不变；后3阶段分别4spp/gen2、4/gen3、4/gen4。相机结果还与独立一次4spp Dispatch比较，拒绝旧32spp残留。实际Back Buffer逐RGB误差≤1、alpha全255。

![实际Back Buffer](../../sandbox/path_tracing/dxr-path-tracer/results/pt10-final/window-comparison.png)

## 3. GPU时间必须先定义区间

CPU调用Dispatch/Execute的时间只是命令提交时间。CUDA与D3D异步执行；Present还可能涉及垂直同步。要测GPU阶段，必须在GPU命令流中写timestamp。

设GPU tick频率为f ticks/s，两次写入的tick为t0、t1：

```text
seconds = (t1-t0)/f
milliseconds = 1000*(t1-t0)/f
```

不能假设tick单位是纳秒；也不能直接相减两个不同API/设备的绝对时钟。这里D3D阶段全部使用同一个DIRECT queue的timestamp，CUDA消费者只读取CUDA event自身提供的时差。

实现见`path_metrics.h:5`：

```cpp
HRESULT ID3D12Device::CreateQueryHeap(
    const D3D12_QUERY_HEAP_DESC* desc,
    REFIID riid, void** heap);

HRESULT ID3D12CommandQueue::GetTimestampFrequency(UINT64* frequency);

void ID3D12GraphicsCommandList::EndQuery(
    ID3D12QueryHeap* heap,D3D12_QUERY_TYPE type,UINT index);

void ID3D12GraphicsCommandList::ResolveQueryData(
    ID3D12QueryHeap* heap,D3D12_QUERY_TYPE type,
    UINT startIndex,UINT numQueries,
    ID3D12Resource* destination,UINT64 destinationOffset);
```

CreateQueryHeap的desc指定TIMESTAMP、Count6、单节点默认NodeMask；riid请求ID3D12QueryHeap。GetTimestampFrequency写回当前队列的Hz。TIMESTAMP使用EndQuery直接写一个槽，不配BeginQuery。EndQuery的index在0..5范围；Resolve的startIndex0、numQueries6，将6个UINT64复制到READBACK buffer的offset0（满足8B对齐），目标处于COPY_DEST。

六个槽的语义：

|槽|位置|相邻差的含义|
|---|---|---|
|0|本组PathHistory::Record前|—|
|1|Run开始、Pack前|0→1：DXR＋GPU累积与相应barrier|
|2|Pack结束并恢复COMMON后|1→2：打包及状态转换|
|3|queue.Wait(done)后、显示前|2→3：外部交接区间|
|4|显示回调结束|3→4：显示＋Back Buffer诊断复制；无窗口时只是空槽间隔|
|5|packet/history读回复制后|4→5：HDR诊断读回|

Resolve录在槽5之后，本地Fence覆盖它。CPU只在Fence完成后Map48B读取ticks；下一帧复用槽和readback也必须等此Fence。槽0必须在Record前写；本组到Run前不能再独立Flush，否则区间会包含CPU空闲。旧调用不显式BeginFrame时，Run把0与1都写在打包前，不把之前已经提交的路径工作冒充本次计时。

CUDA event区间位于wait(ready)之后，包围消费者+audit。它被包含在D3D的2→3外部交接区间中。因此不能做：

```text
render + pack + handoff + CUDA + readback   // 错：重复计入CUDA
```

我们的queue interval是五个相邻D3D差值之和，不另外加CUDA。它包含跨API调度与提交空隙，不等于纯kernel busy time；也不含槽5之后的Resolve开销和Present。CPU wall包括录制、提交、等待和读回映射/向量复制，用来展示同步验收路径开销，不能拿它当生产引擎多帧吞吐。

微软说明：[Timing](https://learn.microsoft.com/en-us/windows/win32/direct3d12/timing)。

## 4. 测量条件和实测时间

验证进程默认开启Debug Layer与GPU-Based Validation。性能进程显式`UploadContext(false)`，关闭二者，输出`debug_disabled_performance_mode`，不能把这种运行记为“Debug0通过”。两个进程使用同一场景、shader、积分器、布局和同步代码。

性能输入：固定gallery，192×96及384×192，K8、RR开启、32spp。每种分辨率/消费者预热3次，计时9次；每次重置到相同seed0/32样本，确保消费者不会改变路径数。场景导入、AS初始化、OIDN创建/commit不计入稳态阶段。没有窗口/Present，仍保留真实共享回接和读回。raw模式表示无OIDN，但仍有共享packet、CUDA透传/audit，不能理解为完全移除互操作的渲染器。

本次中位数（ms）：

|内部尺寸|消费者|DXR＋累积|CUDA消费者＋audit|D3D交接区间|完整queue interval|CPU wall|
|---|---|---:|---:|---:|---:|---:|
|192×96|raw|1.432736|0.006976|0.349664|1.895168|3.9850|
|192×96|仅颜色|1.435808|0.616896|0.875296|2.424128|4.4120|
|192×96|guides|1.440768|0.580256|0.875264|2.418560|4.5102|
|384×192|raw|4.741216|0.008160|0.211552|5.428864|11.3469|
|384×192|仅颜色|4.792832|0.771456|1.012288|6.298336|12.1765|
|384×192|guides|4.780352|0.777504|1.057920|6.303360|12.3014|

384×192 guides的pack中位数.020256ms、HDR readback .430848ms。窗口验证阶段的显示+Back Buffer复制约.0285–.0485ms，但它开启验证层、窗口尺寸也不同，不能和离屏性能进程混成统一性能结论。

完整54条测量及min/max在timings.csv/summary.json。queue interval先逐次求和再取中位数，不把各列中位数相加。9次只是本机可重复小基准；192×96 CUDA区间存在明显波动，不将小差异解释为某种输入必然更快，也不据此推算1080p/4K帧率。

相同32spp，所有消费者射线数完全一致：192×96为1,758,453；384×192为7,025,410。这里统计TraceRay次数，含主射线、反弹和阴影射线，不是“像素数×SPP”那么简单。对应1024spp参考分别56,208,525与224,828,065条射线。

## 5. 显存口径

精确可算的三个图像缓冲：batch112B/像素、history128B/像素、packet96B/像素，合计336B/像素。384×192时为23.625MiB，其中packet6.75MiB。另有packet/history诊断readback逻辑15.75MiB，属于CPU可读资源，不能不区分位置就加成显存。

这还不包括VB/IB、纹理、BLAS/TLAS、SBT、描述符、驱动上下文、OIDN模型及工作区。OIDN/CUDA映射同一个packet不会因此让底层packet变成两份。

`path_metrics.h:26`查询同LUID适配器的进程用量：

```cpp
HRESULT IDXGIAdapter3::QueryVideoMemoryInfo(
    UINT nodeIndex,DXGI_MEMORY_SEGMENT_GROUP group,
    DXGI_QUERY_VIDEO_MEMORY_INFO* info);
```

nodeIndex0；group分别LOCAL和NON_LOCAL；输出结构包含Budget、CurrentUsage、AvailableForReservation、CurrentReservation。本节记录CurrentUsage与Budget，不申请reservation。LOCAL是独显本地显存，NON_LOCAL是另一内存段的用量；Budget是OS动态分配给进程的目标预算，不是显卡物理容量。[微软结构说明](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_4/ns-dxgi1_4-dxgi_query_video_memory_info)。

本次已预热的进程LOCAL观测：

|尺寸|raw|仅颜色|guides|
|---|---:|---:|---:|
|192×96|261.895MiB|271.895MiB|271.895MiB|
|384×192|284.645MiB|308.645MiB|310.645MiB|

同一进程按顺序测试，CUDA/驱动可能保留缓存；这些是采样时的进程用量，不是峰值，也不是通过差值精确测出的OIDN独占工作区。质量阶段同时保留两种filter，384×192观测约332.645MiB。本次LOCAL Budget=11175MiB。

## 6. 从误差定义推导质量实验

我们要比较的是固定像素目标L，而不是PNG码值。线性RGB MSE为：

```text
MSE = Σpixel,channel (I - R)^2 / (3*width*height)
```

R是相同分辨率、独立seed73、1024spp参考；I分别为原始、仅颜色OIDN和带guides OIDN。输入seed为0/19/41，样本数4/16/64/256。共有24组物理输入，每组比较三个输出，所有显示图最后才统一曝光/Reinhard/sRGB。

如果X、R是独立的同目标估计，则：

```text
E[(X-R)^2] = Var(X) + Var(R) + (E[X]-E[R])^2
```

即使X对当前有限深度模型无偏，有限参考的Var(R)仍然存在。不能把1024spp图称为精确真值，更不能用同一批输入样本拼进参考后假装独立。有限K、材质近似和数值近似造成的共同偏差，也不能靠同模型高spp参考检出。

对降噪器D，输出D(X)改变估计器。它可降低方差，但也可引入偏差；增加SPP后，原始X的随机误差下降，重建对真实细节的改变可能成为较重要的误差。不能把D(X)重新放回原始累积。三个种子的min/max带展示有限观测变化，不是统计置信区间。

三种子平均全图MSE：

|尺寸|spp|原始|仅颜色OIDN|guides OIDN|
|---|---:|---:|---:|---:|
|192×96|4|.08019590|.04591917|.09528686|
|192×96|16|.02025082|.02054256|.03112870|
|192×96|64|.00526394|.00915646|.00831568|
|192×96|256|.00153336|.00438301|.00298332|
|384×192|4|.07016961|.02942746|.02582719|
|384×192|16|.01736830|.01088064|.01216308|
|384×192|64|.00458612|.00505556|.00523460|
|384×192|256|.00137442|.00281667|.00266407|

原始图在两种分辨率都随样本数增加明显收敛。384×192低SPP时OIDN改善全图误差，较高SPP时原始结果更准确；低分辨率guides在本场景的亮区表现较差。不同分辨率的像素积分域不同，因此各自配各自参考，不把两个绝对MSE直接当作同一目标的比较。没有声称所有场景的最优切换阈值，也没有做等时间质量排名。

![质量曲线](../../sandbox/path_tracing/dxr-path-tracer/results/pt10-final/quality-curves.png)

![固定seed0/16spp对比](../../sandbox/path_tracing/dxr-path-tracer/results/pt10-final/quality-images.png)

图像已目视检查；两种OIDN明显减噪，但小亮边界和玻璃/反射细节仍有重建差异。前课关于首命中guide的近似边界继续成立。

## 7. 硬件、运行与整章验收

本次实查：RTX5070、nvidia-smi报告12227MiB；驱动610.88，CUDA UMD13.3；Toolkit13.3.33；Core Ultra7 265K、20核20逻辑处理器。驱动是本次查询值，已更新learning/README.md中旧591.86记录。shader使用DXC，CUDA kernel显式sm_120，CMake使用VS2022。

从仓库根目录运行全套：

```powershell
.\learning\sandbox\path_tracing\dxr-path-tracer\verify_final.ps1
```

脚本构建、编译DXIL、跑10阶段窗口验证、memcheck含leak-check、独立性能/质量进程、分析、旧PT10显示/互操作/history回归以及R13 window/resize回归。输出直接归results/pt10-final各子目录；R13回归脚本新增OutputDirectory参数，默认保持旧课命令兼容。

主动启动交互查看器：

```powershell
.\learning\sandbox\path_tracing\dxr-path-tracer\view_final.ps1
```

N循环原始/仅颜色/guides，+/-曝光，WASD平移相机，R重置，Esc退出。内部384×192，每轮增加1spp；最小化暂停。使用与自动验收相同的显示/重置入口，但没有自动模拟键盘，也不把输入手感称为已验收。仍是同步参考查看器，不是完整鼠标自由相机或多帧生产调度器，后者属于既定后续范围。

|PT.10要求|当前证据|
|---|---|
|持久线性HDR、计数/随机样本序列|path_history与前节2+5+6对13样本参考|
|相机/尺寸/材质/场景变化重置|history-regression全部通过，包含真实TLAS/材质更改和NaN旧历史|
|曝光、Tone Mapping、一次sRGB|旧显示16阶段逐码验收；本节output平面直接显示10阶段|
|albedo/normal/depth语义|前节CPU64×13主射线参考与共享packet审计|
|可替换成熟降噪器|PathConsumer/OIDN2.5.0 CUDA，raw/color/guides真实对照|
|静止随SPP收敛|两分辨率、3输入种子、4/16/64/256，独立1024参考|
|移动/Resize不残留|本节10阶段，camera对独立fresh Dispatch，尺寸重建；history回归|
|外部Fence/资源状态/生命周期|Run队列时间线、COMMON↔PS SRV、末尾Fence清命令引用|
|Debug与sanitizer|窗口Debug/GBV0，Fence13/13；memcheck0 errors、0 bytes leaked|
|误差/GPU时间/射线/显存/环境|summary.json、timings.csv、quality.csv、memory.csv、硬件文件及本讲义|
|共享代码兼容|旧窗口16帧Fence20/20；interop quick Fence10/10；history Fence33/33；R13 window96帧Fence97/97、resize64帧Fence65/65，全部Debug0|

PT.10核心范围完成。保留有限K、固定偏移、几何法线、无吸收/非嵌套教学玻璃、mip0及既有导入范围；没有时域降噪、运动重投影、生产异步资源池、设备恢复、完整角色动画或自由鼠标相机。本章没有把这些后续内容改写成已完成。

## 8. 接续PT.9

下一章保留当前DXR Path Tracer，另建CUDA求交/执行架构对照，从暴力遍历参考、AABB与BVH开始，再到Megakernel/Wavefront和Nsight，不把换求交后端当成新的光传输理论。

下次直接回答：为什么总时间不能再加一次CUDA事件时间？为什么23.625MiB图像缓冲不等于进程总显存？为什么降噪在4spp更好，却可能在256spp更差？随后进入PT.9，不等待用户“继续”。
