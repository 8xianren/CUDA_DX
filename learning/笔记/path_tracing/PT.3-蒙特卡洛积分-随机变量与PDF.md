# PT.3 蒙特卡洛积分、随机变量与 PDF：地基版

## 0. 为什么重讲这一节

上一版有几个容易造成根本误解的压缩说法，本版先纠正：

```text
错误的听法：每一个 f(X_i)/p(X_i) 都等于原积分。
正确的说法：每一个 f(X_i)/p(X_i) 是随机变量的一次实现；它的期望才等于原积分。

错误的听法：平均值方差永远是 Var(F)/N。
正确的说法：只有样本独立同分布时才能直接这样写；一般还要加协方差项。

错误的听法：分层只是“把随机点排开”。
正确的说法：分层改变了样本的联合分布；要用条件期望和全方差公式分析它。

错误的听法：Sobol 是更好的随机数。
正确的说法：Sobol 首先是确定性的低差异点集；Owen scrambling 才把它随机化，
             随机化后才能重新获得可用于无偏估计和误差条的随机重复。
```

本节仍然只讲采样和估计，不引入 BRDF、BVH 或 CUDA kernel。PT.4 才把它们接到 Lambert 路径权重。

可运行验收：

- `learning/sandbox/path_tracing/pt03-monte-carlo/pt3_monte_carlo.cu`

---

## 1. 先固定符号：三个 `f/F/p` 不要混

这一节最容易因为符号复用而混乱。这里固定约定：

```text
f(x)       被积函数。它是一个普通函数，不是随机变量。
p(x)       PDF，描述随机变量 X 在 x 附近出现的密度。
C(x)       CDF，累计分布函数：P(X ≤ x)。不用 F 作为 CDF，避免和单样本贡献混淆。
X          随机变量，表示“尚未抽出具体值的抽样过程”。
x          一次具体抽样结果，是 X 的实现。
Y          单样本贡献这个随机变量：Y = f(X)/p(X)。
y            一次具体贡献：y = f(x)/p(x)。
```

所以：

```text
Y 是随机变量
y 是一次运行中打印出来的一个数
E[Y] 是所有可能抽样结果的加权平均
```

如果写：


a\_i = f(X_i)/p(X_i)

这里的 `a_i` 是第 `i` 枪实际产生的一个随机数。它通常不等于积分；只有平均值在期望意义上等于积分。

---

## 2. 从“积分”到“期望”：为什么每一项的期望等于原积分

我们想计算：

\[
I=\int_\Omega f(x)\,d\mu(x)
\]

这里 `μ` 是积分测度：

```text
区间积分       dμ = dx
半球方向积分   dμ = dω
面积积分       dμ = dA
```

我们选择一个 PDF `p(x)`，它是相对于同一个测度 `μ` 的密度：

\[
\int_\Omega p(x)\,d\mu(x)=1
\]

随机变量 `X` 的概率分布由 `p` 定义。对任意函数 `g`，期望的定义是：

\[
E[g(X)] = \int_\Omega g(x)p(x)\,d\mu(x)
\]

现在令：

\[
g(x)=\frac{f(x)}{p(x)}
\]

代入期望定义：

\[
E\left[\frac{f(X)}{p(X)}\right]
=\int_\Omega \frac{f(x)}{p(x)}p(x)\,d\mu(x)
=\int_\Omega f(x)\,d\mu(x)
=I
\]

因此：

\[
E[Y]=I,\qquad Y=\frac{f(X)}{p(X)}
\]

### 2.1 这里“每一项都是原积分”到底是什么意思

不是说每一枪都等于 `I`。例如：

\[
I=\int_0^1x^2dx=\frac13
\]

均匀抽样时 `p(x)=1`。如果某一次抽到：

```text
x = 0.2
y = x² = 0.04
```

这一次贡献是 `0.04`，不是 `1/3`。

另一次抽到：

```text
x = 0.9
y = x² = 0.81
```

这一次贡献是 `0.81`，仍然不是 `1/3`。

只有把所有可能的抽样结果按照它们出现的概率加权：

\[
E[Y]=\frac13
\]

所以“每一项的期望等于原积分”应展开成：

\[
\boxed{E[f(X_i)/p(X_i)]=I}
\]

不是：

\[
f(X_i)/p(X_i)=I
\]

后者只有在特殊零方差采样时才成立，例如后面会看到的 `p(x)=3x²` 积分 `x²`。

### 2.2 N 个样本为什么平均

定义：

\[
\hat I_N=\frac1N\sum_{i=1}^{N}Y_i
\]

若每个 `Y_i` 都来自同一个 PDF，并且期望存在，则由期望的线性性：

\[
E[\hat I_N]
=E\left[\frac1N\sum_iY_i\right]
=\frac1N\sum_iE[Y_i]
=\frac1N\sum_i I
=I
\]

**这里不需要样本独立。** 无偏性只使用期望的线性性；样本独立性主要影响方差公式。

必须满足：

```text
1. f(x) ≠ 0 的区域不能有 p(x)=0；否则该区域永远抽不到。
2. 实际采样过程确实服从你写下来的 p。
3. p 使用的测度和积分一致：p(ω) 针对 dω，不能拿 p_A 直接代替。
```

---

## 3. PDF 不是概率：单位和测度

连续随机变量在一个无限小区域 `dx` 中的概率是：

\[
P(X\in[x,x+dx])\approx p(x)dx
\]

因此：

```text
p(x)       是密度
p(x)dx     才是这个小区域的概率
```

PDF 的单位是“概率 / 测度”：

```text
区间 x     [1/x]
面积 A     [1/m²]
方向 ω     [1/sr]
```

归一化是：

\[
\int_\Omega p(x)\,d\mu(x)=1
\]

半球均匀方向：

\[
p(\omega)=\frac1{2\pi},
\qquad
\int_{\Omega^+}\frac1{2\pi}d\omega=1
\]

余弦加权方向：

\[
p(\omega)=\frac{\cos\theta}{\pi},
\qquad
\int_{\Omega^+}\frac{\cos\theta}{\pi}d\omega=1
\]

这就是为什么 PT.1 的：

\[
\int_{\Omega^+}\cos\theta d\omega=\pi
\]

可以直接用来证明余弦 PDF 的归一化。

---

## 4. 逆变换采样：`X = C^{-1}(U)` 到底是什么意思

“逆变换采样”上一版只写了一句公式，没有讲清它在做什么。

### 4.1 CDF 的定义

对随机变量 `X`，CDF 定义为：

\[
C(x)=P(X\le x)
\]

它描述“从分布左端一直累积到 `x`，已经占了多少概率”。

例如 PDF：

\[
p(x)=2x,\qquad 0\le x\le1
\]

CDF 是 PDF 的积分：

\[
C(x)=\int_0^x2t\,dt=x^2
\]

于是：

```text
x=0.2   C(x)=0.04   只有 4% 的样本应该落在 [0,0.2]
x=0.5   C(x)=0.25   只有 25% 的样本应该落在 [0,0.5]
x=0.9   C(x)=0.81   81% 的样本应该落在 [0,0.9]
```

### 4.2 为什么 `X=sqrt(U)` 会产生 `p(x)=2x`

先抽：

\[
U\sim Uniform(0,1)
\]

再定义：

\[
X=\sqrt U
\]

要验证 X 的分布，直接算它的 CDF：

\[
P(X\le x)
=P(\sqrt U\le x)
=P(U\le x^2)
=x^2
\]

因为 `U` 在 `[0,1]` 上均匀，所以 `P(U≤a)=a`。

因此：

\[
C_X(x)=x^2
\]

对 CDF 求导：

\[
p_X(x)=C'_X(x)=2x
\]

这就证明了：

```text
U 均匀 + X=sqrt(U)
    ↓
X 的 PDF 是 2x
```

它不是“把随机数随便开平方”，而是一个确定的分布变换。

### 4.3 一般形式 `X=C^{-1}(U)`

如果目标分布的 CDF 是 `C(x)`，而且它可逆：

\[
X=C^{-1}(U),\qquad U\sim Uniform(0,1)
\]

则：

\[
P(X\le x)
=P(C^{-1}(U)\le x)
=P(U\le C(x))
=C(x)
\]

因此 X 的 CDF 正好是目标 `C(x)`。

这就是“逆变换采样”的含义：

```text
均匀随机数 U
    ↓ 用目标 CDF 的反函数映射
目标分布中的样本 X
```

不是逆矩阵，也不是把已有样本“逆回来”；这里的“逆”是 **inverse CDF**。

### 4.4 三个例子

```text
p(x)=1       C(x)=x       X=U
p(x)=2x      C(x)=x²      X=sqrt(U)
p(x)=3x²     C(x)=x³      X=cbrt(U)
```

如果 CDF 不能解析求逆，可以：

```text
离散表 / alias table
数值积分构造 CDF
二分查找 CDF^{-1}
拒绝采样、重要性重采样或其他方法
```

---

## 5. “理想目标 `p ∝ |f|`”中的符号是什么意思

这里的 `∝` 读作“正比于”：

\[
p(x)\propto |f(x)|
\]

意思不是 `p(x)=|f(x)|`，而是存在一个归一化常数 `K`：

\[
p(x)=K|f(x)|
\]

由 PDF 必须归一化：

\[
1=\int p(x)d\mu(x)
=K\int|f(x)|d\mu(x)
\]

所以：

\[
K=\frac1{\int|f(x)|d\mu(x)}
\]

最终：

\[
p^*(x)=\frac{|f(x)|}{\int|f(x)|d\mu(x)}
\]

这里的 `|f|` 是**绝对值**，不是内存地址，也不是“某种范数的省略写法”。
原因是 PDF 必须非负；即使 `f(x)` 有正有负，PDF 也不能为负。

### 5.1 为什么它是最理想的 PDF

单样本贡献：

\[
Y=\frac{f(X)}{p(X)}
\]

如果 `f≥0`，令：

\[
I=\int f(x)d\mu(x)
\]

那么理想 PDF 是：

\[
p(x)=\frac{f(x)}I
\]

于是：

\[
Y=\frac{f(x)}{f(x)/I}=I
\]

每个样本都等于答案，方差为 0。

如果 `f` 有正负号，`p∝|f|` 会让 `Y` 的大小接近常数，但符号仍由 `f` 保留；通常不能完全零方差。

严格地说，`p∝|f|` 是使单样本重要性采样方差最小的理想目标之一，前提是积分存在且能实现这种采样。

渲染里完整的：

\[
f(\omega)=f_rL_i\cos\theta V
\]

通常未知 `L_i`、可见性 `V`，所以不能直接使用完整理想 PDF，只能用近似：

```text
Lambert       p(ω) ≈ cosθ/π
小面积光源    p(ω) 让样本集中在光源方向
镜面高光      p(ω) 贴近高光瓣
```

---

## 6. 方差：上一版为什么不够严谨

### 6.1 单个样本的方差

令：

\[
Y=\frac{f(X)}{p(X)},\qquad E[Y]=I
\]

方差是：

\[
\operatorname{Var}(Y)=E[(Y-I)^2]
=E[Y^2]-I^2
\]

它描述一枪贡献有多分散。

### 6.2 多个样本的一般公式：必须包含协方差

估计量：

\[
\hat I_N=\frac1N\sum_{i=1}^NY_i
\]

一般情况下：

\[
\operatorname{Var}(\hat I_N)
=\frac1{N^2}
\left(
\sum_i\operatorname{Var}(Y_i)
+2\sum_{i<j}\operatorname{Cov}(Y_i,Y_j)
\right)
\]

这才是总公式。

只有在 `Y_i` 独立同分布时：

```text
Var(Y_i)=Var(Y)
Cov(Y_i,Y_j)=0
```

才得到熟悉的：

\[
\operatorname{Var}(\hat I_N)=\frac{\operatorname{Var}(Y)}N
\]

所以你说“采样逻辑不同，方差理解会偏”，是正确的。必须看样本生成机制：

```text
普通 i.i.d. Monte Carlo       独立同分布，Var/N 直接成立
分层采样                      通常独立但不一定同分布；应按 strata 方差计算
Latin hypercube / QMC         样本有结构，可能有相关性；不能套 Var/N
确定性 Sobol                  没有随机概率空间，严格说不能直接谈随机方差
随机化 Sobol/Owen             有随机化空间，可以谈方差，且可用多次 scramble 估计
```

### 6.3 分层采样的正确方差推导

把积分域分成互不重叠的 strata：

\[
\Omega=\bigcup_{j=1}^{M}S_j
\]

令第 `j` 个 strata 的测度为：

\[
w_j=\mu(S_j)
\]

为了讲清楚，先假设在每个 strata 内均匀采一个点：

\[
X_j\sim Uniform(S_j)
\]

定义第 `j` 个 strata 的条件均值：

\[
\mu_j=E[f(X_j)]
\]

以及条件方差：

\[
\sigma_j^2=Var(f(X_j))
\]

第 `j` 个 strata 的积分是：

\[
I_j=\int_{S_j}f(x)d\mu(x)=w_j\mu_j
\]

因此分层估计量是：

\[
\hat I_{strat}=\sum_{j=1}^{M}w_jf(X_j)
\]

它无偏：

\[
E[\hat I_{strat}]
=\sum_jw_jE[f(X_j)]
=\sum_jw_j\mu_j
=\sum_jI_j
=I
\]

如果各 strata 的抽样彼此独立，方差是：

\[
\operatorname{Var}(\hat I_{strat})
=\sum_{j=1}^{M}w_j^2\sigma_j^2
\]

注意这里不是 `Var(f)/M`。

### 6.4 为什么分层通常降方差：全方差公式

先把随机点 `X` 的 strata 编号记为 `J`。全方差公式：

\[
\operatorname{Var}(f(X))
=E[\operatorname{Var}(f(X)\mid J)]
+\operatorname{Var}(E[f(X)\mid J])
\]

两项分别表示：

```text
第一项：每个 strata 内部还有多少波动
第二项：不同 strata 的均值之间差多少
```

普通随机抽样既承受 strata 内波动，也承受“这次抽到了哪个 strata”的波动。
分层后每个 strata 都强制取样，第二种波动不再由抽样数量决定；因此对按 strata 等权的情形，
分层通常更稳定。

更精确地说：分层不是无条件保证每个函数都改善；它的收益依赖 strata 划分和函数在各 strata 内的变化。
好的 strata 让每个内部函数更平滑，坏的 strata 可能收益很小。

### 6.5 为什么当前代码里的 `se` 不能当分层误差条

当前程序把每个 strata 的 `f(X_j)` 都塞进一个普通样本方差，再除以 `N`。这是 i.i.d. 公式，
不是严格的分层方差估计。它可以作为“样本贡献的离散程度”诊断，但不能叫作分层估计量的标准误差。

正确做法有两个：

```text
方法 A：已知每个 strata 内的样本方差，使用 Σ w_j² s_j²/n_j
方法 B：用许多独立重复的整套分层设计，直接统计这些 run 的均值方差
```

本节以后比较采样器，统一采用方法 B：固定 `N`，生成很多独立 run，比较 run 均值的方差和均方误差。
这样不需要假装样本 i.i.d.。

---

## 7. Sobol：它不是“更好的 rand”

### 7.1 普通随机点和 Sobol 点的区别

普通 i.i.d. Monte Carlo：

```text
每个样本都由独立随机变量产生
样本可能扎堆，也可能留下大空洞
理论典型误差 O(N^{-1/2})
```

Sobol 是一种低差异（low-discrepancy）数字序列：

```text
第 0、1、2、... 个点不是独立随机点
它们被设计成在 [0,1)^d 中尽量均匀覆盖
```

“低差异”不是“每个点之间距离都一样”。它衡量的是：

> 任意轴对齐子区域中，实际点数与理想点数之间的最大偏差有多大。

点越均匀，discrepancy 越低。对足够光滑的被积函数，QMC 的误差经常比 `1/sqrt(N)` 快；经典理论常写成包含 `(log N)^d/N` 的界，但常数、维度、函数光滑性和边界不连续性决定实际效果，不能把它当普遍保证。

### 7.2 一维 Sobol 为什么像二进制反转

一维最简单的 Van der Corput / Sobol 直觉：

```text
整数 n 的二进制位反转，再放到小数点后
n=0  -> 0.000... = 0
n=1  -> 0.100... = 0.5
n=2  -> 0.010... = 0.25
n=3  -> 0.110... = 0.75
n=4  -> 0.001... = 0.125
```

前 4 个点是：

```text
0, 0.5, 0.25, 0.75
```

它不是随机的，但迅速填补大空洞；普通随机可能前 4 个点全在左半边。

多维 Sobol 不能简单让每个维度都使用同一组点，否则维度之间会强相关。每个维度使用不同的 direction numbers，构造不同的数字网格，同时保持低差异的投影性质。

### 7.3 Sobol 的缺点：确定性结构可能形成图案

确定性是优点，也是风险：

```text
优点：前 N 个点通常比纯随机均匀，低 SPP 可能更干净
风险：如果被积函数、相机、像素布局和序列结构发生相关，可能出现结构化伪影
风险：N 不合适、维度分配不好、路径中断分支复杂时，理论优势会下降
```

所以渲染器不会简单地把一个固定 Sobol 表永远重复使用。

---

## 8. Owen scrambling：怎么在保持结构的同时随机化 Sobol

### 8.1 scrambling 的目标

我们希望同时获得：

```text
Sobol 的低差异、少扎堆
随机化后的不同重复 run
平均意义上的无偏性
可以用多次重复估计误差/方差
```

Scrambling 就是对 Sobol 的数字位做受控随机置换，而不是给每个点加一个独立随机数。

### 8.2 Owen scrambling 的核心思想

把 `[0,1)` 写成二进制小数：

\[
x=0.b_1b_2b_3\ldots_2
\]

Owen scrambling 对每一层二进制前缀使用随机置换：

```text
第一位 b1：随机决定 0/1 是否交换
第二位 b2：根据前缀 b1 选择另一套随机交换
第三位 b3：根据前缀 b1b2 再选择另一套随机交换
继续递归
```

关键是：

```text
不是独立打乱每一位
而是根据已经走过的前缀选择条件置换
```

这样既能保持数字网格的覆盖结构，又把固定 Sobol 的可见模式打散。

完整 Owen scrambling 的理论版本是递归、逐 bit 的随机置换；GPU 上完整实现成本较高，所以工程中常用 hash-based 近似。它必须小心设计：随机化要保持每个数字位置的均匀性，否则可能降低视觉误差却引入偏差。

UE 的 `PathTracingRandomSequence.ush` 中明确提供：

```text
RANDSEQ_PURERANDOM = 0
RANDSEQ_OWENSOBOL = 1
RANDSEQ_LATTICE   = 2
```

默认是 `RANDSEQ_OWENSOBOL`。源码里的 `FastOwenScrambling(Index, Seed)` 先对索引做 hash-based 混合，再 reverse bits；注释也说明这是为了低成本模拟 Owen scrambling，不是把它当成普通 `rand()`。

UE 源码位置：

```text
C:\xf\engine\unreal\UnrealEngine\Engine\Shaders\Private\PathTracing\Utilities\PathTracingRandomSequence.ush
```

### 8.3 为什么随机化后可以谈无偏和方差

固定 Sobol 点集是确定性的：给定 N，估计值就是一个确定数。严格说没有一个随机实验空间，不能把普通 Monte Carlo 的 `Var/N` 直接套上去。

随机化 Sobol 后，每次 scramble 得到一套随机点：

```text
第 k 次 scramble → 一套 N 点 → 一个积分估计 I_k
重复 K 次 scramble → I_1,...,I_K
```

如果 scrambling 保证每个样本边际均匀，那么：

\[
E_{scramble}[I_k]=I
\]

因此 randomized QMC 对 scramble 随机性无偏；多次 scramble 的 run 均值方差可以作为误差诊断。

注意：这里的方差是“不同 scramble 之间”的方差，不是把一套 Sobol 内部 N 个点当 i.i.d. 后计算 `sample variance/N`。

---

## 9. RNG、seed、stream、sample、dimension：重新建立正确模型

“有一个 seed，然后调用 random()”对 CPU 小程序够用，对路径追踪不够。

### 9.1 seed 不等于随机性本身

一个伪随机生成器是确定函数：

\[
(state_{n+1},u_n)=G(state_n,parameters)
\]

给定：

```text
算法版本
初始 state
stream / sequence 参数
调用顺序
```

整个序列就确定了。seed 只是初始化输入，不是魔法，也不保证两个不同 seed 的序列在数学上完全独立。

### 9.2 必须区分四种身份

```text
global seed       一次渲染或一次实验的总种子
pixel key         像素坐标，例如 (x,y)
frame/sample key  帧号、SPP 样本号
dimension         这条路径当前要的第几个随机维度
```

一个样本应更像：

```text
u = Sample(pixel_x, pixel_y, frame_index, sample_index, dimension, global_seed)
```

而不是：

```text
u = rand(); // 谁先调用谁拿下一个数
```

### 9.3 为什么“调用顺序”会破坏复现

假设一条路径先抽：

```text
维度 0：像素 jitter
维度 1：像素 jitter
维度 2：BRDF 方向 u
维度 3：BRDF 方向 v
```

如果某条路径提前命中光源，多抽或少抽了一个随机数，后续调用会整体错位：

```text
路径 A 的 dimension 4 → 原来用于下一次反弹
路径 B 的 dimension 4 → 因为分支不同，变成另一个用途
```

结果是：

```text
改一个 if，整张图后续样本全部改变
多线程执行顺序改变，结果也改变
```

stateful per-thread RNG 可以工作，但必须固定每条路径的消耗契约。更稳的生产方式是 counter/key based：根据 `(pixel, frame, sample, dimension)` 直接计算数字，不依赖线程调度顺序。

### 9.4 PCG32 到底保存什么

本课 PCG32 保存：

```text
state   64 位内部状态
inc     64 位 stream 参数，强制为奇数
```

`make_rng(initstate, initseq)` 做初始化；之后每次 `pcg32()` 改写 state 并输出一个 `uint32`。

```text
同算法 + 同 initstate + 同 initseq + 同调用顺序 = 同序列
```

`inc` 不是“第二个随机数”，它选择不同的 LCG stream。不同 stream 不能仅凭肉眼说成严格独立；工程上还要避免相同 seed/stream 组合、做统计测试或使用成熟库。

`uniform01`：

\[
u=\frac{uint32+0.5}{2^{32}}
\]

这是把离散整数映射到 `(0,1)`，避免返回恰好 0 或 1。它只产生均匀 `u`，不是任意目标 PDF。

### 9.5 路径追踪复现清单

要复现一张图，至少保存：

```text
RNG / Sobol 算法与版本
全局 seed / frame seed
pixel 到 key 的映射
sample index 到序列 index 的映射
path dimension 的分配规则
分辨率、SPP、最大 bounce
采样器配置：纯随机、分层、Sobol、Owen seed
场景、相机、材质、光源参数
```

只保存 PNG 不够。只保存一个 seed 也不够，因为算法、调用顺序和维度分配同样是输入。

---

## 10. 普通 MC、分层、Sobol、Owen 的统一对照

```text
普通 i.i.d. MC
  样本：独立同分布
  无偏：是（采样与 p 配套）
  方差：Var(Y)/N 直接成立
  优点：理论简单，分支影响相对容易处理
  缺点：扎堆和空洞，典型 O(1/sqrt(N))

分层采样
  样本：每层条件采样，通常不再同分布
  无偏：是（按层测度加权）
  方差：Σ w_j² σ_j²/n_j；不能直接套 Var/N
  优点：覆盖域，平滑函数常显著降方差
  缺点：高维分层成本上升；不合理分层收益小

确定性 Sobol/QMC
  样本：有结构的确定性点集
  无偏：严格说没有随机期望可谈；误差用 discrepancy / 实验收敛分析
  方差：固定点集本身没有随机方差
  优点：低差异、低 SPP 通常更均匀
  缺点：结构化伪影、维度相关、分支/不连续函数会损失收益

随机化 Sobol + Owen scrambling
  样本：每个 scramble 是一套结构化点集
  无偏：随机化满足边际均匀时，对 scramble 期望无偏
  方差：跨 scramble 的方差；不是套样本内部 Var/N
  优点：保留低差异，同时可重采样、估误差
  缺点：实现复杂，hash 近似不等于理论完整 Owen
```

---

## 11. UE Path Tracer 对照

UE 的路径追踪随机序列源码：

```text
C:\xf\engine\unreal\UnrealEngine\Engine\Shaders\Private\PathTracing\Utilities\PathTracingRandomSequence.ush
```

源码默认：

```hlsl
#define RANDSEQ_PURERANDOM  0
#define RANDSEQ_OWENSOBOL  1
#ifndef RANDSEQ
#define RANDSEQ RANDSEQ_OWENSOBOL
#endif
```

UE 还把像素、帧、SampleIndex 组合成随机序列的 key。例如 PathTracingCore 中使用：

```text
RandomSequenceCreate(LaunchIndex, TemporalSeed, SampleIndex)
```

所以生产引擎不是“每个像素共用一个 rand 状态”。它把：

```text
像素位置
时间/帧索引
样本索引
路径采样维度
```

组合进序列生成过程，使时间累积、空间像素和路径样本能够复现并解相关。

UE 的 Owen 实现是面向 GPU 的快速 hash-based 版本；本课不把它冒充成完整数学参考实现。先用 PCG 和小型解析积分把估计量地基打牢，后面 PT.10 或专门采样专题再实现 Sobol/Owen 验收。

---

## 12. 本机验收现状

现有 `pt3_monte_carlo.cu` 已验证：

```text
同 seed 逐样本 replay：identical
不同 seed 序列不同
∫_0^1 x² dx = 1/3
∫_H cosθ dω = π
忘掉 PDF → 0.5，不是 π
PDF 数值归一化接近 1
```

但必须诚实说明：当前程序的 `Acc::se()` 直接使用了 i.i.d. 样本方差除以 `N`。
对分层样本它只是诊断量，不是严格的分层标准误差；下一次验收扩展应改成：

```text
固定 N，运行 K 个独立分层设计
统计 K 个 run 均值的方差
与 i.i.d. MC 的 K 个 run 方差比较
```

这正是本节修正后的方差口径。

---

## 13. 小结

```text
I = ∫ f dμ
X~p 时，E[f(X)/p(X)] = ∫ f dμ
“每一项的期望等于积分”，不是“每一枪等于积分”
X=C^{-1}(U) 是逆 CDF 采样；由 P(X≤x)=P(U≤C(x))=C(x) 证明
p∝|f| 中 ∝ 是“正比”，|f| 是绝对值；f≥0 且 p=f/I 时零方差
Var(mean)=Var/N 只适用于 i.i.d.；一般公式必须包含协方差
分层用条件期望和全方差公式；正确方差是 Σ w_j²σ_j²/n_j
Sobol 是确定性低差异序列，不是普通随机数
Owen scrambling 是按二进制前缀做随机置换；随机化 Sobol 才能谈 scramble 期望和跨 scramble 方差
seed 只是确定性序列的初始化；复现还需要算法、stream、pixel/sample/dimension 映射和调用契约
```

下一节 PT.4 才把这些采样基础接到：

\[
L_i\,f_r\,\cos\theta / p(\omega)
\]

那时会再次使用余弦 PDF，并做白炉测试，验证材质不会凭空增能。

---

## 自测题

1. 对 `I=∫_0^1x²dx`，均匀抽到 `x=0.2` 时这一枪贡献是多少？为什么它不等于 `1/3`？什么量的期望才等于 `1/3`？
2. `p(x)=2x` 的 CDF 是什么？为什么 `X=sqrt(U)` 的 CDF 正好是 `x²`？
3. `p∝|f|` 中 `∝` 和 `| |` 各是什么意思？如果 `f≥0`，为什么 `p=f/I` 会让每一枪都等于 `I`？
4. 什么时候可以写 `Var(mean)=Var/N`？分层估计量的正确方差公式是什么？为什么当前代码的单次 `se` 不能直接当分层误差条？
5. Sobol 固定点集为什么严格说没有随机方差？Owen scrambling 做了什么，为什么随机化后可以用多次 scramble 估计方差？
6. 要复现一个像素的第 17 个样本，除了 global seed，还需要哪些 key？为什么“谁先调用 rand()”不适合作为路径采样契约？
