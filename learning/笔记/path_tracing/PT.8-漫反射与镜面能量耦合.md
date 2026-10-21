# PT.8 漫反射与镜面能量耦合

2026-10-21。上一节GPU白炉复现了基线材质增加能量的问题。本节推导一个同时满足能量预算与互易性的近似闭合模型，实现CPU double参考与独立验收。**尚未替换GPU材质，也未完成PT.8。**

代码与命令：[pt08-materials](../../sandbox/path_tracing/pt08-materials/README.md)。上一节：[glTF材质与GPU混合采样](PT.8-glTF材质与GPU混合采样.md)。共享GPU主线：[dxr-path-tracer](../../sandbox/path_tracing/dxr-path-tracer/README.md)。

## 先解答上一节自测

1. metallic=.5不是要求采样镜面分支概率ps=.5。metallic属于材质定义，ps属于估计器；改变ps必须相应改变PDF。
2. 即使选中了GGX分支，整BRDF估计器仍要计算余弦分支的PDF，使用边缘混合密度ps*pGGX+(1-ps)*pCos。
3. CPU和GPU一致只能证明两者对同一公式的实现一致；公式本身可能增加能量。1.26866白炉反例就是这种情况。

## 从需要满足的约束开始

想象两个系统共享一笔预算：表面镜面反射先使用一部分，颜料/内部散射再决定剩余部分中有多少能够返回。这个类比的关键是“同一笔入射预算”，而不是为两个分量各准备一份完整入射能量。

局部坐标n=+Z，wo和wi都离开表面，co=n·wo、ci=n·wi均为正。无发光、无透射的材质在单位白色环境中输出为

\[
E(\omega_o)=\int_{\Omega^+}f(\omega_o,\omega_i)c_i\,d\omega_i.
\]

E称为方向反照率：固定一个观察方向，对整个入射半球的BRDF响应积分。f单位是sr^-1，乘cos和立体角后E无量纲。对互易反射模型，也可把它解释为交换路径方向后的方向入射总反射率。

本节要求：非负；不主动增加能量；白色无吸收非金属输出1；互易性f(wo,wi)=f(wi,wo)。这是针对我们约定的近似模型的约束，不声称这些条件唯一决定真实分层材料的完整散射。

旧基线非金属项是

\[
f_{old}=f_s+[1-F(\omega_o\cdot h)]B/\pi.
\]

这里F是单个半角对应的Fresnel，镜面总反射却要经过DG与所有wi的积分。两者没有构成“一个积分用了多少，另一个恰好用剩余多少”的恒等式。因此每个方向都有1-F，并不能证明积分守恒。

## 先定义镜面已经使用的能量

继续使用前课各向同性GGX、alpha=roughness²、Smith高度相关G、F0=.04的Schlick介质镜面分量fs。定义

\[
E_s(\omega_o)=\int f_s(\omega_o,\omega_i)c_i\,d\omega_i,
\qquad R(\omega)=1-E_s(\omega).
\]

各向同性使E只依赖方向余弦c与roughness，不依赖方位角。B在本模型中表示剩余能量返回的RGB比例，每通道在[0,1]。期望漫反射积分为B*R(wo)。

最直接的形式B*R(wo)/pi可满足这个积分，因为半球cos积分是pi，但交换wo/wi后一般不相等。实测单侧形式的最大互易性差约.289752 sr^-1。能量守恒和互易性是两个不同约束。

## 解出双侧归一化因子

选择一个可分离、对称的近似形式

\[
f_d(\omega_o,\omega_i)=K B R(\omega_o)R(\omega_i).
\]

“可分离”是建模假设：两个方向的影响以乘积表达，不含额外方位关系。把它代入要求的积分：

\[
KB R(\omega_o)\int R(\omega_i)c_i\,d\omega_i=B R(\omega_o).
\]

定义余弦加权平均方向反照率

\[
\bar E_s=\frac1\pi\int E_s(\omega)c\,d\omega
=2\int_0^1 E_s(c)c\,dc.
\]

它不是对角度的简单算术平均，2c来自半球积分测度和归一化。于是

\[
\int R(\omega)c\,d\omega=\pi(1-\bar E_s),
\quad K=\frac1{\pi(1-\bar E_s)}.
\]

最终得到

\[
\boxed{f_d=\frac{B[1-E_s(\omega_o)][1-E_s(\omega_i)]}{\pi(1-\bar E_s)}}.
\]

如果漏掉1/(1-Eavg)，双侧因子会重复减少能量；仅加入对称项还不够，必须完成归一化。总非金属方向反照率变成

\[
E_{dielectric}=E_s+B(1-E_s).
\]

B=1时恒为1；B=0时只剩镜面；每通道B∈[0,1]时不超过1。双侧乘积保证互易性。我们不把最终颜色clamp到1：那是非线性截断，会掩盖模型问题且通常使估计器有偏。

这一结构与[OpenPBR规范Glossy-diffuse部分](https://academysoftwarefoundation.github.io/OpenPBR/index.html)讨论的互易albedo-scaling形式一致；也可直接查看[完整规范](https://academysoftwarefoundation.github.io/OpenPBR/index.html)的Glossy-diffuse段落。本节明确使用自己的单次GGX镜面和Lambert剩余能量闭合，不是完整OpenPBR实现，不模拟真实层间折射、吸收和无限次内部反射。

## 金属、delta与采样

金属仍保留前课单次微表面镜面分量，F0=B；非金属用上式，再按metallic作凸组合：

\[
f=(1-m)(f_{s,d}+f_d)+m f_{s,m}.
\]

因此漫反射整体乘1-m；由于Schlick对F0线性，镜面仍可用F0mix=(1-m).04+mB。只要两个分量均不增能，凸组合也不增能。单次GGX金属的微面多次散射仍被省略，因此高粗糙度金属偏暗并没有被本次非金属修正解决。

delta区alpha<=1e-4保留显式离散事件。此时

\[
E_s(c)=.04+.96(1-c)^5,
\quad \bar E_s=.04+2(.96)\int_0^1 c(1-c)^5dc
=.04+.96/21=3/35.
\]

积分c(1-c)^5等于1/42，可令x=1-c后积分x^5-x^6得到。delta不能硬塞进连续BRDF积分；实验把离散镜面质量单独加回。

改变BRDF不会自动改变我们已有的采样分布：连续事件仍使用ps*pGGX+(1-ps)*ci/pi，权重为f*ci/pdf。镜面delta事件使用离散概率ps，权重F/ps。null微面反射样本继续记为0并计入总数。这里余弦采样仍无偏，但不完全匹配新的R(wi)*ci分布；是否值得增加专用采样器是方差/成本问题，不是此次守恒成立的必要条件。

## 实现、布局与失败路径

- `energy_quadrature.h:10`：`Basis Integrate(double roughness,double co,unsigned order)`。前两参数指定镜面粗糙度和方向余弦；order为两个Gauss-Legendre积分轴的阶数。固定wo在XZ平面，利用方位对称性积分phi∈[0,pi]再乘2；对ci∈[0,1]积分，dω=dphi*dci。返回两个double：scale积分F=1，schlick积分(1-wo·h)^5，因此任意F0可线性重组。该积分不调用路径Draw、BRDF Eval或查表。
- `energy_quadrature.h:31`：`Reference Converged(double roughness,double co)`从128阶细化到最多2048阶，两个积分基的相邻差低于2e-7才接受；非法参数或未收敛抛异常。有限阶相邻一致不是数学上的全局误差证明。delta走解析结果。
- `energy_balance.h:10`：`Row`拥有roughness、average和vector<double> values。每行257个能量值，节点余弦c_j=(j/256)^2；这里没有可上传的GPU ABI，也不做roughness维插值。表含c=0极限和c=1端点。
- `Row::At(double cosine)`用sqrt(c)定位区间，但在实际c坐标上线性插值。平方节点给掠射端更多分辨率；初版均匀c节点未通过1e-4表外误差门槛，因此更换节点布局，未放松门槛。delta直接使用解析函数。
- `Row::Normalize()`对实际分段线性函数精确计算2∫E(c)c dc。每段E=E0+dt，c=c0+ht，贡献为2h[E0c0+(E0h+dc0)/2+dh/3]。不能使用一份与实际插值函数不一致的average。数据非有限、越界、缺失或average≥1时抛异常。
- `energy_balance.h:36`：`pbr::Evaluation Eval(pbr::Material material,V wo,V wi,unsigned mode,const Row& row)`。material传RGB B、metallic、roughness；wo/wi按前课单位局部方向约定；mode选择ps=.5或.8（无漫反射时ps=1）；row只读且必须与材质roughness匹配。返回原有f/diffuse/specular/pdf/specPdf/diffPdf，镜面和PDF沿用前课，仅替换diffuse。
- `energy_test.cpp:21` Draw保留连续/离散测度分支，所有权都在调用栈，不持有GPU资源；`:29` Integral用另一种phi中点规则直接积完整BRDF，检验推导预测而非用查表自证；`:57`五个std::async任务各自产生一行，future.get同步并传播异常，文件仅由主线程写入。无D3D12 Fence、CUDA stream或GPU提交。

对co=0的积分端点，直接计算G/(4co)会遇到0/0；先代数化简成

\[
\frac{G}{4c_o}=\frac1{2[\sqrt{c_o^2+\alpha^2(1-c_o^2)}+
c_o\sqrt{c_i^2+\alpha^2(1-c_i^2)}/c_i]}
\]

再取极限，避免把数值异常用clamp掩盖。实际BRDF Eval仍要求上半球方向，co=0只供构表端点。

## 查表误差会怎样进入白炉

设表函数为Etilde，average也由这个函数计算。漫反射积分精确为B(1-Etilde_o)，但镜面仍是原始GGX，所以白色非金属的实际输出是

\[
E_s+1-\tilde E_s=1+(E_s-\tilde E_s).
\]

这是很有用的误差传播关系：它告诉我们不能只把理论公式证明一次，就声称任何粗糙查表都守恒。插值误差会直接变成白炉偏差。本节检查五条roughness曲线，每条64个未参与构表的半格点；有限检查不代表整个连续参数域已有严格误差界。下一节必须继续处理GPU float、roughness插值及窄高光。

## 命令与本机结果

仓库根目录运行，脚本按自身路径定位，可从其他工作目录调用：

```powershell
.\learning\sandbox\path_tracing\pt08-materials\verify_energy.ps1
python .\learning\sandbox\path_tracing\pt08-materials\plot_energy.py
```

CMake/VS2022 Release纯CPU构建，不链接DXR资源库，不调用CUDA。exe为`learning/sandbox/path_tracing/pt08-materials/build/Release/energy_test.exe`，唯一命令行参数是结果目录。输出到该课`results/energy/`的energy.csv、furnace.csv、sampling.csv、summary.txt和构建/运行日志，绘图另写PNG/SVG。绘图沿用`results/ggx/plot_packages`隔离matplotlib；数值验收不需要Python依赖。

2026-10-21本机实际结果：

| 验收 | 结果 |
|---|---:|
| CPU混合采样 | 7,864,320，120组RGB均值均在6SE+1e-4内 |
| 构表 | 5行×257节点，r=0/.25/.5/.75/1 |
| 表外点 | 320，最大插值误差9.78188470616e-6 |
| 积分细化 | 最大相邻差1.83791628389e-7，最高2048阶 |
| 完整白炉 | 15个r/观察角组合，最大偏离1为1.154033762e-6 |
| 完整BRDF积分 vs 能量预测 | 最大差1.16248233262e-9 |
| 互易性 | 10,000对，最大差3.8369307731e-13 |
| 坏输入 | 4类拒绝 |
| 旧模型r=.25、80° | 1.26865688683708 |
| 修正模型同一条件 | .9999999579922 |
| 单侧剩余能量负对照 | 最大互易性差.289752337378 |

修正后的白色r=.25在0°/60°/80°分别为.999999999696/.999999403669/.999999957992。r=0的解析delta白炉也通过；有色非金属、metallic=.5混合与纯金属的两种采样策略通过参考均值验收。均值可能略高于1，这是有限样本噪声，不能因此逐样本截断。

![CPU能量耦合验证](../../sandbox/path_tracing/pt08-materials/results/energy/energy-balance.png)

引擎与生产材质通常会将这类积分预计算为表或拟合，并结合完整材质层、专用采样及多散射处理。OpenPBR规范本身讨论了能量缩放的近似性。本课保留显式积分以便审计，再做GPU压缩/查表；不能把五条CPU参考曲线称为通用生产材质，也没有承诺与UE某版本默认BRDF逐像素一致。

## 自测与后续

1. 为什么乘1-E(wo)可以满足能量预算，却不自动满足互易性？
2. 双侧剩余能量因子为什么还要除以1-Eavg？
3. 若E表的某个方向比真实镜面积分小.002，白色非金属输出会偏向哪个方向、偏多少？

依连续授课授权，下一节先给答案，然后继续GPU能量表和共享材质接入；PT.8保持进行中，随后按计划PT.10→PT.9→PT.11→PT.12。
