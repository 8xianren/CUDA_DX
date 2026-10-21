# PT.10 GPU线性累积与历史重置

2026-10-21。本小节已实现并在RTX5070验收；PT.10整章仍在进行中，窗口显示、降噪/互操作与完整性能报告尚未完成。

[共享主线代码与运行入口](../../sandbox/path_tracing/dxr-path-tracer/README.md)；[上一节PT.8](PT.8-共享积分器与粗糙度场景验收.md)。

## 上节自测答案

1. delta命中灯的权重为1：连续面积采样不能以非零概率产生那一个精确的镜面/折射方向，没有第二个策略来重复估计该离散事件。连续PDF与离散质量不能直接放在同一个MIS分母。
2. K1玻璃发黑：K按散射次数计，进入玻璃之后，在背面达到截断；背面不是灯，路径也未被允许继续透射出去。K8有机会完整穿出并看到环境或被照亮的物体。不是玻璃吸收变黑。
3. MIS的MSE更低不证明GPU更快：相同SPP下它增加了阴影射线、灯光采样与BRDF计算。需要等时间或达到同等误差所需时间，才是在比较性能。

## 为什么累积必须保留在线性HDR空间

目标是估计每个像素的平均辐亮度。每个样本X包含整个路径积分贡献；已经应用BRDF/PDF、NEE/MIS和RR权重，不能在累积阶段再除一次这些概率。

游戏开发类比：静止相机的每一批路径都是对同一个像素光照的补充测量。GPU历史相当于持续更新测量平均值。相机移动之后，即使像素索引没变，它对应的观察射线也变了，旧测量不能无条件继续混入。

已有N个样本，均值为H_N；新批次n个样本，均值为B_n。把样本集合合并：

\[
H_{N+n}=\frac{NH_N+nB_n}{N+n}
=H_N+\frac n{N+n}(B_n-H_N).
\]

GPU使用最后一种形式。它避免保存会随样本数增长的颜色总和，但仍有float舍入；不宣称无限SPP精确。当前最大历史为1048576 spp，超过显式报错。计数使用uint32，不用浮点alpha保存。

批次不是统计样本单位。例如两批均值为1、3，分别有2、6个样本，正确结果是2.5，平均两张图得到2则错误。验收故意使用2+5+6不等长批次。

Tone Mapping一般非线性，所以T(E[X])不等于E[T(X)]。用Reinhard T(x)=x/(1+x)，两个样本0和4：先平均再映射得到2/3；先映射再平均得到0.4。因此历史保存未经曝光/色调映射/sRGB编码的线性HDR；显示在后续独立阶段执行。

radiance.w保存亮度Y的二阶原点矩E[Y²]，同样按样本数加权。它不是alpha，也不是E[Y]²。当前用它做误差统计辅助，不在本节实现数值更稳定的Welford方差合并；高SPP极小方差下直接做二阶矩减平方会受相消影响。

## 批次划分不能偷偷改变随机样本

旧PT.8每32spp换batch seed，适合固定验收；现在改为可选择连续样本编号。128B PathConfig原保留偏移104变为sampleOffset，旧调用默认0保持旧行为。

shader循环中：

```hlsl
uint sample = c.sampleOffset + localSample;
```

随机数仍由(pixel,sample,seed,depth,dimension)哈希生成。同一目标与seed下：一次计算样本0..12，与分批计算0..1、2..6、7..12，抽到相同的路径。这里只需保留整数游标，不需要每像素保存一个会被顺序更新的PRNG状态数组。

每一代历史从sampleOffset0开始，下一批从当前累计样本数开始。改变批大小不重置；改变seed会重置，以便可重复比较。seed变化本身不必改变物理积分目标，这属于本课明确选择的实验策略。

GPU批输出的几何特征取本批第一个主样本；累积器只保留本代首批的特征。把不同主样本的实例ID或法线直接平均，会在轮廓处混合不同物体；本节不把这些审计特征冒充完整降噪G-buffer。

## 历史有效性由什么决定

`path_history.h/.cpp`的MakeHistoryKey逐字段构造键：相机eye/forward/right/up、视角、宽高、环境颜色/强度、灯强度/分布面积、起点偏移、K、积分模式、RR设置、seed，以及场景和材质revision。

排除spp和sampleOffset：它们是工作量/进度，不是被估计的目标。曝光、显示变换不属于本课PathConfig，后续也不应加入线性积分历史键。当前管线固定，重新创建shader管线时会新建历史；未来热重载要把积分器版本纳入键。

revision是调用契约，不是自动检测任意内存变化。修改材质因子/纹理必须递增materialRevision；修改实例/几何/灯分布必须递增sceneRevision，并上传相应真实GPU资源。只递增revision而不改资源是空测试；只改资源而不递增revision会留下旧历史。测试同时做实际修改和递增。

键不同、初次使用或forceReset时，previousCount=0，generation递增。generation是历史代号，不是样本数。每个GPU像素都保存这两个uint，后续合并时检查它们与CPU计划一致，防止计数和资源意外串代。

## 为什么重置不能写old*0+new

历史资源新建后内容没有初始化。即使旧资源曾有效，它也可能含另一视角的内容，甚至NaN。

IEEE浮点中NaN*0仍为NaN。所以`lerp(old,new,1)`或`old*0+new`不能作为“不读取旧数据”的保证。本课在compute shader中明确分支：

```hlsl
if (previousCount == 0) {
    next.value = current;
    next.meta = uint4(batchCount, generation, 0, 0);
} else {
    next = history[index];
    float weight = float(batchCount) / float(previousCount + batchCount);
    next.value.radiance += (current.radiance - next.value.radiance) * weight;
    // 累加路径计数；首主样本特征不覆盖。
}
```

重置分支完全写入128B像素，不读取history[index]。验证把旧GPU历史的四个radiance分量填成NaN、错误计数和元数据填成999，再重置。结果与新历史一致，归一化差为0。

## 资源布局与职责

|资源|布局/所有者|使用方式|
|---|---|---|
|批次输出|PathPixel112B/像素；PathHistory持有DEFAULT buffer|DXR写UAV，compute读SRV，每批覆盖|
|持久历史|PathHistoryPixel128B/像素；PathHistory持有DEFAULT buffer|112B结果+uint4(count,generation,0,0)，compute读写UAV|
|配置|128B头+64B/灯；每批独立UPLOAD资源|GENERIC_READ，Record存进uploads，Fence后释放|
|累积常量|6个uint，24B|直接写根常量，随命令记录，不用独立cbuffer|
|读回|128B/像素的READBACK buffer|只在检查点创建，COPY_DEST，Fence完成后Map|

这里使用结构化buffer保存HDR，后续显示可以直接读取，或明确转换到纹理；HDR描述的是颜色范围/精度，不要求底层一定是Texture2D。128B包含大量教学诊断，并非生产最省显存布局。128×64时批输出917504B、历史1048576B，二者合计1966080B；这只是两项资源的逻辑字节数，不是整个进程显存占用。

累积shader用8×8线程组，每像素一个线程，只读写自己像素，无需原子操作。Dispatch组数为ceil(width/8)、ceil(height/8)，超出图像范围的线程先返回。95×49非整组尺寸验收通过。

`MaterialRayPipeline`提取自共享材质同步提交：构造时创建根签名、DXR State Object和SBT；Record只绑定并录制DispatchRays。旧DispatchMaterialBuffer调用同一实现，保持前课同步API。没有复制一套设备、BLAS或根签名。

共享`path_scene.h`包含相机、世界三角形、灯面积CDF、配置打包和教学IOR；PT.8离线入口与本节复用相同数据定义。

## API、资源状态与生命周期

新增接口：

```cpp
bool PathHistory::Record(
    const MaterialBindings&, const GpuScene&, const InstanceFrame&,
    PathConfig, const std::vector<PathLight>&,
    uint64_t sceneRevision, uint64_t materialRevision,
    bool forceReset = false);
void PathHistory::Flush();
std::vector<PathHistoryPixel> PathHistory::Readback();
```

Record借用场景/材质/TLAS，复制配置并保留Upload资源；返回是否新开一代历史。它覆盖传入sampleOffset，不允许调用者和内部计数各自推进。它不提交、不等待、不读回。正常使用必须在外部资源替换和对象析构前Flush或Readback。

Flush调用既有SubmitWait：Close→ExecuteCommandLists→队列Signal→CPU等Fence→重置allocator/list，成功后清理uploads。Readback先录制历史COPY_SOURCE→Readback复制→历史恢复UAV，然后Flush，最后Map并返回CPU自有vector。CPU Map读范围为[0,bytes)，Unmap写范围为[0,0)，表明CPU没写入。

单队列每批的依赖链：

```text
批buffer(UAV)：DXR写
  → Transition UAV→NON_PIXEL_SHADER_RESOURCE
批buffer(SRV)：compute读
历史buffer(UAV)：compute读取旧值并写新值
  → 历史UAV barrier
  → 批buffer Transition SRV→UAV
下一批DXR/compute
```

Transition声明访问状态变化并建立对应依赖。历史连续两次都处于UAV状态，仍有前写后读依赖，因此需要UAV barrier。它不改变资源状态，也不是CPU Fence。参见[Microsoft UAV barrier定义](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ns-d3d12-d3d12_resource_uav_barrier)。

根签名：参数0为t0批输出SRV，参数1为u0历史UAV，参数2为b0六个常量。实际API：

```cpp
void SetComputeRoot32BitConstants(
    UINT RootParameterIndex,
    UINT Num32BitValuesToSet,
    const void* pSrcData,
    UINT DestOffsetIn32BitValues);
```

本课调用`SetComputeRoot32BitConstants(2,6,constants,0)`：参数2、复制6个32位值、数据来自CPU数组、从根常量第0项写起；单位是32位项而不是字节。六项分别为width,height,batchCount,previousCount,generation,reserved。该调用返回void；根签名序列化、CreateRootSignature和CreateComputePipelineState则使用HRESULT并检查失败。见[Microsoft API说明](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12graphicscommandlist-setcomputeroot32bitconstants)。

尺寸改变会重建批buffer和历史buffer，必须先完成旧批次并确认Fence完成；存在尚未提交的uploads时拒绝Resize。先创建两份新资源成功后再替换旧对象。此版本尚无多帧异步退役队列，失败后不能假装已经提交，也不能删除等待来冒充异步。

输入范围、样本计数/代号溢出、缺失shader、HRESULT、CPU/GPU历史不一致、非有限结果或Debug消息导致验收失败。GPU等待有既有30秒上限；设备故障或提交失败应停止该渲染器，未实现透明恢复。

本节只有一个D3D12 DIRECT队列，没有CUDA外部消费者，所以还没有导入External Fence，也没有本节CUDA kernel可供compute-sanitizer检查。PT.10整章要求的外部生产者/消费者时间线、互操作与sanitizer保留到后续实际接入时完成，不能拿当前D3D12 Debug通过代替。多队列/Fence职责参见[Microsoft同步说明](https://learn.microsoft.com/en-us/windows/win32/direct3d12/user-mode-heap-synchronization)。

## 真机验收

从仓库根目录：

```powershell
.\learning\sandbox\path_tracing\dxr-path-tracer\verify_history.ps1
```

脚本按自身定位，依赖已完成PT.8的gallery.gltf/bin、energy-lut.bin和材质回归资产。CMake/VS2022构建C++宿主，DXC编译lib_6_3路径shader与cs_6_0累积shader。没有CUDA kernel，不涉及nvcc架构选项。所有新结果直接位于`dxr-path-tracer/results/pt10-history/`。

|验收|实测|
|---|---|
|2+5+6对一次13spp|最大归一化差3.0646262e-7；路径计数、首样本特征逐字段一致；三批之间零提交，最后一次提交|
|相机改变|重置后与全新13spp差2.0487540e-7；改变前后线性MSE .8975453|
|96×48→95×49|每像素count13；新旧资源尺寸和索引有效；参考差3.0642193e-7|
|地板材质改绿|参考差2.5500431e-7；改变前后MSE .0534355|
|金属球节点平移、重建TLAS|参考差2.7161953e-7；改变前后MSE .0547781|
|灯强度12→3|参考差1.3417949e-7；改变前后MSE .7921658|
|seed变化|参考差1.7225340e-7；开启新一代历史|
|旧历史NaN/999毒化后手动重置|参考差0；旧错误/计数不残留|
|未提交批次时Resize|明确拒绝；随后原批次可Flush并读到count14|

归一化差定义为abs(a-b)/(1+abs(b))，比较RGB一阶矩及亮度二阶矩；容差2e-5。全批参考仍用同一个已在PT.8验收的积分器，因此该对照主要证明累积/调度/重置正确，不独立证明所有光传输公式。

静止收敛图为128×64，K8/MIS/RR，连续seed0样本；参考是独立seed73的1024spp，仍有参考噪声与有限K偏差：

|SPP|线性RGB MSE|实际射线|
|---:|---:|---:|
|1|.4842375655|24359|
|4|.1247631269|97286|
|16|.0317489261|389853|
|64|.0077482796|1560951|
|256|.0027293267|6244087|

图已实际查看。颜色预览仍是Reinhard后一次sRGB编码，无降噪；MSE直接读取PFM线性浮点，不使用PNG。单次随机序列的误差不保证每帧单调，脚本检查长期下降及末两检查点，不能把本次单调结果讲成MC定理。

![GPU历史收敛](../../sandbox/path_tracing/dxr-path-tracer/results/pt10-history/history-convergence.png)

本节主测试Debug/GPU Validation0，Fence33/33。共享后端重构后，PT.8 K0 CPU几何/发光回归最大辐亮度误差2.63751e-9；PBR回归1966080路径/3648139射线、Debug0、Fence50/50；D.4源CPU场景销毁后材质读取误差0、Debug0、Fence2/2。

## 边界与下一节

持久历史与可复用管线已经实现，多批之间无需CPU读回；但目前仍是离屏验收，检查点/每128spp命令组有同步等待，没有完成交互窗口、多帧调度、降噪或完整GPU计时。商业引擎会通过帧资源、Fence退役和渲染图追踪这些依赖，本课先显式展示同样的所有权和访问规则。

下一节接曝光、Tone Mapping、一次sRGB编码和实际显示路径。自测：为什么不等长批次不能平均批均值？为什么相机重置要完全避开旧历史读取？为什么history一直是UAV仍需要UAV barrier，而这个barrier又不能替代CPU等待Fence？按授权下一节直接解答并继续。
