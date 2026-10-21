# PT.11 第六小节：GI重连接与Jacobian推导

2026-10-21，CPU double两次散射参考。本节完成DI到GI的测度推导与数值验收，不实现完整ReSTIR GI生产流水线；UE源码对照与整章验收仍待继续。

[代码入口](../../sandbox/path_tracing/restir-di/README.md) · [原始统计](../../sandbox/path_tracing/restir-di/results/gi/statistics.csv)

## 前节答案

相机Z改变时须将当前世界点放到旧相机下预测深度，才能与旧深度比较同一几何量。遮挡板移动不改变灯候选身份，不含可见性的候选评分仍能复用，但最终贡献必须查询当前可见性。评分正下限只影响随机选择，不修改物理贡献，因而不会凭空给背面补光。

## 问题和假设

DI路径为相机->x->灯；GI的最小扩展为相机->x->y->灯，其中y不是发光面，而是反射入射光的次级表面。复用旧接收点xs的路径时，将第一段改接到xd，保留y和后面的路径。这个操作称为重连接。

NVIDIA官方[ReSTIR GI说明](https://github.com/NVIDIA-RTX/RTXDI/blob/main/Doc/RestirGI.md)将次级表面位置、朝向、发现该表面的方向PDF及其辐亮度作为输入。本文只借此明确接口角色，不声称复现SDK。论文入口：[ReSTIR GI](https://research.nvidia.com/publication/2021-06_restir-gi-path-resampling-real-time-path-tracing)。

本课：接收微表面朝+Z，rho_x=.7；次级面为z=2、[-1,1]^2、朝-Z的Lambert面，rho_y=.6；点灯位于(0,0,.5)，标量辐射强度8。只估计x->y->点灯的两次散射项，不计算x的直接光、环境或更长路径。接收点是局部微表面，不是无限遮挡平面；所有指定连接无遮挡。后缀解析值为：

    L_y = (.6/pi)*8*1.5 / (y.x²+y.y²+1.5²)^(3/2)

这是点灯照度乘Lambert BRDF，包含真实空间变化。Lambert出射辐亮度与出射方向无关，才能将同一个L_y用于xs和xd。任意光泽表面、镜面和折射链不满足这个简化条件。

## 从投影面积推导测度变换

次级面上小块dA投影到连接垂直方向，投影面积为cos(theta_y)*dA。距离r处单位球面上的面积为投影面积/r²，也就是立体角：

    dω_x = a_x(y)*dA
    a_x(y) = |n_y·(-ω_x)| / |y-x|²

这里余弦在次级面y处，不是接收点x处。接收面余弦属于方向域被积函数：

    Fω_x(y)=f_x(ω_x,ω_o)*L_y*cos(theta_x)

同一个dA，源/目标立体角分别为a_s*dA、a_d*dA。因此本课约定的Jacobian是：

    J = dω_d/dω_s = a_d/a_s
      = (cos_y,d / cos_y,s) * (r_s²/r_d²)

Jacobian是映射对积分测度的局部缩放。必须说明分子分母的方向，不能只记一个距离平方比。若目标在相同轴线上距离减半，同一小块表面张开的立体角扩大4倍，J=4；代码用此解析点检查倒数错误。

概率守恒要求q_d*dω_d=q_s*dω_s，于是q_d=q_s/J，反密度权重乘J。

源reservoir的W_s虽不能任意当成最终分布PDF的倒数，但仍满足相应加权期望恒等式。因此变换到目标方向域的权重为W_mapped=W_s*J，组候选合并权重为：

    w_group = t_d(y)*W_s*J*M_s

合并后仍用W_out=S_out/(M_out*t_d(selected))，最后乘Fω_d。J已经进入选择权重和归一化，最终输出不能再额外乘一次。

前提：本实验中每个源都覆盖同一整个次级面，y与源/目标方向一一对应，所有目标/提议正且有限，两个组大小4/12固定。来源随机相关不自动导致期望偏差，但会影响方差；支持域缺失、多对一映射和依赖样本的拒绝不能直接沿用这里的证明。

## 面积域为什么可以没有显式J

将积分写成次级面面积：F_A,d=Fω_d*a_d；源权重同步转换W_A,s=Wω_s/a_s。面积域里保留同一个y，映射为恒等，J_A=1。

合并权重：

    t_A,d*W_A,s*M_s
    = (tω_d*a_d)*(Wω_s/a_s)*M_s
    = tω_d*Wω_s*J*M_s

因此两种写法的候选选择和最终贡献都应一致；“直接删J”却保留原来的方向域F和W不会等价。这个等价依赖这里t_A=tω*a_d的选择，不能将任意独立定义的评分都说成逐次相同。

## 接口和代码

`gi_reconnection.h`复用现有Reservoir、V3与PCG，不改已有DI接口。Sample按值保存次级面世界位置与标量后缀辐亮度；法线固定-Z是几何约定，未重复保存。无场景指针、无GPU缓冲所有权。

```cpp
Reservoir Generate(V3 source, unsigned candidates, mis::Rng& rng);
void MergeMapped(Reservoir& destination, const Reservoir& source,
                 double target, double scale, double u);
```

Generate在面积4的次级面上均匀抽样，qA=1/4，转成源方向PDF qω=qA/a_s后调用Update；不是按BSDF抽样。source是接收点，candidates为固定组大小，rng是调用者拥有且会推进状态的随机数发生器。

MergeMapped的destination由当前CPU线程独占；source只读借用；target为目标测度下的评分；scale为新/旧测度之比；u是独立选择随机数。它复制source，令weightSum乘scale，保持selectedTarget不变，因而临时副本Normalization乘scale，再调用原Merge。副本仅用于当次合并，不作为一条重新生成的候选流历史保存。scale<=0或非有限在修改destination前拒绝，溢出也报错；共享Merge检查计数与权重。零J/无效映射在本课被当作不支持输入报错，不声称解决一般GI的退化路径。

所有计算同步发生在CPU；没有CUDA kernel、GPU资源状态或Fence。仅课程构建入口使用nvcc sm_120。测试程序捕获异常并返回非零，脚本检测构建与运行退出码。

## 验证与结果

源点(-.8,0,0)、(.5,-.2,0)，分别生成4/12个候选。目标x=(.6,.2,z)，z=0/.5/1，每点10万独立试验。直接面积16候选基线完整平均16个贡献，复用只输出一个最终样本；不是等昂贵评估成本，也不据此宣称加速。

独立面积中点求积512/256提供物理参考。486个位置以单位方向关于面坐标的中央差分切向量叉积，独立验证立体角面积缩放：最大J相对误差9.45262e-11；逆映射乘积和J=4锚点通过。方向域与面积域估计30万次逐次对比，最大绝对差2.77556e-16，全部M=16。

|目标z|参考|正确J|漏J|倒J|
|---|---:|---:|---:|---:|
|0|.073445145|.073470269|.073246758|.077005081|
|.5|.107173114|.107097331|.069216000|.049235603|
|1|.164017865|.164036133|.061371813|.029372480|

正确方法全部在6SE+求积容差内。6个错误对照中5个超过10SE；z=0漏J误差较小，不谎称6/6强检出。首轮使用6/6强检出条件失败，随后补充错误算法自身积分，证明机制而非靠放宽正确性阈值。

漏J的期望为sum_s(M_s/M)*∫Fω_d*a_s dA，倒J为sum_s(M_s/M)*∫Fω_d*a_s²/a_d dA。所有错误算法均值也通过各自错误期望的6SE检查。z=1漏J理论期望.061375075，与实测.061371813吻合，证实它在稳定地估计另一个积分。

z=1直接面积16方差.00103043、重连接方差.00582081；本节不宣称复用必然更低方差。错误漏J方差更小但均值错了，不能用平滑证明正确。

![Jacobian均值对比](../../sandbox/path_tracing/restir-di/results/gi/jacobian-comparison.png)

仓库根运行：

```powershell
& ./learning/sandbox/path_tracing/restir-di/verify_gi.ps1
python ./learning/sandbox/path_tracing/restir-di/plot_gi.py
```

结果在results/gi/，含构建/运行日志、checks.txt、statistics.csv和图。本节仅两次散射/固定Lambert后缀/无遮挡/公共完整支持域，未实现一般多反弹GI、GI时空屏幕流水线、specular shift或支持域校正。与前五节DI组合完成“先DI，再对照GI”的教学范围，仍需UE源码对照后审核整章。

自测：次级面余弦与接收面余弦分别进入哪里？权重乘J后为何不能在最终输出再乘J？漏J但结果很平滑为何仍可能错误？下节直接解答后继续。
