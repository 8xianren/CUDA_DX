# PT.8：有厚度玻璃与多界面状态

2026-10-21。代码：[pt08-materials](../../sandbox/path_tracing/pt08-materials/README.md)，本课结果：[results/slab](../../sandbox/path_tracing/pt08-materials/results/slab/)。

本小节将单平滑界面扩展为平行玻璃板。目标是从路径族推导整板反射/透射，正确更新介质、Radiance吞吐量与RR辅助尺度，并用真实DXR逐步记录验证。当前没有粗糙材质、吸收或嵌套介质。

## 上节答案

1. FORCE_OPAQUE跳过Any-Hit，不改变命中后的光学材质。玻璃要先命中，再计算Fresnel与折射；IgnoreHit只会让原射线继续，无法代替折射。
2. 80°反射miss的贡献为零，仍计入样本分母。丢弃零样本会把无条件期望改成命中条件下的期望。
3. 两次TraceRay依次在RayGen执行，第一次已返回，第二次才开始，嵌套深度仍是1。

## 问题和约定

游戏里的一块玻璃有前后两个表面。射线在前表面进入玻璃，并不意味着下一次一定离开：它可以在后表面反射，再在前表面反射，往返多次。

本课玻璃占-1<z<0。上表面z=0的外法线ng=(0,0,1)，下表面z=-1的外法线ng=(0,0,-1)。空气IOR=1，玻璃IOR=1.5，外侧两个灯分别位于z=2和z=-3。灯线性RGB辐亮度为(.8,.3,.1)和(.2,.6,1)。相机默认在z=1，向下发射平行射线；内部测试从z=-.5出发。

所有面实际是半宽256的有限矩形；没有侧壁。本课最深16次散射，CPU独立检查所有正确路径均未触及矩形边缘，因此可与无限横向平板模型比较。它不是任意入射条件都成立的闭合玻璃网格。

采用几何光学、非相干强度叠加，忽略薄膜干涉；材质为无吸收标量介质，每次界面用非偏振Fresnel平均值。正入射时两偏振反射率相同；斜入射多反弹不传播偏振状态，因此解析参考验证的是这个标量模型，不是完整偏振电磁传播。

## 从路径族求整板反射与透射

设外部入射角为theta_a，内部角为theta_g。Snell约束为n_a sin(theta_a)=n_g sin(theta_g)。两个表面平行，所以内部往返只改变法向分量符号，角度绝对值不变。互易的一对空气/玻璃方向具有相同的功率Fresnel反射率F。

先固定正入射n_a=1、n_g=1.5：F=((1.5-1)/(1.5+1))²=.04。

射线在上表面立即反射，系数是F；进入后从下表面直接穿出，系数是(1-F)²；内部反射一次后从上表面穿出，是(1-F)²F；内部反射两次后从下表面穿出，是(1-F)²F²。每次多一次内部反射乘一个F，并改变最终出口所在侧。

于是最终到下方的总系数：

T=(1-F)²(1+F²+F⁴+...)=(1-F)²/(1-F²)=(1-F)/(1+F)。

最终到上方的系数：

R=F+(1-F)²(F+F³+F⁵+...)=2F/(1+F)。

F=.04时，R=.076923076923，T=.923076923077，R+T=1。两面空气IOR相同且无吸收，所以整板外部功率系数和Radiance组合系数一致。红通道目标为R*.8+T*.2=.246153846154；实际CSV使用float存储的灯值，目标末位略有差异。

这说明“每面反射4%，所以整板就是4%”漏掉了从背面及内部往返后回来的路径。简单把两面相加成8%也不准确，因为到达后面及再穿出的光已经受到透射系数约束。

## 介质状态：命中不等于跨越

inside表示射线当前传播介质：0空气，1玻璃。ng始终朝玻璃外部。dot(d,ng)<0表示射线正准备从外向内过界面；dot(d,ng)>0表示准备由内向外。

|事件|原状态|新状态|原因|
|---|---|---|---|
|外侧反射|空气|空气|没有穿过边界|
|入射透射|空气|玻璃|跨过上/下表面进入内部|
|内部反射/全反射|玻璃|玻璃|仍在界面的同一侧|
|出射透射|玻璃|空气|穿过界面回到外部|

shader先验证entering与inside一致，再调用SampleDielectric。只有event==2才执行inside=1-inside。反射改变方向而不改变介质。若每次撞面都翻转inside，内部反射后的下一段就会错误地使用空气IOR，Snell方向、Fresnel和路径权重会一起错。

两侧法线和单一介质足以支持这个状态机。嵌套的玻璃、水、气泡需要知道边界两侧介质身份及当前介质；简单bool无法表达。介质栈适用于满足其嵌套假设的几何，重叠/相交体还要定义优先级和边界策略，本课没有实现这些。

## 为什么两个q²会消去

令q=etaI/etaT。Radiance相机路径的离散抽样更新为反射weight=F/pr，透射weight=(1-F)q²/pt。pr、pt是选中事件的概率质量，不是每球面度的连续PDF。按Fresnel抽样时pr=F、pt=1-F，因此反射weight=1，透射weight=q²。

从空气进入玻璃的q²=(1/1.5)²=4/9；返回空气时q²=(1.5/1)²=9/4。完整跨入再跨出的路径，两个比例相乘为1。内部反射的weight=1，因此不改变这个结果。即使中间反射多次，完整外部路径的beta仍接近1。

GPU实测normal_K2、mode0、path0：进入后beta=.444444447756、etaScale=2.25；离开后beta=.999999880791、etaScale=1。微小偏差来自float计算。etaScale每次透射乘1/q²，用于RR选择存活率时抵消纯介质比例；不能把etaScale再乘到最终L中。本实验不实际执行RR，只审计累计状态。

这里有两个重要限定。第一，半半抽样时pr=pt=.5，F不被抽样概率完全抵消；正入射直穿路径beta=(.96/.5)²=3.6864。这不是放大能量的bug：该路径发生的抽样概率是.25，期望仍为.9216。第二，如果相机直接在玻璃内开始，它没有先前空气→玻璃的4/9因子；出射后Radiance权重可以是2.25，不能拿“beta必须≤1”当断言。CSV的upper_coefficient/lower_coefficient对内部相机是Radiance组合系数，不是和必须为1的外部反射率/透射率。

参考：[PBRT Dielectric BSDF](https://pbr-book.org/4ed/Reflection_Models/Dielectric_BSDF)的Radiance透射修正；[A Better Path Tracer](https://pbr-book.org/4ed/Light_Transport_I_Surface_Reflection/A_Better_Path_Tracer)的RR etaScale处理。

## 有限散射上限究竟截掉了什么

K表示最多执行K次材质散射，不等于K次TraceRay。达到K次散射以后仍发出下一条射线：如果命中灯，贡献可以计入；如果又撞到介质界面，因为还需第K+1次散射才能继续，所以截断为零。

外部开始时，第一次上表面直接反射始终可计入。进入后，第j次内部界面遇到出口的系数为(1-F)²F^(j-1)，j=1,...,K-1；j奇数去下方，偶数去上方。被截掉的物理分支总质量为(1-F)F^(K-1)。这不是漏掉的RGB数值：RGB还取决于出口灯。

|K|R_K|T_K|未完成质量|
|---|---:|---:|---:|
|1|.04|0|.96|
|2|.04|.9216|.0384|
|8|.0769230767718|.923076923071|1.572864e-10|

只允许两次散射时，直穿路径能接收下方灯光，但是“入内→内部反射→再透射出外”需要3次散射，尚未计入。所以K2的红色目标.21632与无限结果.246154有真实截断偏差；增加样本数只能减少噪声，不能消除这个偏差。

内部45°发生全反射：F=1、没有出射分支，所有32768条路径完成16次散射后被截断。本课外部灯贡献为零；这不等于“全反射吸收光”，而是这组理想平行板路径无法到达外部灯。实际有限玻璃的侧壁、表面粗糙度或吸收会改变问题。

## 实现、布局和同步

入口代码slab.hlsl:50的RayGen循环。一线程拥有一条路径的o、d、beta、etaScale、inside以及完整Record；输出槽为index=y*width+x，没有跨线程写冲突，不需要atomic。ClosestHit只返回material+1和RayTCurrent，16B payload；0保留为Miss。表面法线由本fixture面身份确定，不从插值顶点法线推断介质内外。

共享采样原型：

```cpp
DielectricSample SampleDielectric(
    float3 d, float3 ng, float outside, float inside, float u, uint mode);
```

d是沿传播方向的单位向量，ng是朝玻璃外部的单位几何法线；outside/inside是两侧正IOR；u在[0,1)；mode=0按Fresnel概率抽样，1在反射和透射都可发生时半半抽样。F=0/F=1仍强制唯一事件。返回方向、F、weight、mass、pr、etaScale、q²、两侧IOR及event。函数中的inside是IOR参数，不是RayGen的bool状态。无效事件为0，宿主将其视为错误而不是黑色合法样本。

配置Config为96B：12个uint占48B，parameters/upperLe/lowerLe各float4共48B。parameters依次是水平斜率、起点z、外IOR、内IOR。maxScatter为1..16，startInside为0/1，disableOffset仅用于负对照，pad1保留。

Step为80B：position存命中xyz和t；direction存出射xyz和入射IOR；state存更新后beta、etaScale、本次weight和q²；probability存u、pr、F、mass；ids存命中材质、事件、介质旧状态、新状态。

Record为1312B：float4 radiance存RGB贡献与最终beta；uint4 status存终止原因、散射数、TraceRay数、最终inside；后跟16个Step。CPU static_assert核对总尺寸和偏移。StructuredBuffer按这个结构步长寻址，不套用cbuffer数组的打包规则。64×64路径每次读回5373952B，约5.125MiB；这是审计缓冲，不是建议的实时渲染像素格式。

TraceRay调用：

```hlsl
TraceRay(scene, RAY_FLAG_FORCE_OPAQUE, 255, 0, 0, 0, ray, payload);
```

依次为TLAS、射线标志、实例mask、射线HitGroup贡献、几何HitGroup索引乘数、Miss索引、RayDesc、inout payload。mask255包含本课所有实例；所有几何共用一个HitGroup所以两项偏移为0；Miss选择第0条。RayDesc含Origin、单位Direction、TMin=1e-5、TMax=1000。所有调用顺序发生于RayGen，ClosestHit不再追踪，最大嵌套深度1足够。FORCE_OPAQUE只控制Any-Hit路径，与玻璃散射是不同层次。

宿主继续复用：

```cpp
std::vector<uint8_t> DispatchRayBuffer(
    UploadContext& c, const InstanceFrame& frame,
    const void* data, size_t configBytes,
    UINT width, UINT height, size_t outputBytes,
    const std::filesystem::path& dxil);
```

c提供设备、列表、队列、Fence；frame提供TLAS与对象表，及必须仍存活的BLAS依赖；data/configBytes指向CPU配置并在函数中复制；width/height设置DispatchRays二维尺寸；outputBytes是本课1312×width×height；dxil指定已编译shader。返回vector拥有CPU字节副本，之后memcpy到Record数组。

t0根SRV绑定TLAS，t1绑定80B对象表，t2绑定96B配置，u0根UAV绑定结果。配置在UPLOAD，结果在DEFAULT/UAV，读回在READBACK/COPY_DEST。Dispatch后将结果UAV→COPY_SOURCE，再CopyBufferRegion；SubmitWait确认GPU完成，才Map并复制。Map本身不等待GPU。配置、结果、readback、PSO和SBT的ComPtr在Fence之后销毁；调用者保留场景/BLAS/TLAS直到所有提交结束。没有CUDA共享资源或外部Fence。

工具失败、HRESULT错误、逐字段不符、无效介质状态、统计不符和文件写出失败都会终止，退出码1；参数个数错误返回2。脚本检查每一步退出码。未实现设备丢失恢复或异步资源退役。本节共享后端实现未改动，仅增加新的CMake目标。

## 本机暴露的自相交及处理边界

最初仅使用TMin=1e-5和z平面投影。60°外部入射的第一条反射路径再次命中同一Top面：GPU终止码401，当前inside=0但方向却像从内部离开，CPU解析预期直接到上方灯。不能通过忽略状态断言或随意翻转介质来掩盖。

保留disableOffset=1负对照，本机4096条路径有2724条介质不一致拒绝，12293次TraceRay。正确实现按出射方向的z符号，将下一射线原点沿法线推到对应一侧2^-10单位。反射推向原介质，透射推向新介质。CPU参考对下一段起点采用同样偏移，但散射记录仍保存原表面点。

这个常量针对半宽256、厚度1、恒等世界变换的实验选择，远小于厚度，却超过本机出现的起点误差。没有声称适用于很薄玻璃、巨大坐标或非均匀缩放。通用方案应将重建/变换/求交误差界投影到几何法线，详见[NVIDIA自相交处理](https://developer.nvidia.com/blog/solving-self-intersection-artifacts-in-directx-raytracing/)。固定偏移和通用误差界将在PT.10集成路径中区分处理。

16次TIR后，基于float RayTCurrent累积的x偏差最大.000302315；几何位置/距离采用5e-4固定场景验收阈值，方向、概率、权重仍为3e-5，均需finite。此容差是教学测试标准，不是推导出的跨硬件保证。负对照的2724计数也不承诺跨驱动一致。

## 实测

命令工作目录：仓库根目录；脚本实际按自身路径定位，不依赖启动目录。

```powershell
.\learning\sandbox\path_tracing\pt08-materials\verify_slab.ps1
```

VS2022 CMake构建宿主，DXC lib_6_3/HV2021构建shader；真实RTX5070 DXR执行，没有CUDA kernel。8种情况×2抽样模式×8seed×4096路径=524288条正确路径，2374279次TraceRay。另有4096条负对照，不混入正确路径统计。Fence130/130，Debug/GPU Validation警告错误0，Khronos Validator错误/警告0。

|用例，Fresnel抽样|红均值|红SE|有限K解析目标|
|---|---:|---:|---:|
|正入射K1|.0320556645|.0008667601|.0320000005|
|正入射K2|.2162963625|.0006923883|.2163200032|
|正入射K8|.2461608604|.0008833047|.2461538497|
|空气60° K8|.2997192258|.0012338945|.2982604939|
|空气80° K16|.5386719167|.0016434796|.5352622435|
|内部30° K8|.5209029668|.0016636643|.5206097673|
|内部45° TIR|0|0|0|
|同IOR|.2000000030|0|.2000000030|

所有RGB在6SE+3e-6验收容差内。SE为样本方差估计的均值标准误差；通过这个统计检查不是一般无偏性的数学证明，推导与逐字段审计提供另外两层证据。half模式改变路径发生频率，但补偿后的均值仍匹配同一目标。

mode0正入射K8的32768路径中2521到上灯、30247到下灯，无截断，最深实际散射5次。mode1同场景则有128条达到K8截断；这不意味着物理上丢失128/32768能量，因为抽样概率和物理系数不同。对应物理未完成质量仍只有1.57e-10。

## 动手、自测与后续

打开results/slab/steps.csv，选normal_K2/mode0/path0，可看到0→1→0和beta的4/9→1。再选normal_K8/mode1的长路径，观察内部反射的inside前后不变。summary.csv可比较K1/K2/K8的解析目标与采样均值。

自测及答案：

1. 为什么K2的偏暗不能靠更多样本修好？它遗漏需要至少3次散射的路径族；样本增加只降低固定有限K估计器的噪声。
2. 为什么透射两次后beta不总为1？q²比例一定相消，但F/pr、(1-F)/pt抽样补偿仍取决于策略；只有本课Fresnel策略的完整外部无吸收路径满足逐路径约为1。
3. 为什么全反射不应修改inside？它没有跨过边界，只改变传播方向。

本课采用大诊断buffer、逐次提交同步等待、已知平面法线，便于审计。生产引擎的通用路径追踪通常需要任意网格几何法线、材质/介质身份、稳健起点、多帧资源和较小路径状态；实时透明渲染还可能采用屏幕空间等近似。不能把本fixture的固定状态bool和偏移常量当成生产玻璃方案。

下一小节按连续授课授权直接进入GGX微表面：先推导“哪些微小镜面能把给定光线反射到观察方向”，再从法线分布归一化、面积/立体角转换得到BRDF与采样PDF。PT.8仍未整章完成。
