# PT.8 折射方向与全反射

2026-10-21。本节完成方向几何与CPU参考，未接入DXR透射材质，也未更新beta。
代码/复跑命令见[pt08-materials](../../sandbox/path_tracing/pt08-materials/README.md)，实测见[anchors.csv](../../sandbox/path_tracing/pt08-materials/results/refraction/anchors.csv)和[summary.txt](../../sandbox/path_tracing/pt08-materials/results/refraction/summary.txt)。

## 上节答案

1. d=(.6,0,-.8)，n=(0,0,1)：r=(.6,0,.8)，wo=-d=(-.6,0,.8)。
2. eventMass=1是唯一离散事件的概率，pdfOmega=0是连续部分密度。weight已经是完整吞吐量乘数，不用pdfOmega再除一次。
3. R×Le=(.16,.30,.25)。若再乘cos，斜视时会错误变暗；cos=.8时变成(.128,.24,.20)。

## 假设与折射率

仅讨论两个均匀、各向同性、无吸收介质的平滑界面，固定波长的几何光学；暂不处理色散、粗糙度、薄膜干涉和嵌套介质。
折射率eta=c/v；在本节忽略色散的模型中，v为介质中的光传播速度。空气近似1、玻璃示例设1.5，不把所有玻璃写死为同一值。
游戏类比：从一种移动速度区域进入另一种区域，连接固定起终点的最短时间路线通常不是直线。类比用于说明时间与距离的区别，物理基础采用费马驻时原理。

## 从驻值问题推出Snell定律

二维截面，界面z=0，A=(a,h_i)、B=(b,-h_t)，h_i/h_t>0，穿越点X=(x,0)。取a<x<b，折射率分别eta_i/eta_t。
两段长度li=sqrt((x-a)^2+h_i²)，lt=sqrt((b-x)^2+h_t²)。总时间T(x)=(eta_i li+eta_t lt)/c。
令导数为0：

`c T'(x)=eta_i (x-a)/li - eta_t (b-x)/lt=0`。

角度从法线量起，两个比值分别是sin(theta_i)、sin(theta_t)，得到

`eta_i sin(theta_i)=eta_t sin(theta_t)`。

这是Snell定律。费马原理一般说光程驻值，不保证任意系统全局最小；本节固定平面两段路径的T''>0，所以是唯一最小值。3D界面内任意切向移动都满足驻值，得到切向方向共线，射线与法线共面。

## 方向约定与向量求解

d为当前追踪射线指向交点的单位方向；n为朝向当前射线所在介质的单位法线，d·n<0。eta_i是当前介质折射率，eta_t是射线即将进入的介质折射率，q=eta_i/eta_t。
相机路径反向追踪也能用这套几何，因折射路径可逆；本节的i/t按追踪方向定义，不偷偷切换成光源传播方向。

设ci=-d·n=cos(theta_i)，切向分量d_parallel=d+ci*n。长度是sin(theta_i)。由共面性和Snell，透射方向的切向分量必须是t_parallel=q*d_parallel。
单位长度要求|t_parallel|²+|t_normal|²=1，故k=1-q²(1-ci²)。透射射线进入另一侧，法向分量取负根：t_normal=-sqrt(k)n。
合并得到

`t=q*d+(q*ci-sqrt(k))*n`。

先判定k再开根。q<1时切向分量缩短，向法线靠近；q>1时远离法线；q=1时t=d；正入射时不转向。方向向量规范化表达几何，不表示传播速度大小。

## 全反射与临界角

如果q*sin(theta_i)>1，Snell要求透射正弦大于1，没有实数传播方向，对应k<0。仅在eta_i>eta_t时可能出现。
边界sin(theta_c)=eta_t/eta_i，所以玻璃1.5→空气1的临界角theta_c=asin(2/3)=41.8103148958°。
k=0时透射方向趋于切向；本课接口不返回穿越界面的透射射线。把k<0的严格全反射与k=0的临界极限区分清楚，再在接口里统一命名NoTransmission。
无吸收理想界面全反射时能量走反射分支，不应当把路径直接置黑。临界角以下也通常同时存在反射和透射；存在透射解不代表100%透射。能量比例下一节用Fresnel处理。完整波动理论允许另一侧的倏逝场，本节没有传播透射射线的说法不等于电磁场处处为零。

## 外向法线与介质选择

ng为几何外向法线，固定从物体内部指向外部。不要用法线贴图扰动后的着色法线决定介质内外。

| 条件 | 路径方向 | n | eta_i | eta_t |
|---|---|---|---|---|
| d·ng<0 | 进入物体 | ng | etaOutside | etaInside |
| d·ng>0 | 离开物体 | -ng | etaInside | etaOutside |

只翻法线但不交换IOR，会错误地抹掉玻璃离开空气时的全反射。d·ng=0时射线沿界面，单靠该判定无法确定来源侧；本节返回Invalid，上层应有当前介质状态。更一般的水中玻璃、嵌套物体需保存介质关系，不足以用永远固定空气的一个bool概括。

## 接口、输入、结果与失败路径

源码[refraction_math.h](../../sandbox/path_tracing/pt08-materials/refraction_math.h)：

```cpp
Result RefractBoundary(V d, V outward, float etaOutside, float etaInside);
```

V为三个float；输入按值。d和outward必须有限且近似单位，长度平方偏离1超过1e-4拒绝；小残差在内部归一化。IOR必须有限且大于0，计算溢出也返回Invalid。
Result包含direction、当前朝向normal、etaIncident、etaTransmitted、ratio、k、entering和Status。它是CPU按值返回结构，没有GPU ABI/stride保证，没有动态分配和同步。

- Transmitted：direction为有效透射方向；本节方向数学尚不提供BSDF权重。
- NoTransmission：k<=0，无穿越界面的透射方向，direction保留零；不能归一化零向量或交给TraceRay。
- Invalid：坏输入、切向来源不确定或数值溢出；不能当作物理全反射默默处理。

核心更新：先算sin²_t与k，若k<=0返回，再sqrt(k)。不能用sqrt(max(k,0))掩盖全反射而伪造一条切向射线。
HLSL的float3实例化使用`float3 refract(float3 incident,float3 normal,float etaRatio)`。此方向约定下传入d、朝当前介质的n、eta_i/eta_t；它不替你推断内外介质。全反射返回零向量。我们这次没有执行HLSL intrinsic，只验证自写CPU公式；不要把两者说成已做GPU逐值对照。
PBRT第4版Refract使用朝外方向和与本节倒数关系的IOR约定，读公式必须先转换变量。官方资料：[Microsoft refract](https://learn.microsoft.com/en-us/windows/win32/direct3dhlsl/dx-graphics-hlsl-refract)、[PBRT §9.3](https://www.pbr-book.org/4ed/Reflection_Models/Specular_Reflection_and_Transmission)。

## 本机验收

用build.ps1/nvcc sm_120构建，但程序只有CPU执行，无CUDA kernel、无DXR射线或Fence。本节仍沿用PT.8目录，未修改上一节DXR镜面后端。
独立double参考先atan2求入射角，再asin求透射角、在入射平面重建方向；不复用被测float公式。覆盖9个法线方向、4组IOR、进出两侧、0至89.5度半度步进，再加9个锚点。

| 场景 | 入射角 | 结果 |
|---|---:|---|
| 空气→玻璃 |0°|透射0°，t=(0,0,-1)|
| 空气→玻璃 |30°|透射19.4712211°，t≈(.3333333,0,-.9428090)|
| 空气→玻璃 |60°|透射35.2643902°|
| 玻璃→空气 |30°|透射48.5903787°，t≈(.75,0,.6614378)|
| 玻璃→空气 |45°|k≈-.12499988，无透射|
| 相同IOR |60°|仍为60°|
| 玻璃→空气 |临界角-.001°|透射89.6417269°|
| 玻璃→空气 |临界角+.001°|无透射|

12969组中Transmitted10869、NoTransmission2100；10869次反向追踪验证-t经过同一界面后得到-d；6类非法输入拒绝。
最大方向误差1.64926936394e-6，最大单位长度残差3.91236785191e-7，最大Snell残差2.5125828218e-7，最大反向误差1.93334307114e-5，均通过设定阈值。反向误差在接近临界角时更敏感，不能把一个固定机器精度等同于所有角度的方向误差。

额外费马验证：A=(-1,+1)，B=(+1,-1)，两侧IOR1和1.5，独立二分T'(x)得到X横坐标.362650205535；从A到X的入射方向经折射与X到B方向误差2.88605970266e-8。

唯一显式理论临界角样本量化成float后，k=-1.19209289551e-7；记录为边界诊断，不要求与理想实数临界分类相同。其余12968组正常分类全部通过。未把未知临界误差简单clamp为“成功透射”。

## 与完整玻璃材质的边界

常见引擎的实际材质还要判断反射/透射事件、Fresnel能量、传输模式权重、吸收和介质状态；实时屏幕空间折射也可能只偏移颜色查询，并非追踪穿过物体的光路。本节方向规律适用于几何折射，但不能代表那些完整渲染路径。
折射改变方向束的立体角，辐亮度传输权重会出现折射率比的平方项；不能直接照搬上一节beta*=R或把所有透射当weight=1。该项连同Fresnel分支概率在下一小节推导。[PBRT Dielectric BSDF](https://pbr-book.org/4ed/Reflection_Models/Dielectric_BSDF)。

## 自测

1. 空气1→玻璃1.5，以30°入射，透射角是多少，靠近还是远离法线？
2. 玻璃1.5→空气1，以45°入射，为什么不存在透射方向？此时应走哪条分支？
3. 离开物体时只翻法线、仍用1/1.5作q，会产生什么错误？

下一节：Fresnel反射率、反射/透射离散抽样，以及透射路径权重。PT.8继续进行中。
