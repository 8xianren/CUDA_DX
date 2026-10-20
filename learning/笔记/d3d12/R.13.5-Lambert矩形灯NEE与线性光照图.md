# R.13.5：从受光几何推导 Lambert 矩形灯 NEE

2026-10-13，沿用新版R.13.1–4的矩阵相机、三实例、世界位置/几何法线和双槽Fence。按仓库cuda-tutor课程流程授课。本节完成直接光单帧数值图，不提前实现跨帧累积。下一节R.13.6。

## 1. 要解决的问题与全部约定

相机射线已经命中x，单位法线n已验证。现在求该点朝相机方向wo的反射辐亮度Lo，而不是把normal映射成颜色。可以把矩形灯想成天花板上的发光面板：桌面某点能看到多少面板、以什么角度看，会决定受光；挡住部分面板自然形成半影。

- 世界+X前/+Y右/+Z上，1单位=1米；延续原有View/Projection，不重新简化相机。
- 384×256输出，ViewRect=(0,0,320,180)，像素中心射线；本节8组相机完全相同。视口外清零。
- 不透明、单面Lambert反射；rho为线性反射率，id1=(.7,.18,.08)、id2=(.08,.28,.7)、地板=(.65,.65,.65)。法线用几何法线，不faceforward；n·wo<=0时不反射。
- 一盏均匀单面矩形灯：中心c=(2,-.5,3.5)，U=(1,0,0)，V=(0,-1,0)，半边长1米，A=4平方米，nL=(0,0,-1)。固定几何与灯彼此分离，r>0。
- Le=(12,11,9)，线性RGB辐亮度参数，不是点光源强度I，也未标定为UE灯光的流明输入。没有介质吸收，沿无遮拦光线Li=Le。
- 常规模式无环境光/间接反弹，背景黑。灯仅以积分参数存在，不是TLAS发光网格。
- 每个固定命中点取64个灯面样本；没有因此生成64条像素内不同位置的主射线，不等于64 spp，不做抗锯齿或跨帧累积。“相机样本”是对主射线生成输入的采样，不是对相机对象取样；本课固定像素中心，详细术语见[R.13.6第2节](R.13.6-像素采样与线性HDR累积.md)。

## 2. 先由能量约束得到Lambert

接收面朝向入射方向wi的投影面积比例为cos(theta_s)，所以微小方向范围的辐照度是

    dE = Li(wi) cos(theta_s) dωi

E是单位表面积接收到的功率；Li是方向上的辐亮度。BRDF定义fr=dLo/dE，故

    Lo(wo) = ∫hemisphere fr(wi,wo) Li(wi) cos(theta_s) dωi

Lambert假设fr为常量k。让材料反射总入射能量的比例是rho，出射积分需要满足

    ∫hemisphere k cos(theta_o) dωo = rho
    dω = sin(theta) dtheta dphi
    ∫0^(2π)∫0^(π/2) cos(theta) sin(theta) dtheta dphi = π
    kπ = rho ⇒ fr = rho/π

rho没有单位，是反射比例；fr是每单位立体角的响应。不能把rho本身当BRDF，少除π会使归一化错误。

## 3. 面积为何变成立体角

从x连向灯面点q，定义delta=q-x，r=|delta|，wi=delta/r。

    cs=max(n·wi,0)
    cl=max(nL·(-wi),0)

wi从受光点朝灯，-wi从灯朝受光点；两个余弦来自两个不同表面。不要用abs使单面灯背面发光。

先把灯面微元dA投影到垂直连线的平面，得到cl*dA；再缩到单位球，面积缩小r²倍。因此

    dω = cl/r² dA

立体角是方向范围的面积度量；dω不是二维角度dtheta*dphi。得到面积形式的直接光：

    Lo = ∫A V(x,q) Le (rho/π) cs cl/r² dA

V是0或1的可见性。r^-2已经由灯面到方向范围的几何关系产生；真空中的辐亮度Le本身不再单独做距离衰减。

## 4. 从均匀面积采样到NEE估计式

两维均匀随机数xi∈[0,1)²，仿射映射

    q = c + (2xi.x-1) U + (2xi.y-1) V

单位方形被拉伸为4平方米矩形，因此pA=1/A=1/4，单位m^-2。

对G(q)=V Le (rho/π) cs cl/r²，有E[G(q)/pA(q)]=∫A G(q)dA。于是

    Lo_hat = (1/N) Σ V Le (rho/π) cs cl/(r² pA)

遮挡或背向的样本贡献0，仍占N；只除可见样本数估计的是条件平均，会错误增亮阴影。

如果shader接口统一用方向PDF，概率质量不变要求

    pω dω = pA dA ⇒ pω = pA r²/cl
    Lo_hat = (1/N) Σ V Le fr cs/pω

代码先判断cs/cl是否大于0，再除cl。面积形式与方向形式二选一，不能在pω版本再乘cl/r²。

三个“均匀/重要性”概念分清：

|策略|随机对象|相对于立体角的PDF|
|---|---|---|
|均匀半球|受光点周围方向|1/(2π)|
|余弦半球|受光点周围方向|cos(theta_s)/π|
|均匀矩形灯|灯面位置q|转换后r²/(A cl)，在灯所占方向范围内|

均匀半球不是theta和phi各自均匀：球面带面积含sin(theta)。均匀半球可以取z=cos(theta)=xi1、phi=2πxi2。余弦半球z的边缘PDF为2z，CDF=z²，所以z=sqrt(xi1)。重建方向为(sqrt(1-z²)cos(phi),sqrt(1-z²)sin(phi),z)，然后用局部切线基变换到n周围。

本节常规NEE直接选灯面位置，没有先做余弦半球采样。NEE的作用是主动连接已知光源，避免大量方向样本没有打中小灯。它不意味着估计器零方差，也不等于BRDF采样；灯内仍有距离、余弦和遮挡变化。理想连续均匀随机样本下估计式无偏；实际实现使用有限离散hash固定样本，以复现实验为目标，不宣称严格独立连续随机。

## 5. DXR阴影与完整调用约定

`dxr_direct_light.hlsli`第18行的estimate_direct输入x/n/wo均为世界空间，id查反射率，pixel是绝对像素线性编号，mode来自View.targetInfo.w。两个out float4的xyz分别是直接光和忽略遮挡的对照，w分别是通过余弦筛选且可见/仅通过筛选的样本比例；w不是按能量加权的透过率。

可见性测试从o=x+0.0001n出发，重新计算q-o和长度l，方向单位化，TMin=.001、TMax=l-.001。实际贡献仍用原始x。epsilon是本米制小场景补丁，不是大世界/任意比例的稳健射线偏移方案。

TraceRay的接口等价于以下模板（HLSL内建，不是C++宿主函数）：

```cpp
void TraceRay(RaytracingAccelerationStructure AccelerationStructure,
              uint RayFlags, uint InstanceInclusionMask,
              uint RayContributionToHitGroupIndex,
              uint MultiplierForGeometryContributionToHitGroupIndex,
              uint MissShaderIndex, RayDesc Ray, inout payload_t Payload);
```

本课调用：scene、FIRST_HIT|SKIP_CLOSEST_HIT、0xff、0、0、1、shadow、p。

- scene：TLAS；包含3个共享BLAS实例。
- flags：遇到已接受遮挡即可停止，并跳过ClosestHit。所有几何均opaque，不处理透明叶片或透射。
- mask=0xff：与实例8位mask相交后决定是否遍历该实例。
- contribution=0、geometryMultiplier=0：共享单条hit record；不是InstanceID。
- missIndex=1：调用第二个Miss，ShadowMiss；主射线用0。
- Ray：起点、单位方向、有限T区间。
- Payload：4B uint visible，初值0，仅Miss改1。命中后跳过ClosestHit，因此保持0。不能让4B阴影载荷进入解释116B主载荷的SurfaceHit。

SBT：RayGen偏移0，主Miss64，阴影Miss96，Hit128。光照Miss表size64/stride32。递归深度2，因为RayGen主TraceRay内部的ClosestHit又TraceRay阴影；64次依次调用不会把嵌套深度变成65，更不意味着间接反弹两次。

主payload由84B扩为116B，包含两份float4结果；输出record由128B扩为160B。两者不是同一结构。原先的128B View常量、256B槽步长、两槽512B上传分配保持原协议，targetInfo.w现在用于模式。

CPU持有Upload、AS、SBT、Default输出和Readback的COM引用直到对应GPU工作完成。GPU写UAV后以transition到COPY_SOURCE排序写入与CopyResource；CPU等本槽Fence后才能Map读回、覆写View槽或Reset allocator。8次提交加AS构建Fence最终9，完成后才能释放。Map不是等待机制。所有HRESULT、Fence超时/设备移除与Debug Layer消息均有检查，数值验证失败排空后返回非零；PFM写入失败也影响验收结果。

## 6. 白炉为什么有用、又不能证明什么

隔离测试强制整个入射半球Li=1、V=1，故Lo=(rho/π)∫cosθdω=rho。代码用余弦分布cosθ=sqrt(xi)，pω=cosθ/π，单样本fr*cosθ/pω=rho。

它检查BRDF归一化和权重组合，不发环境遮挡射线，不验证矩形灯PDF或一般方向采样器；由于被积函数与phi无关，此测试只计算cosθ而不构造完整方向。不要把白炉图当本场景开启天空光后的正确GI结果。

## 7. 实机验收与边界

2026-10-13：DXC lib_6_3成功；build.ps1默认sm_120构建成功；RTX5070/Tier1.1运行8组均PASS，Debug Layer 0 error/0 warning，Fence9/9，程序返回0。宿主.cu没有CUDA kernel，GPU渲染通过DXR/HLSL执行。

|组|对照|结果|
|---|---|---|
|1|64灯样本、有遮挡|RGB向量最大误差2.60781e-7；部分可见像素2414；最大通道值.421964|
|2|同样本、强制V=1|有阴影输出与open对照完全一致|
|3|仅翻转灯面法线|全黑，误差0|
|4|孤立白炉|相对rho的最大RGB向量误差4.12953e-8|
|5|rho=0|全黑，但几何可见性仍存在|
|6|Le加倍|逐像素输出恰为组1两倍；最大CPU误差5.21562e-7|
|7|1灯样本|最大CPU误差3.01505e-7；噪声显著|
|8|恢复组1|与组1逐像素相同，检查槽复用与固定样本|

各组逐像素可见样本数、有效样本数与CPU一致，invalid=0。注意输出保存的是计数比例和RGB总和，不是逐条阴影射线bitmask；不能把它说成逐样本逐条可见性已全量比对。

参考分两层：首先独立CPU相机射线+double三角形求交验证GPU命中数据；再将已验证的GPU位置/法线作为相同积分输入，用CPU double面积形式和独立三角形遮挡检测，与GPU float立体角形式比较。后半层不是从CPU独立位置端到端渲染，目的是隔离积分误差与轮廓不连续性。

默认不带lighting的原R.13.4 DXIL和宿主也重新编译/回归，8组PASS、Debug0/0、Fence9/9。

线性输出：dxr_lighting_direct_1.pfm等8张，RGB float32、little-endian、底部行优先。预览dxr_lighting_comparison.png裁掉视口外空区，各图统一曝光1、Reinhard L/(1+L)、sRGB编码。它只用于看图，数值验收在显示变换前。白炉背景线性值1经该预览变换后显示灰白，不能凭屏幕灰度否定白炉结果。

2026-10-14澄清：“曝光1”是曝光倍率E=1（相对基准0 EV），不是+1 EV。完整预览顺序为线性光照 → 曝光乘法E*L → Reinhard色调映射 → sRGB编码 → 8位量化。当前代码因倍率为1省略乘法；没有自动曝光。固定曝光乘法是线性的，可与平均交换；非线性色调映射和sRGB编码不能如此交换。详见同目录`R.13.6-像素采样与线性HDR累积.md`的显示链路澄清。

UE的Path Tracer会累积相机样本并支持丰富材质、光源及多次反弹。本课保留矩阵相机/AS/材质求值/可见性/线性辐亮度这条链路，刻意将灯参数、Lambert材质写死并带大量诊断输出，便于定位数学错误；不声称这是UE内部管线或完整路径追踪器。

## 8. 运行与练习

从仓库根目录，每一步成功后再运行下一步：

```powershell
& 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\dxc.exe' -T lib_6_3 -D ENABLE_DIRECT_LIGHT=1 -Fo learning/sandbox/d3d12/r13-renderer/dxr_lighting.dxil learning/sandbox/d3d12/r13-renderer/dxr_view.hlsl
.\learning\sandbox\build.ps1 .\learning\sandbox\d3d12\r13-renderer\dxr_view_pipeline.cu -NoRun
.\learning\sandbox\d3d12\r13-renderer\dxr_view_pipeline.exe .\learning\sandbox\d3d12\r13-renderer\dxr_lighting.dxil lighting
python learning/sandbox/d3d12/r13-renderer/dxr_lighting_preview.py
```

lighting参数必须与ENABLE_DIRECT_LIGHT=1的DXIL匹配。默认诊断版不加二者。Pillow脚本只格式化真实GPU读回结果。

自测：①为什么用pω后不能再乘cl/r²？②64个样本中只有16个可见，应除以64还是16？③Le加倍后线性输出加倍，PNG字节为什么未必加倍？

下一节R.13.6再加入像素内部采样、随帧变化的样本与线性HDR累积，区分像素积分误差、直接光积分误差、固定序列和统计收敛；R.13.7处理历史有效性，.8接窗口与显示。

## 参考

### 2026-10-14 自测答案与目录整理

1. `1/pOmega=cl/(pA*r²)`已经包含面积到立体角的转换，再乘`cl/r²`会重复计算。
2. 分母为64；遮挡样本贡献0，仍属于原积分的样本。除以16得到可见条件下的平均，通常会抹掉应有的遮挡损失。
3. 灯面样本积分固定命中点收到的直接光；像素抗锯齿需要改变像素内部的相机采样位置，使其覆盖不同几何表面或背景。固定像素中心无法估计这部分覆盖率。

D3D12/DXR与PT.1–5已按课节归档。当前程序在`learning/sandbox/d3d12/r13-renderer/`，结果在该目录`results/r13-04/`及`results/r13-05/`，参见目录README。重新构建并运行R.13.4/5、重新生成预览均通过；PT.2重新构建运行29项通过。R.11窗口程序因硬编码输出路径变化重新构建通过，本次未启动窗口做运行验收。

- [PBRT Area Lights](https://www.pbr-book.org/4ed/Light_Sources/Area_Lights)：面光源辐亮度、单面发光。
- [Microsoft TraceRay](https://learn.microsoft.com/en-us/windows/win32/direct3d12/traceray-function)：调用原型与参数。
- [Epic Path Tracer](https://dev.epicgames.com/documentation/en-us/unreal-engine/path-tracer-in-unreal-engine)：引擎路径追踪、样本累积与材质范围。
