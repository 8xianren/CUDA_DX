# PT.8 Fresnel与透射路径权重

2026-10-21。完成CPU平滑介质界面采样参考，未完成GPU玻璃集成。代码与命令见[pt08-materials](../../sandbox/path_tracing/pt08-materials/README.md)，结果见[sampling.csv](../../sandbox/path_tracing/pt08-materials/results/dielectric/sampling.csv)。

## 上节答案

空气1→玻璃1.5、入射30°：theta_t=asin((1/1.5)sin30°)=19.4712°，靠近法线。
玻璃1.5→空气1、入射45°：sin(theta_t)=1.5/sqrt(2)>1，没有传播透射方向，应走反射。
离开物体只翻法线而不交换IOR，会错误使用q=1/1.5而非1.5，弯折方向错误并漏掉全反射。

## 本节模型与要解决的问题

同一平滑玻璃界面既能反射又能透射。方向由上节决定；还需求两部分功率、选择一条路径继续、保证估计量不因随机分支改变期望。
假设无吸收、非磁、各向同性、固定波长的平滑介质。采用非偏振标量渲染；真实多次反射会改变偏振状态，本课不追踪它。Fresnel在本模型下是界面功率反射率，不等于抽样概率，也不直接等于beta乘数。

## 从界面边界条件求Fresnel

光是电磁波。入射方向与法线组成入射平面；s偏振的电场垂直此平面，p偏振的电场在此平面内。偏振是电场振动方向，和RGB通道不是一回事。
对无自由表面电流的界面，切向电场与切向磁场连续。把入射切向电场振幅归一化为1，同一切向基底的反射/透射振幅记r、a：

`1+r=a`，`Y_i(1-r)=Y_t*a`。

Y是切向磁场/电场的波导纳，表示两者比例。非磁介质平面波中|H|/|E|正比eta；投影后，省略两侧公共常数，s偏振Y_s=eta*cos(theta)，p偏振Y_p=eta/cos(theta)。反射波传播方向反转，使第二式中的r带负号。
消元得到`r=(Y_i-Y_t)/(Y_i+Y_t)`，`a=2Y_i/(Y_i+Y_t)`。
设ci=cos(theta_i)、ct=cos(theta_t)，代入两种Y：

`r_s=(eta_i*ci-eta_t*ct)/(eta_i*ci+eta_t*ct)`；
`r_p=(eta_i*ct-eta_t*ci)/(eta_i*ct+eta_t*ci)`。

p式采用同一界面切向E基底，符号可与其他教材的反射基底相反；功率用平方，结果相同。反射光与入射光在同一介质、角度相等，功率比R_s=r_s²、R_p=r_p²。
非偏振入射两种偏振各占一半功率，因此`F=(R_s+R_p)/2`，不能先平均振幅再平方。
透射功率不是简单a²，而是`T=(Y_t/Y_i)*a²`。代入上式可证R+T=1；本节无吸收，所以非偏振透射功率为1-F。
全反射时振幅有复数相位，两个偏振的功率反射率都为1；CPU实现不存储该相位，直接返回F=1。

正入射ci=ct=1，得到`F0=((eta_i-eta_t)/(eta_i+eta_t))²`。空气/玻璃示例F0=.04，意味着界面正常入射仍反射4%功率。两侧IOR相同时F=0。不同IOR的掠射极限F→1。
参考：[MIT 电磁波与界面](https://ocw.mit.edu/courses/6-974-fundamentals-of-photonics-quantum-electronics-spring-2006/fafcb9e36b7749f4eeb099d666bdf70a_electr_wav_inter.pdf)、[PBRT §9.3](https://www.pbr-book.org/4ed/Reflection_Models/Specular_Reflection_and_Transmission)。

## 为什么相机路径透射有q²

沿用上节：i是当前相机路径所在介质，t是继续追踪的介质；q=eta_i/eta_t。几何追踪从i到t，但递归查询的辐亮度从t侧传回i侧。这个方向区分决定比值的方向。
对Snell定律微分：eta_i*cos(theta_i)dtheta_i=eta_t*cos(theta_t)dtheta_t。方位角保持，立体角domega=sin(theta)dtheta*dphi，结合sin(theta_t)=q*sin(theta_i)得

`domega_t=q²*(ci/ct)*domega_i`，即`eta_i²*ci*domega_i=eta_t²*ct*domega_t`。

该Jacobian是两个方向域之间的面积缩放。界面面积dA相同，来自t侧的光经过界面到达i侧，其通量满足：

`L_i*ci*dA*domega_i=(1-F)*L_t*ct*dA*domega_t`。

代入Jacobian：`L_i=(1-F)*q²*L_t`。
因此确定性两分支目标为`C=F*L_r+(1-F)*q²*L_t`。本节指相机路径的Radiance模式，不直接套用到光源正向通量/Importance传输模式。
q²不是吸收。空气进入玻璃的相机路径q²=4/9；离开时q²=9/4。辐亮度按投影面积和立体角定义，单纯数值增大不代表总功率增加；上面的通量方程仍守恒。
参考：[PBRT Dielectric BSDF](https://pbr-book.org/4ed/Reflection_Models/Dielectric_BSDF)。

## 离散抽样与吞吐量

反射分支概率pr、透射pt=1-pr。为使估计量期望等于C，应返回：

反射：`weight=F/pr`；透射：`weight=(1-F)*q²/pt`。

证明直接展开期望：`pr*(F/pr)*Lr+pt*((1-F)*q²/pt)*Lt=C`。
选择pr=F时，反射weight=1、透射weight=q²。F已经体现在路径出现的频率里，不能再乘F或1-F，否则得到平方系数而错误变暗。选择pr=.5也可以无偏，但两侧都非零才这么选；F0/F1时零贡献分支直接移除。
纯平滑介质只有离散反射/透射事件，连续pdfOmega为0。后续命中发光面保留delta规则，发光MIS权重1；eventMass不与普通NEE的连续PDF直接比较。更新beta只乘Sample.weight一次。
pr=F并非对所有光照方差最优；最优分配还与两个方向的未知后续辐亮度及q²有关。本次80度用例中，半半抽样反而比Fresnel抽样标准误更低，不能删掉该结果。

## 接口与运行契约

实现[dielectric_math.h](../../sandbox/path_tracing/pt08-materials/dielectric_math.h)：

- `Fresnel Evaluate(double cosI,double etaI,double etaT)`：cosI∈[0,1]，IOR正且有限；返回F、非全反射时的实数rs/rp、cosT、valid/tir。tir字段包含临界切向极限。两个IOR相等单独处理，避免掠射0/0。全反射时rs/rp不表示复数振幅，CSV的Rs/Rp明确写1。
- `Interface Prepare(V d,V ng,float outside,float inside)`：复用上节RefractBoundary做float方向与内外判定，返回两方向、F、q²、valid。临界分类优先服从几何函数，避免选择不存在的透射方向。
- `Sample Draw(const Interface&,double u,Choice)`：u有限且[0,1)，Choice=Fresnel或Half；返回方向、Event、eventMass、完整weight、RR用rrEtaScale。Invalid必须上层报错，不能当作吸收或全反射。

结构均为CPU值，没有GPU ABI/布局保证、动态资源或Fence；RNG由调用者拥有，结果按值拥有。Prepare每个界面一次，Draw每次路径采样一次。RGB积分器会把标量weight同时乘到三个通道；有色吸收/色散未加入。

## 与RR对接

实际beta必须保留q²，计算L仍用该beta；RR若仅看beta，会把进玻璃的4/9缩放误当作强衰减，导致过早终止、方差增加。只要正确补偿，原RR仍可保持期望，这里主要是效率问题。
另存etaScale，初始1，每次透射乘1/q²，反射不变；用beta*etaScale估计RR生存概率，实际beta和L不乘这个修正。Sample.rrEtaScale就是单事件的更新乘数。
完整进出同种外部介质的两次透射：q_enter²*q_exit²=1。它只表示折射率坐标缩放相消，不表示整块玻璃100%透光；Fresnel分支发生概率和可能的吸收仍存在。

## 本机数值验证

纯CPU，统一nvcc/sm_120构建；无GPU Dispatch。
1800组双向角度：0至89.9度，每.1度；通过独立切向场边界方程求幅度、检查功率守恒；正入射F=.04、同IOR F=0、掠射F=1、Brewster角56.309932474°时rp=0通过。
最大边界方程残差2.48689957516e-14，最大R+T-1残差5.55111512313e-16。
Snell映射小角环带，精确积分两侧投影立体角，Jacobian最大相对误差2.79716483661e-12；通量方程通过。

Monte Carlo设后续两个方向Lr=2、Lt=3，六种界面各两种采样策略，每组262144样本，总3145728。无几何求交，不称玻璃渲染图。所有均值在6SE+数值容差内，分支频率也通过。

| 用例/策略 | 正确均值 | 标准误SE | 解析目标 |
|---|---:|---:|---:|
| 空气→玻璃正视/Fresnel |1.35963948568|.000253496405289|1.36|
| 空气→玻璃正视/半半 |1.36151977539|.0023437525907|1.36|
| 空气→玻璃80度/Fresnel |1.59078979492|.000633951441003|1.59180288208|
| 空气→玻璃80度/半半 |1.59185478949|.0000800500681234|1.59180288208|
| 玻璃→空气30度/Fresnel |6.49081420898|.00210716724128|6.48784667816|
| 玻璃→空气45度全反射 |2|0|2|
| 同IOR |3|0|3|

正视解析：C=.04*2+.96*(4/9)*3=1.36。
反例1在已正确除概率的weight上再乘F/1-F，实测1.23264892578，错误期望1.232。
反例2漏q²，实测2.96054077148，错误期望2.96。
两次透射weight乘积1、RR etaScale乘积1；TIR只反射、同IOR只透射、非法RNG拒绝，PASS。

## 生产对照与下一节

本课是平滑、无色、非偏振标量介质，工程引擎还需要粗糙度、混合lobes、吸收、纹理、介质管理；实时屏幕空间折射并不等于本课的路径积分。金属有复折射率，不用此玻璃公式替代金属Fresnel。
下一节将本节采样契约接入共享DXR后端，验证真实反射/透射路径及发光贡献；GPU玻璃、GGX、完整glTF映射尚未完成。

自测：1. 空气→玻璃正入射按F抽样，F/pr与透射weight各是多少？为什么不能再乘.04/.96？
2. 玻璃→空气透射weight=2.25为什么不违背能量守恒？
3. beta因进玻璃乘4/9后，etaScale如何更新？能否把beta*etaScale用于实际L？
