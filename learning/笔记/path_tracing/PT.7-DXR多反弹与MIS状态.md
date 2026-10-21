# PT.7：DXR多反弹与MIS状态

2026-10-21。[前课：beta推导](PT.7-路径吞吐量与多反弹展开.md)。[源码与运行入口](../../sandbox/path_tracing/pt07-throughput/README.md)。本课完成限定盒腔的真实glTF/DXR多反弹、RGB吞吐量和NEE/BSDF命中MIS。俄罗斯轮盘赌尚未实现，PT.7保持进行中。

## 上节答案

均匀半球下单步因子2rho*cos=2*.8*.9=1.44；这是采样补偿后的权重，不是概率，可以大于1。K=0仍应显示相机直接看到的发光。固定K=8增加SPP只能减少采样噪声，不能补回被截断的长路径。

## 要解决的问题

在xi做一次NEE，同时沿BSDF继续路径到x(i+1)。若下一顶点发光，该发光项和前一顶点NEE都在估计“从xi直接连接光源”的积分。直接把两个完整估计相加会重复计数。但x(i+1)反射来的更远光照，尚未被xi的NEE计算；不能把该直接连接的权重乘到所有未来贡献上。

beta_i是到达xi的散射权重积。当前NEE灯样本y方向ωL，估计：

\[
C_L=\beta_i\,\frac{f_i L_e(y)\cos\theta_i V}{p_L(\omega_L)}w_L(\omega_L).
\]

BSDF延伸更新beta(i+1)=beta_i*f_i*cos/pB，抵达下一发光表面后，其发光贡献：

\[
C_B=\beta_{i+1}L_e(x_{i+1})w_B(\omega_B).
\]

wi两者一般不同，不能拿当前灯样本的wL去与下一命中wB直接求和。权重和1的条件，是在同一方向上比较两个策略的PDF。

保持beta无MIS权重，能继续正确估计x(i+1)处散射来的光。若beta乘wB，未来多反弹也被无故压低；也不能在采样当前灯点后把previousPdf覆盖成灯策略PDF。

## 为什么必须记前一顶点

抵达x(i+1)时，wB需要pB(ωB)和从xi出发的pL(ωB)。当前点的法线或当前新采样方向不能替代上一跳数据。RayGen保存previousPoint和previousPdf，计算发光权重后，才在下一次BSDF采样完成时覆盖它们。

Power启发式：wB=pB²/(pB²+pL²)，wL=pL²/(pL²+pB²)。代码先缩放再平方，避免不必要的溢出。相机主命中depth0没有对应前一顶点NEE，故发光权重1；BSDF-only模式也为1。当前只有连续Lambert，delta事件标志和专项材质仍在PT.8。

## glTF盒腔与联合PDF

[-1,1]^3闭合盒，6面/12三角形/6mesh/6instance，共享材质Cavity。rho=(.6,.4,.2)、Le=(.1,.2,.3)读取导入后的glTF线性因子。观察点原点，主方向+Z，每次RayGen是一条独立路径样本，不是新相机图像或窗口。

全表面均匀发光、Lambert反射且无开口，有限深度解析值仍为LK=Le*(1-rho^(K+1))/(1-rho)，逐RGB成立。换成盒子不改变常量辐亮度解；余弦采样BSDF-only每条路径仍为同一几何级数。

光源采样先均匀选面，概率1/6；每面面积4，条件面积密度1/4，所以联合pA=1/24。必须包含选面概率；只使用1/4会漏乘光源选择概率。

转换方向密度：pL=|y-x|²/(24*cosLight)。余弦半球BSDF PDF pB=cosSurface/pi。抽到当前所在平面时，切向连接的cosSurface=0，样本贡献为0；本实现不重采样，因此PDF仍为1/24。若排除当前面再选5面，必须相应改成1/20，并同步命中灯时的PDF评估，不能只改一个分支。

## GPU循环与有限深度

`gpu_path.hlsl:35`：RayGen持有origin/direction、RGB beta/L、previousPoint、previousPdf、rng和depth。ClosestHit只有材质+1与t，payload16B；所有TraceRay顺序调用，不在ClosestHit中追踪，因此MaxTraceRecursionDepth仍为1。

一次迭代：TraceRay→重建交点→用上一跳PDF累加当前发光→若depth<K做一次NEE→保存诊断→若depth==K停止→采样BSDF→更新beta、previousPoint/PDF与下一射线。

最大K次散射时，主命中depth0到最终depthK共K+1顶点。最后仍收取发光，但不做NEE：最后顶点的NEE需要再经历一次该顶点散射，属于K+1次散射的路径。固定K按这个约定验证，不能一边改变深度定义一边沿用旧解析式。

NEE在这里也用最近命中查询，检查命中距离是否与所选灯点距离一致；不是任意网格通用的截断shadow接口。闭合凸盒中，非同面连接都应可见，失败会计入诊断并使验收退出。

## 数据布局与共用提交接口

PathConfig64B：偏移0 paths/maxScatters/seed/mode；16 rho.xyz+padding；32 emission.xyz+padding；48保留。读取方式StructuredBuffer，无cbuffer打包歧义，C++ static_assert核对。

每条路径每个顶点PathRecord112B，连续7组16B：position.xyz/t、beta.xyz/发光权重、累计L.xyz/上一跳PDF、灯样本.xyz/可见性、已乘beta的NEE.xyz/灯权重、实际方向.xyz/保留、uint4诊断（材质+1、射线数、错误数、depth）。索引为path*(K+1)+depth。K8、4096路径，一次读回4128768B。每个RayGen独占自己的9个记录，无atomic或跨路径同步。

CPU将共用调度从PT.6抽为gltf-scene/src/ray_buffer_dispatch.{h,cpp}，PT.6保留薄封装，未复制设备/BLAS/SBT实现。接口：

```cpp
std::vector<uint8_t> DispatchRayBuffer(
    UploadContext&, const InstanceFrame&,
    const void* data, size_t configBytes,
    UINT width, UINT height, size_t outputBytes,
    const std::filesystem::path& dxil);
```

context拥有device/queue/list/fence；frame持有TLAS与对象表，外层保持BLAS存活；data/configBytes为CPU配置和大小，先复制到UPLOAD；width/height为RayGen网格，本课4096×1；outputBytes是输出总字节数，必须和shader布局/索引匹配；dxil为编译库路径；返回CPU拥有的字节vector，再memcpy到PathRecord数组，不把可能未对齐的字节指针强转为结构体。

根参数仍为t0 TLAS、t1 80B对象表、t2配置、u0结果；UPLOAD为GENERIC_READ，输出DEFAULT/UAV，READBACK为COPY_DEST。管线和SBT沿用16B payload/三导出/单HitGroup/递归1。调度后输出UAV→COPY_SOURCE→CopyBufferRegion→Submit/Signal/Wait→Map→复制→Unmap，所有局部GPU资源保持到Fence完成。Map本身不等待GPU。

配置范围、创建/序列化/Map失败、等待超时、设备移除、GPU诊断/非有限数值/方程误差均导致非零退出。miss时shader填满剩余输出槽的失败标记，不让CPU读未初始化内容。没有设备恢复或异步帧资源改造。

## 实际遇到的数值边界

首次MIS运行中，接近棱边的float命中被舍入为同时位于x=1与y=-1。下一条射线可能从另一面的外侧离开而miss。TMin减得过小又出现自身面命中，所以最终保持TMin=1e-6，将所属面坐标吸附到±1，切向分量限制在[-1+2e-6,1-2e-6]。

这是本盒子特定的微小几何近似，不声称任意网格鲁棒性或严格无偏。CPU按真实记录的射线方向解析求交，核对修正位移及距离误差。不能从被修正的极短线段重新反推方向来核对PDF，否则微小位置变化被放大为方向变化。真实方向因此单独占一个float4诊断字段。统计通过不替代通用误差分析。

## RTX5070实测

每模式8seed×4096路径，K8；模式包括BSDF-only、Power MIS、故意NEE+BSDF不加权相加。另测K0/K1、rho0、Le0。总计890112顶点、1330943次TraceRay，逐顶点CPU方程最大绝对差2.55761468537e-6，CPU解析t最大差6.05036851731e-7。Fence29/29，Debug/GPU Validation0，glTF Validator errors0/warnings0。所有检测通过。

|红通道|均值|seed均值SE|目标|
|---|---:|---:|---:|
|BSDF-only|.247480586171|0|.247480593538|
|Power MIS|.247478297451|.000115117071080|.247480593538|
|错误直接相加|.393168166705|.000581876171774|错误期望.394961185585|

错误版本的期望不是2LK，而是Le+2(LK-Le)=2LK-Le，因为相机直接可见发光只计一次。有限样本均值在本测试6SE+2e-6宽松阈值内；该阈值是回归检查，不是严格置信保证或无偏证明。

RGB MIS均值为(.247478297451,.333248362364,.375025799835)，参考为(.247480593538,.333245960265,.374999824298)。float导入因子使参考与前课double字面值略有不同。

真实路径0：depth1 betaR=.600000023842，发光权重.333096444607，当前NEE贡献.0177548751235，累计红.165621459484；depth2 betaR仍为.360000014305，而不是再乘前一项MIS权重。最终单路径.266032934189不等于总体参考，属于正常随机波动。`path0.csv`记录全过程，`depths.csv`保存每深度路径数和平均RGB beta；无RR所以各深度仍32768路径。

本均匀盒腔对BSDF-only本来零方差，MIS反而引入灯采样噪声，不能用它宣称MIS更快或更低噪声。目标是验证状态/计数/期望。未计GPU时间、未生成图像或窗口。

PT.6受影响的gpu_mis_test小/大灯回归均PASS，原计数和误差保持一致，Fence20/20、Debug0。

## 复现与下一课

仓库根运行`& ./learning/sandbox/path_tracing/pt07-throughput/verify_gpu.ps1`，结果直接写本课results/gpu；exe在build/Release，共享静态库仍在gltf-scene/build。[运行日志](../../sandbox/path_tracing/pt07-throughput/results/gpu/run.txt)。

商业渲染器的BSDF、灯选择器与命中属性可处理一般场景，诊断数据通常按需输出；本节固定盒面法线和灯采样，并为每个顶点写112B记录和同步读回，以便检查每项计算。底层仍是同样的TraceRay、BSDF/PDF、MIS与Fence机制。当前无一般网格法线、纹理材质、delta分支、环境光或RR；一般材质在PT.8，RR为下一节PT.7。

自测：命中下一发光体的MIS需要当前顶点PDF还是上一顶点PDF？发光权重.2应否乘进后续beta？为什么K次散射在depthK仍收发光但停止NEE？

参考：[PBRT PathIntegrator](https://pbr-book.org/4ed/Light_Transport_I_Surface_Reflection/A_Better_Path_Tracer)、[DXR管线递归深度](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ns-d3d12-d3d12_raytracing_pipeline_config)。


后续更新（2026-10-21）：[俄罗斯轮盘赌与存活补偿](PT.7-俄罗斯轮盘赌与存活补偿.md)已完成，PT.7限定范围通过验收。PathRecord现由112B增至128B，配置保留区用于RR；共用Run移到gpu_path_dispatch.cpp。前课默认关闭RR回归通过，本文保留当时的112B布局与实测记录。
