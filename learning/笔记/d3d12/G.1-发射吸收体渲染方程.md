# G.1 从一段雾推导发射—吸收体渲染

本节目标：从“光穿过小段介质后还剩多少”推导 `alpha`、透射率 `T` 和前向颜色累积，独立验证权重约束与步长收敛。2026-10-22 已在本机运行 CPU 参考程序。

课程共享工程：[neural-rendering](../../sandbox/d3d12/neural-rendering/README.md)。实现入口是 [volume_math.cuh](../../sandbox/d3d12/neural-rendering/src/volume/volume_math.cuh)、[volume_cpu.cpp](../../sandbox/d3d12/neural-rendering/src/volume/volume_cpu.cpp)，验收入口是 [volume_validate.cu](../../sandbox/d3d12/neural-rendering/tests/volume/volume_validate.cu)。源码定位：`Density` 第 30 行、`Accumulate` 第 45 行；CPU `RenderCpu` 第 31 行；独立解析验收 `G1` 第 45 行。

## 1. 要解决的几何问题

普通不透明网格沿射线找一个最近交点。雾、烟、云等体积在一整段空间内都有贡献：射线经过前面的雾以后，后面物体的颜色会被削弱，而雾自己也可能向相机送来颜色。

可以先把雾看成一串极薄的半透明层，但这只是建立直觉。真正的输入通常是每个位置的介质密度，并不是预先给定、与厚度无关的一张张 Alpha 图片。我们首先要得到“密度 × 行进距离”怎样决定一层的透光比例。

本课使用世界盒 `[-1,1]^3`，相机默认在 `(0,0,-3)`，看向 `+Z`；`+Y` 是上方，输出图像第 0 行在上方。射线写成

\[
\mathbf x(t)=\mathbf o+t\mathbf d,\qquad\|\mathbf d\|=1.
\]

归一化很重要：这样 `t`、步长 `delta` 和相交距离才都以世界长度计量。如果方向长度为 2，却还把 `delta` 当世界长度，实际采样点每次走了两倍距离，而吸收公式仍按原距离计算，介质会变得错误地稀薄。

## 2. 从薄层约束推导透射率

定义 `sigma >= 0` 为消光系数，单位是世界长度的倒数。为了与 NeRF 习惯接轨，代码把它叫 `density`；它并不是物理质量密度本身。两者之间还需要材质相关的截面/比例系数。

设当前仍能继续穿行的比例是 `T(s)`。在均匀的极薄段 `ds` 内，损失应当同时正比于“当前剩余比例”“介质强度”“段长”：

\[
dT=-\sigma T\,ds.
\]

分离变量并施加边界 `T(0)=1`：

\[
\frac{dT}{T}=-\sigma ds,
\quad \ln T(s)=-\sigma s,
\quad T(\Delta)=e^{-\sigma\Delta}.
\]

因此这一段与光发生相互作用的比例为

\[
\alpha=1-e^{-\sigma\Delta}.
\]

这不是人为挑出的调色公式，而是由“局部损失与剩余量成正比”得到的指数解。如果两个等长段的透射率各为 `q`，连在一起就是 `q²`；同一物理厚度拆成多少段，不应凭空改变总吸收。

密度变化时，光学厚度为 `tau(a,b)=integral sigma(s) ds`，透射率为 `exp(-tau)`。光学厚度无量纲；几何厚度相同的两团雾，密度不同就有不同的光学厚度。

### 密度、Alpha、覆盖率各是什么

|量|含义|是否随采样步长改变|
|---|---|---|
|`sigma`|单位距离的消光强度|同一场位置不变|
|`alpha`|有限厚度小段发生相互作用的比例|会；段越短通常越透明|
|几何覆盖率|一个像素/采样区域被几何遮住多少|不是上述体积密度|

Alpha Blend 的代数可以复用，但 Alpha 的来源并不相同。若把一个 `alpha=.2` 原封不动地用于所有步长，步长减半意味着同一距离经过的层数翻倍，雾就会无故变浓。

## 3. 颜色为什么是 `T * alpha * c`

设某段的线性颜色为 `c_i`，到达这段前尚未被消耗的比例是 `T_i`。只有其中 `alpha_i` 这一部分在该段贡献颜色，所以该段权重是

\[
w_i=T_i\alpha_i.
\]

更新顺序为

\[
C\leftarrow C+T_i\alpha_i c_i,
\qquad T_{i+1}\leftarrow T_i(1-\alpha_i).
\]

必须先用旧 `T_i` 算本段贡献，再更新 `T`。如果先更新，当前段会被自己的吸收额外乘一次，颜色会偏暗。

连续形式是

\[
C=\int_{t_n}^{t_f}T(t)\sigma(t)c(t)\,dt+T(t_f)C_{bg},
\quad T(t)=\exp\left(-\int_{t_n}^{t}\sigma(s)ds\right).
\]

这里采用“发射系数 `j=sigma*c`”的常用体渲染参数化。更一般的发射—吸收模型允许独立给定 `j`；若 `sigma=0` 而 `j>0`，仍可能存在发光。我们的 `density + source color` 表示不能直接表达这个特殊情形，也没有求解多次散射、相函数或入射光照。后续 NeRF 里的 `rgb` 同样是射线方向相关的场输出，不等于已经分解好的物理表面反照率。

### 为什么权重和不超过 1

由更新式直接得到

\[
w_i=T_i-T_{i+1}.
\]

累加时中间项抵消：

\[
\sum_i w_i=T_0-T_N=1-T_N\le1.
\]

因 `sigma>=0`、`delta>=0`，所以 `alpha` 和 `T` 都在 `[0,1]`，每个权重也非负。这既是推导结果，也是一个能写进测试的约束；它比“看起来像球”更能发现更新顺序错误。

## 4. 预乘颜色与数值稳定性

最终存储 `float4(C.r,C.g,C.b,1-T)`，其中 RGB 已经包含各段 Alpha 权重，叫**预乘 Alpha**。与背景合成只需

```cpp
finalRgb = volumeRgb + (1.0f - volumeAlpha) * backgroundRgb;
```

不能再次把 `volumeRgb` 乘 `volumeAlpha`，否则重复衰减。所有累积发生在线性颜色空间；仅预览输出时执行一次 sRGB 编码。

当 `x=sigma*delta` 很小时，`exp(-x)` 非常接近 1，浮点运算的 `1-exp(-x)` 会丢掉小数的有效位。代码用 `-expm1f(-x)`，直接计算指数减一的小量。该函数的输入是无量纲光学厚度，输出仍是段 Alpha。

核心实现如下，与 `volume_math.cuh:45` 对应：

```cpp
const float alpha = -expm1f(-sigma * dt);
const float weight = T * alpha;
C = C + color * weight;  // 源码用 float3 辅助函数表达。
T *= 1 - alpha;
```

这是教学数学写法；本文件没有为 `float3` 定义运算符，所以真实代码使用 `Add/Mul`。

## 5. CPU 参考是怎样求积的

本课解析球半径 `R=.65`，密度

\[
\sigma(\mathbf x)=20\max(0,1-\|\mathbf x\|^2/R^2)^2.
\]

球外严格为 0；边界密度和一阶导数连续。它不是硬切换的常密度球，因此减小中点求积步长时更容易观察稳定收敛。线性源颜色还随位置变化，以便检测前后次序造成的颜色差异。

射线先与盒子求交，三条轴各给一个允许的 `t` 区间，取交集。平行于某轴时不能盲目除以 0：如果原点在该轴盒范围外，直接无交；在范围内，该轴不限制区间。

随后对每个区间 `[t,t+dt]` 在中点取密度。最后一段使用 `min(step,end-t)`，不能把盒外距离也计入吸收。采样位置由整数 `k` 重建成 `begin+k*step`，而不是不断 `t+=step`，为后续跳空保持相同采样格点。

公共 CPU API：

```cpp
std::vector<float4> RenderCpu(
    const Field* field,
    const Camera& camera,
    const RenderOptions& options,
    std::vector<PixelStats>* stats = nullptr,
    const float* meshRayDistance = nullptr);
```

`field==nullptr` 时直接求解析密度；非空时用该场的 CPU 三线性插值。返回数组按 `y*width+x` 排列，由返回的 `vector` 拥有；调用方不手动 `free`。可选 `stats` 被调整到像素数并覆写。CPU 参考不使用 occupancy 跳空，保留最直接的积分路径。非法分辨率/步长/数据布局会抛出异常，测试程序将异常转成非零退出码。

最后一个可选参数 `meshRayDistance` 是 G.10 端到端遮挡验收增加的 CPU 数组指针，借用调用方的 `width*height` 个世界射线距离，不取得所有权。非空时每像素积分远端取盒出口与该距离的较小值；默认空指针保持本节的无遮挡行为。它不是设备指针，也不是 NDC 或 view Z。

## 6. 动手与本机实测

从仓库根目录执行：

```powershell
& learning/sandbox/d3d12/neural-rendering/tests/volume/build-volume.ps1
```

完整程序默认同时运行 G.1–G.3；仅运行正确性部分：

```powershell
& learning/sandbox/d3d12/neural-rendering/build/volume/volume_validate.exe `
  learning/sandbox/d3d12/neural-rendering/results quick
```

中心射线逐段记录在 [ray_trace.csv](../../sandbox/d3d12/neural-rendering/results/g1/ray_trace.csv)。其中 `t` 列是沿中心射线的世界 Z 采样位置；本实验方向固定 `+Z`，不要误当作从相机起算的射线距离。几条代表记录：

|序号|Z|sigma|alpha|旧 T|weight|
|---:|---:|---:|---:|---:|---:|
|14|-0.6375|0.029020|0.000725|1.000000|0.000725|
|20|-0.4875|3.828125|0.091266|0.837910|0.076473|
|30|-0.2375|15.016240|0.312990|0.090401|0.028295|
|40|0.0125|19.985210|0.393245|0.000975|0.000383|
|65|0.6375|0.029020|0.000725|9.50818e-7|6.89558e-10|

后半球虽然还有密度，但前方已经把绝大多数透射率消耗掉，因此贡献很小。80 段的实测权重和为 `0.99999904987124`，最终 `T=9.5012875863891e-7`，`abs(sumWeight+T-1)=2.2204460492503e-16`，最小权重为 0。

中心弦还可以独立求闭式解：

\[
\tau=20\int_{-R}^{R}(1-z^2/R^2)^2 dz
=20R(2-4/3+2/5)=\frac{16\cdot20R}{15}.
\]

所以精确透射率为 `exp(-16*20*.65/15)=9.5013033534077e-7`，与数值积分接近。这条独立的 double 精度解析计算没有复用 GPU 的累积函数，能防止同一个错误被 CPU/GPU 共同继承后互相“验证通过”。

64×64 图像关闭提前终止，以 `step=1/1024` 的解析参考作比较：

|步长|线性预乘 RGBA RMSE|最大绝对误差|
|---:|---:|---:|
|1/8|1.985778e-4|1.206577e-3|
|1/16|4.297779e-5|2.852678e-4|
|1/32|9.955997e-6|7.840991e-5|
|1/64|2.453057e-6|1.892447e-5|

步长减半时误差大致缩小到四分之一，符合这里平滑密度场、中点求积的预期；这不保证所有含突变边界的体数据都有同样收敛速度。结果见 [convergence.csv](../../sandbox/d3d12/neural-rendering/results/g1/convergence.csv) 与 [summary.json](../../sandbox/d3d12/neural-rendering/results/g1/summary.json)。原始 PPM 图像保留在本课 `results/g1/`，不把生成的二进制图像当作源码提交。

## 7. 与引擎实践对照、自测及答案

商业引擎的体积雾常使用视锥网格、低分辨率注入、光照积分和时间重投影；云还会使用分层密度、噪声、光源方向采样与专门降噪。本课先在世界盒内做单射线发射—吸收积分，尚未实现这些光照/时域系统。共同的底层机制仍是透射率乘积、预乘颜色和沿射线的离散求积。

1. **步长减半，sigma 要不要翻倍？** 不要。sigma 描述同一场的单位距离强度，变化应体现在 `alpha=1-exp(-sigma*delta)` 中。
2. **为什么需要背景项 `T_final*C_bg`？** 累积权重通常小于 1，剩余的比例就是没有被体积遮住的背景。
3. **同样的红雾与蓝雾交换前后，Alpha 不变而颜色会变吗？** 会。总透射率是乘积，交换因子不变；颜色权重使用到达各段前的 T，因而依赖次序。

下一节把这个积分流程映射为“一个 CUDA 线程负责一个像素”，并明确三维纹理、输出缓冲和 D3D12 共享资源各自的所有权。
