# R.13.6：像素采样、线性HDR累积与统计收敛

2026-10-14。当前主线位于 [r13-renderer](../../sandbox/d3d12/r13-renderer/README.md)，本节结果放在该目录`results/r13-06/`。R.13.3–5原目录改为稳定名称，继续复用一套场景/AS/宿主基础；没有逐节复制渲染器。

## 1. 问题、约定与积分目标

上一节固定相机射线穿过像素中心，每命中点取64个灯面样本。只能减少该点直接光积分噪声，不能计算像素覆盖几何边界的比例。

本节明确选择箱式像素滤波：像素内部等权重平均。针孔透视相机、View/Projection/场景/材质/灯均固定，矩阵不加jitter。输出160×96，ViewRect=(0,0,160,90)，最后6行显式清零。降低分辨率是为了让多种子验证和轮廓观察更直接，不改变几何、FOV和16:9视图比例。

设像素整数坐标(i,j)，像素内部坐标(u,v)∈[0,1)²，沿对应相机射线的辐亮度为L(i+u,j+v)。本节像素目标定义为

    Cij = ∫0¹∫0¹ L(i+u,j+v) du dv

这是明确选择的滤波目标，不宣称像素在所有渲染器中都必然是物理面积平均。更一般的滤波器会引入权重与归一化，本节不展开。

比如轮廓像素30%区域看到颜色4、70%看到黑背景，目标为0.3*4+0.7*0=1.2。像素中心只能选到4或0，再准确地计算这个中心的灯光也无法恢复30%的覆盖比例。

## 2. 先推导采样估计，再写代码

### 术语说明：“相机样本”到底采样什么？（2026-10-16补充）

“相机样本”（camera sample）容易被误解为对相机对象、位置或朝向取样。它实际指对**相机成像模型用于生成主射线的输入变量**取样。本课相机位置、朝向与投影固定，针孔模型没有镜头孔径采样，也没有快门时间采样；这里实际只选择像素内部的位置(i+u,j+v)。因此本课优先称为“像素内位置采样”或“一次主射线采样”，首次使用广义术语时再注明“相机样本”。

必须区分三个阶段：

1. **采样位置**：(u,v)是单位像素内的二维位置，是生成主射线的输入，不是颜色。
2. **生成主射线**：相机模型把该位置映射为世界空间射线。针孔相机的世界空间射线原点仍是相机位置，不能把成像平面上的采样点称为世界射线原点；近裁剪通过射线有效区间处理。
3. **得到颜色估计**：追踪主射线、执行灯面采样与可见性判断后，才得到一次线性RGB估计Y，随后将Y累积到对应像素。

所以“一个相机样本”不是“一个已经计算出的颜色”。本课每个像素内位置样本生成一条主射线，再得到一次像素颜色估计；主射线后续产生的阴影射线不另外增加SPP。

更一般的相机模型还可能采样**镜头孔径位置**（景深）和**快门开启期间的时间**（运动模糊）。这些变量与像素位置共同决定主射线，所以统称“相机采样”，与主射线命中后的光源采样、BSDF采样区分。它不意味着必须随机移动相机。本课没有实现这些额外相机采样维度。

### 本课的估计式

u、v在单位像素内均匀采样，联合PDF为1，因此估计像素积分时没有额外非单位的像素PDF因子。

但沿这次像素内采样位置生成的主射线求交后，直接光估计仍来自随机灯面点q。上一节的条件估计是

    Y(u,v,q) = V(x,q) Le fr cs / pOmega(q|x)

其中x是该主射线与场景的命中位置。先对灯面采样取期望得到L(i+u,j+v)，再对像素内位置采样取期望得到Cij。因此可以同时抽(u,v)和灯面两维，一次得到完整像素估计Y。主射线Miss或阴影遮挡都贡献0，但仍计入一次像素颜色估计。

本节每帧在每个有效像素内取1个位置样本，由它生成1条主射线；命中后至多发1条灯连接阴影射线。SPP=samples per pixel；在本课中，每像素每帧增加1次颜色估计，即增加1 spp，不是把主射线和阴影射线数量相加。为了隔离采样问题，仍只有单盏矩形灯、Lambert直接光，无MIS、间接反弹、景深或运动模糊。

代码将原来的

    uv = (localPixel + 0.5) / ViewSize

改为

    uv = (localPixel + sampleOffset) / ViewSize

其中sampleOffset=(xi0,xi1)。如果围绕中心描述，偏移就是xi-0.5；不能在像素位置和投影矩阵里重复加同一份jitter。后续NDC映射、逆ViewProjection、齐次除法、单位方向和近面TMin均沿用已验证的实现。

## 3. 随机数的四个地址维度

`dxr_progressive_sampling.hlsli`提供无可变全局状态的函数：

    sample = F(pixelIndex, sampleIndex, dimension, seed)

- pixelIndex：输出buffer中的绝对像素编号。
- sampleIndex：每像素从0开始的采样序号，用于选择本次像素位置与灯面位置的随机数；本节每帧增加1，不是相机对象编号或射线总数。
- dimension：0/1给像素x/y，2/3给灯面u/v。
- seed：选择另一条可复现的测试序列；同一次正常累积中保持不变。

逐步混合32位整数，再取高16位的中点值 `(bits+.5)/65536`，严格在(0,1)内。CPU/GPU四维坐标逐帧全像素精确核对。它是有限离散伪随机序列，不等于证明数学上的IID；统计推导在理想独立同分布假设下成立，实测另行验证趋势。

不能让像素x和灯面u直接复用同一个随机数：边缘看到哪块几何会与采样灯的哪个位置发生人为关联，可能改变联合分布。也不能每帧只改Fence却保持sampleIndex不变：实际积分样本没增加。

## 4. 在线平均是怎样推出来的

N个等权重样本的平均定义为

    M_N = (Y1 + ... + YN)/N

已知前N-1个平均M_(N-1)，旧总和为(N-1)*M_(N-1)。加入新样本：

    M_N = ((N-1)*M_(N-1) + YN)/N
        = M_(N-1) + (YN - M_(N-1))/N

所以每像素只需保存平均值，不必保存所有过去的样本。shader中第一次直接赋值，其余在线更新：

```hlsl
uint count = sampleControls.x + 1u;
if (count == 1u)
    mean = result.directLight.xyz;
else
    mean = history[index].xyz
         + (result.directLight.xyz - history[index].xyz) / float(count);
```

第一次不读未初始化的Default Heap，也不读上一个测试序列的历史。Miss和遮挡的0仍照常更新并增加计数。这里每帧恰好1个样本，才可以用sampleIndex+1当计数；将来每帧样本数不同，应按样本数量加权，不可等权平均不同样本数的帧。

该式在实数算术下等价于求和后除N，浮点舍入会造成微小差异，所以用CPU double对GPU原始单样本求和独立校验，而不是在CPU复制同一float递推公式。

### 4.1 为什么分批累积，而不是同一帧发很多条jitter射线？

2026-10-14补充：同一帧每像素发射多条jitter相机射线完全成立。本课每次更新1 spp，是渐进预览的调度选择，不是路径追踪的数学要求，更不是比同帧多样本天然准确。

固定相机、场景时刻、材料、灯光及像素滤波目标，给定同一套64个完整样本（包括像素位置和灯面随机变量）：

    一批64 spp：M64 = (Y1 + ... + Y64)/64
    八批各8 spp：最终仍为同一组64个Y的平均
    六十四批各1 spp：最终仍为同一组64个Y的平均

在权重相同、没有中途去噪/截断等非线性操作的前提下，实数算术结果相同；浮点归约顺序可能带来小差异。若旧平均A_n已有n个样本，新批次有m个样本、平均B_m，正确合并为：

    A_(n+m) = (n*A_n + m*B_m)/(n+m)

不能不管批次大小就写(A_n+B_m)/2。同帧多样本和跨帧累积可以组合，例如每次更新8 spp并继续累计。当前代码仍是每次1 spp，本段没有把多样本批处理描述成已经实现的功能。

分批的好处是尽早显示粗糙结果、逐步改善，并在批次之间响应相机操作或取消；总共64个样本不会因为拆成多次更新就免费少算路径。实际性能还受批量、调度及读回等开销影响，本课没有做二者性能比较。“同一帧”若指一张最终输出图片，离线渲染器完全可以内部执行很多批，最后只交付这一张图。

### 4.2 与MSAA、TAA和时间采样的区别

每像素多条jitter射线分别求交、计算光照，更接近超采样/路径追踪多spp。典型MSAA主要增加覆盖、深度等采样，并可让多个样本共享着色结果，不等于每个样本都执行一条完整路径。相机jitter采样像素范围；软阴影和反射等光照噪声还需要采样灯面、反射方向等维度，不能靠固定光照样本而只移动相机采样点解决全部噪声。

本课跨多次更新，仍在计算同一个静止场景时刻的积分，不是TAA式运动重投影。计算消耗了现实时间，并不意味着场景时间在变化。TAA/TSR需要在运动中寻找历史对应位置、拒绝失效数据并重建当前画面，详见[R.13.7第8节](R.13.7-历史有效性与重置.md#8-与引擎和taa的关系)。

如果要渲染运动模糊，则目标额外包含快门区间内的时间积分，例如：

    C_p = ∫快门区间 ∫像素范围 L(u,v,t)*w(u,v,t) du dv dt

此时对不同场景时间t采样，是同一张输出图片的积分组成部分，不是误把不同目标的旧帧混在一起；采样分布、滤波和权重须与该目标对应。本课尚未实现此时间维度。

可选后续对照：固定同一套64个样本，比较一批64、八批各8和六十四批各1，检查最终线性结果是否仅有浮点舍入差异。这是建议实验，尚未实现或实测，不能计入下文已有验收结果。

## 5. 必须在线性HDR中累积

HDR在此表示光照值允许大于1，浮点存储用于保留它；不是一种必须先套用的显示效果。

隔离测试按帧交替输出0和(4,2,1)，偶数帧后的正确均值为(2,1,.5)。如果夹到[0,1]再平均，得到(.5,.5,.5)，能量关系被破坏。

非线性显示变换T(x)=x/(1+x)也不能放在平均之前。只看红色通道：

    正确：T((0+4)/2)=T(2)=2/3
    错误：(T(0)+T(4))/2=(0+.8)/2=.4

本节history里只存线性RGB。输出PFM保留浮点；Python只在全部渲染和验证之后读取PFM，做固定曝光1、Reinhard和sRGB的离线PNG排版。Python不生成样本、不累积、不参与DXR。

### 显示链路中的曝光与色调映射（2026-10-14澄清）

本课完整预览链路是：未曝光的线性HDR平均值M → 曝光倍率E乘法 → Reinhard色调映射 → sRGB编码 → 8位量化。显示变换不能只用Reinhard曲线代称，曝光与色调映射是两个独立步骤；sRGB编码也不是色调映射。

    exposed = E * M
    mapped = exposed / (1 + exposed)
    encoded = sRGB(mapped)

此前“曝光1”指曝光倍率E=1，不是+1 EV。若定义正曝光补偿ΔEV为变亮，则E=2^ΔEV：0 EV对应倍率1，+1 EV对应倍率2，-1 EV对应倍率0.5。这是相对于本课基准的曝光补偿，不是带快门/光圈/ISO标定的绝对相机EV100。当前预览固定E=1，所以脚本省略了乘1；没有自动曝光或可调曝光界面。

固定曝光倍率是线性操作，E*mean(Y)=mean(E*Y)，数学上可以与平均交换。不能交换的是非线性的色调映射、sRGB编码，以及截断/量化。本课把曝光也放在累积之后，是为了让历史保存未曝光的光照、便于统一比较和后续独立调节显示。若引擎使用pre-exposure，必须说明历史的曝光尺度与转换；本节未实现该机制。

当前架构只修改显示曝光或色调映射参数，不会改变原始光照积分目标；修改灯的Le则改变目标。相机/灯/材质变化的历史失效机制将在R.13.7展开。

## 6. GPU资源、数据布局与同步

新增文件分工：

|文件|职责|
|---|---|
|dxr_progressive_sampling.hlsli|b1采样参数、四维随机数、像素偏移|
|dxr_progressive_accumulation.hlsli|u1历史与在线平均|
|dxr_progressive_runner.h|两槽提交、历史资源、实验序列、CSV统计|
|dxr_progressive_reference.h|CPU随机数/几何/灯光抽查、全量均值校验、PFM|
|dxr_progressive_preview.py|离线预览和轮廓放大图|

沿用Root参数0–4：TLAS t0、输出u0、View b0、VB t1、IB t2。新增参数5是root UAV u1历史，参数6是b1的4个32位root constants。总Root成本从10 DWORD变为16 DWORD。

```cpp
void SetComputeRoot32BitConstants(
    UINT RootParameterIndex,
    UINT Num32BitValuesToSet,
    const void* pSrcData,
    UINT DestOffsetIn32BitValues);
```

调用`SetComputeRoot32BitConstants(6,4,controls,0)`：6是Root参数索引，不是寄存器b6；4表示4个DWORD；controls指向CPU uint数组{sampleIndex,seed,flags,0}；目标偏移0以DWORD计。该void接口把值记录进命令列表，CPU栈数组不需要活到GPU执行；对比View root CBV记录GPU地址，上传槽的数据则必须保持直到Fence完成。签名配置、shader声明必须匹配。

|数据|布局/所有权|
|---|---|
|View|128B有效数据，两槽各按256B对齐；CPU等本槽Fence后改写|
|采样控制|4个uint、16B，通过root constants传递|
|history|Default Heap，float4 stride16；xyz线性均值，w样本数|
|本帧读回record|192B：前160B沿用几何/直接光数据，后16B均值/计数，再16B四维采样坐标|
|主payload|仍116B，新增的均值与采样坐标不通过TraceRay携带|
|阴影payload|仍4B，嵌套TraceRay深度仍2|

history是所有帧共享的一块GPU资源，不是每个CPU帧槽各一块历史。本节最大2048样本，计数存float能精确表示；无限长渲染的计数表示/浮点误差不在此实现范围内。

每像素恰好一个RayGen读写自己的history[index]，同一Dispatch内没有跨像素竞争，不需要atomic。但相邻Dispatch之间有数据依赖：上一帧写历史，下一帧要读它。

第一次将history从COMMON转为UNORDERED_ACCESS；后续保持UAV状态，并在下一次Dispatch前插入：

```cpp
D3D12_RESOURCE_BARRIER b{};
b.Type = D3D12_RESOURCE_BARRIER_TYPE_UAV;
b.UAV.pResource = history;
list->ResourceBarrier(1, &b);
```

ResourceBarrier的NumBarriers=1、pBarriers指向该描述；UAV barrier约束这块资源前后的UAV访问顺序，不执行CPU等待。不能用“同一队列按序提交”代替缺失的资源访问同步，也不能用shader内线程组同步跨Dispatch排序。

CPU仍通过Fence等待槽复用和读回：output从UAV转COPY_SOURCE后CopyResource到Readback，再Signal。Map本身不等待。history/Upload/两槽输出和读回由runner的COM引用持有；场景、SBT等由调用方持有，runner返回前排空在途任务。最后按样本顺序退役两个槽，CPU参考按相同顺序读取原始样本。

失败路径：资源创建/录制/Map/Signal检查HRESULT；Fence检查设备移除与超时；数值或PFM写入失败累积失败状态，仍排空正常提交的任务后返回非零；Debug Layer消息汇总也参与验收。shader正常输入已在CPU验证；非法状态会由读回标记/有限性/计数检查发现。本课是固定场景验证程序，不实现设备丢失恢复。

## 7. 方差规律与误差统计的边界

在样本独立同分布且方差有限时：

    Var(M_N) = (1/N²) Σ Var(Yi) = σ²/N
    标准差 = σ/√N

一般情况下还存在协方差项：

    Var(M_N) = (1/N²)[Σ Var(Yi) + 2Σ(i<j) Cov(Yi,Yj)]

重复同一随机样本时这些项不会消失，且实际平均始终等于第一次样本。增加计数不等于增加有效信息。

本节8个seed，每条序列观察1/16/256 spp；全部与独立seed9000的2048 spp参考图比较。MSE是在ViewRect内全部RGB通道上平均的平方差；报告RMSE是8个seed的平均MSE再开根号。参考图也有误差，不能当解析真值；不会要求每个像素或每次追加样本误差都下降。

2026-10-14 RTX5070 / DXR Tier1.1实测：

|SPP|8种子平均MSE|sqrt(平均MSE)|
|---|---|---|
|1|0.000667845553|0.0258427079|
|16|0.0000423043997|0.00650418325|
|256|0.00000288980542|0.00169994277|

样本增加16倍，RMSE分别缩小约3.97倍和3.83倍，与1/sqrt(N)趋势相符；有限参考误差会影响比值。这是该固定场景/随机序列的验证，不是所有采样器都必然达到这个数字。

## 8. 其他实际验收

- 全图逐帧GPU均值对CPU double原始样本求和平均：2048 spp参考序列最大RGB向量差约1.10e-6；8个256 spp序列最大约4.07e-7。
- 四维随机坐标逐帧全量一致；有限性、坐标标记、计数、视口外清零均通过。
- 每条序列第一帧全图验证相机几何，其后每帧轮转抽查约68个像素，独立CPU解析相机/三角形求交通过；在抽查命中点用GPU位置做CPU double面积光参考。geometry/shadow mismatch均0，样本光照最大差约3.34e-7；这不是逐帧全量阴影核对。
- 固定随机序号：重复16次与第一次MSE=0。固定像素中心、灯样本变化：光照平滑但阶梯轮廓仍在。
- HDR/零值交替：16次后均值(2,1,.5)，验证大于1的值和零贡献都保留。
- seed0重新跑256次，与之前seed0逐像素MSE=0，验证可复现性和新实验首样本初始化。
- 一共4640次采样Dispatch，加AS构建Fence最终4641/4641；Debug Layer 0 error/0 warning，exit0。
- 默认R.13.4、lighting R.13.5重新编译shader并回归，各8组PASS、Fence9/9、Debug0/0。
- 六格预览和固定中心/像素面积采样的轮廓放大图均已实际查看。放大使用最近邻，不把图片插值的平滑冒充抗锯齿。

![采样与累积](../../sandbox/d3d12/r13-renderer/results/r13-06/comparison.png)

![轮廓对照](../../sandbox/d3d12/r13-renderer/results/r13-06/edge_comparison.png)

完整日志：[validation.txt](../../sandbox/d3d12/r13-renderer/results/r13-06/validation.txt)。逐种子CSV：[convergence.csv](../../sandbox/d3d12/r13-renderer/results/r13-06/convergence.csv)。

## 9. 运行与下一节

仓库根目录下，逐步成功后再执行下一步：

```powershell
$lesson='learning/sandbox/d3d12/r13-renderer'
$dxc='C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\dxc.exe'
& $dxc -T lib_6_3 -D ENABLE_DIRECT_LIGHT=1 -D ENABLE_PROGRESSIVE=1 -Fo "$lesson/dxr_progressive.dxil" "$lesson/dxr_view.hlsl"
& learning/sandbox/build.ps1 "$lesson/dxr_view_pipeline.cu" -NoRun
& "$lesson/dxr_view_pipeline.exe" "$lesson/dxr_progressive.dxil" progressive
python "$lesson/dxr_progressive_preview.py"
```

编译器使用build.ps1的sm_120；宿主.cu内没有CUDA kernel，GPU渲染由DXR/HLSL执行。progressive参数必须匹配启用两个宏的DXIL。脚本只格式化已经验证的PFM。

本课每帧都读回大量诊断记录供CPU检查，实际引擎通常把历史保留在GPU并直接显示；共享机制是像素采样、线性累积与GPU资源同步，不是本课的测试吞吐模式。这里不是TAA：没有运动向量、历史重投影或固定混合权重，也没有去噪。

每次实验显式从sampleIndex=0开始，相机/场景始终不变；这不等于已经实现了历史有效性管理。R.13.7将讨论改变相机、场景、材质或灯时如何自动reset，正常随机样本变化为何不应reset。R.13.8再将结果接入窗口显示。

自测：①前3个样本平均值2，第4个样本是10，新平均多少？②每帧都把随机序号设为0，再累积256帧为什么不收敛？③样本0和4应先平均再tone map，还是先tone map再平均，结果分别是什么？

2026-10-14答案：①新平均为(3*2+10)/4=4，也等于2+(10-2)/4。②所有随机维度、像素和场景固定时，同一个样本重复256次的平均仍是第一次样本，未增加有效采样信息。③在E=1条件下，先平均再Reinhard为T(2)=2/3；先Reinhard再平均为(T(0)+T(4))/2=0.4。二者不同来自非线性，不能据此说固定曝光乘法也不能与平均交换。

## 参考资料

- [PBRT Sampling Theory](https://www.pbr-book.org/4ed/Sampling_and_Reconstruction/Sampling_Theory)：连续图像、采样与重建。
- [Microsoft SetComputeRoot32BitConstants](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12graphicscommandlist-setcomputeroot32bitconstants)：原型与参数。
- [Microsoft UAV barrier](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ns-d3d12-d3d12_resource_uav_barrier)：UAV访问同步。
- [Microsoft Rasterization Rules](https://learn.microsoft.com/en-us/windows/win32/direct3d11/d3d10-graphics-programming-guide-rasterizer-stage-rules)：MSAA覆盖采样与着色的区别。
- [Epic Path Tracer](https://dev.epicgames.com/documentation/en-us/unreal-engine/path-tracer-in-unreal-engine)：渐进预览，以及MRQ空间/时间采样。
