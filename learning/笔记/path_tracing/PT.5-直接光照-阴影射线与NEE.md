# PT.5 直接光照、阴影射线与 Next Event Estimation

## 目标与边界

PT.4 把 `Li(ωi)` 当作已知解析函数。本节把它换成真实光源采样：在命中点显式挑一个光源上的点，计算它对当前点的直接贡献，然后发射一条**有限长度阴影射线**判断中间是否有遮挡。

本节只建立一次直接光照闭环：

```text
命中点 x
  -> 抽光源样本 y
  -> 得到方向 wi、距离 r、光源法线 nl、PDF
  -> 发射 shadow ray，t ∈ (0,r)
  -> 可见：计算 Li * fr * cos_surface / p_omega
```

暂不做：BSDF 随机反弹、MIS、俄罗斯轮盘赌、BVH、CUDA kernel。它们分别在 PT.6/PT.7/PT.9 处理。点光源也会讲，但点光源是 delta 光源，不是普通面积 PDF 的一个极限写法。

代码：`learning/sandbox/path_tracing/pt05-direct-lighting/pt5_direct_lighting.cu`

运行：

```powershell
cd C:\xf\Cuda\accelerated-computing-hub\learning\sandbox
.\build.ps1 path_tracing\pt05-direct-lighting\pt5_direct_lighting.cu
```

本机结果：`PT.5 Direct lighting: PASS`。

---

## 1. 先把 PT.4 的“已知 Li”换成光源

Lambert 表面在点 `x`、法线 `n` 的直接光照为：

\[
L_o^{direct}(x,\omega_o)
=\int_{A_L}
L_e(y\to x)\,f_r(x,\omega_i,\omega_o)\,
\cos\theta_x\,V(x,y)\,d\omega_i
\]

这里把方向域积分改写成了从面积光源 `A_L` 上的点 `y` 进行积分。符号：

```text
x             当前着色点
n             x 处的表面法线
 y             光源表面被抽中的点
nl            y 处光源法线
wi            从 x 指向 y 的单位方向
r=|y-x|       光源点到着色点的距离
Le            光源沿 -wi 方向发出的辐亮度
V(x,y)        可见性，无遮挡为 1，有遮挡为 0
fr            当前表面的 BRDF，本节 fr=ρ/π
```

两个余弦：

\[
\cos\theta_x=\max(0,n\cdot\omega_i)
\]

\[
\cos\theta_L=\max(0,n_l\cdot(-\omega_i))
\]

第一个是接收表面的投影余弦；第二个是发光面朝向着色点的余弦。它们来自不同表面，不能混为一个 `cos`。

---

## 2. 面积光源：先在面积域采样

本节的矩形光源参数：

```cpp
struct RectLight {
    Vec3 center;  // 中心
    Vec3 u, v;    // 两条单位边方向，应该互相正交
    double hu,hv; // 半边长；完整边长分别是 2hu、2hv
    double Le;    // 固定发光辐亮度
};
```

面积为：

\[
A_L=(2h_u)(2h_v)=4h_uh_v
\]

用两个均匀变量：

\[
\xi_u,\xi_v\sim U(0,1)
\]

矩形点：

\[
y=c+(2\xi_u-1)h_u u+(2\xi_v-1)h_v v
\]

相对于面积测度 `dA` 的 PDF 是常数：

\[
\boxed{p_A(y)=\frac1{A_L}}
\]

注意：这不是相对于立体角的 PDF。PT.4 的路径权重使用的是 `p_ω`，所以必须转换。

---

## 3. 面积 PDF 到立体角 PDF：Jacobian 是本节核心

从 `x` 看光源面上一小块面积 `dA`，它在方向空间覆盖的立体角是：

\[
\boxed{
d\omega=\frac{\cos\theta_L}{r^2}\,dA
}
\]

其中：

```text
cosθL  光源面片对着 x 的程度
r²     距离平方
```

直观上：距离越远，同样面积占的视角越小；光源越侧着看，有效投影面积越小。

由概率质量不变：

\[
p_A(y)dA=p_\omega(\omega)d\omega
\]

代入 Jacobian：

\[
p_A dA
=p_\omega\frac{\cos\theta_L}{r^2}dA
\]

消掉 `dA`：

\[
\boxed{
p_\omega(\omega)
=p_A(y)\frac{r^2}{\cos\theta_L}
}
\]

因此矩形面积光源均匀采样时：

\[
\boxed{
p_\omega=\frac{r^2}{A_L\cos\theta_L}}
\]

前提是 `cosθL>0`。如果发光面背对着 `x`，它对单面发光约定不贡献；不能计算一个没有意义的 `p_ω`。

代码对应：

```cpp
double pa = 1.0 / light_area(light);
double po = (cos_light > 0.0)
          ? pa * dist2 / cos_light
          : 0.0;
```

### 3.1 为什么代码里是 `r² / cosL`，不是 `cosL / r²`

`cosL/r²` 是从面积微分到立体角微分的 Jacobian：

\[
\frac{d\omega}{dA}=\frac{\cos\theta_L}{r^2}
\]

PDF 转换需要反过来：

\[
\frac{dA}{d\omega}=\frac{r^2}{\cos\theta_L}
\]

所以：

```text
几何微分 dω/dA       = cosL/r²
面积 PDF 转方向 PDF  = pA*r²/cosL
```

两者方向相反，这是最常见的 Jacobian 错误。

---

## 4. NEE 的面积采样估计量

我们从面积光源采样 `y`，但仍用相对于立体角的 PDF。单样本直接光照贡献是：

\[
Y_{NEE}
=\frac{
L_e(y\to x)\,f_r(x,\omega_i,\omega_o)\,
\cos\theta_x\,V(x,y)
}{p_\omega(\omega_i)}
\]

Lambert：

\[
f_r=\frac\rho\pi
\]

代入面积光源的 PDF：

\[
Y_{NEE}
= L_e\frac\rho\pi\cos\theta_x V
\frac{A_L\cos\theta_L}{r^2}
\]

即：

\[
\boxed{
Y_{NEE}
= L_e\,\frac\rho\pi\,
\frac{\cos\theta_x\cos\theta_L A_L}{r^2}\,V
}
\]

代码选择先用 PDF 形式：

```cpp
return light.Le
     * (rho / pi)
     * cos_surface
     / pdf_omega;
```

它与显式几何形式完全相同：

```text
1 / pω = A * cos_light / r²
```

为什么在代码中没有再乘一次 `cos_light`？因为 `cos_light` 已经包含在 `1/pdf_omega` 中。

错误写法：

```cpp
Le * fr * cos_surface * cos_light / pdf_omega;
```

如果 `pdf_omega` 已经是 `pA*r²/cos_light`，这样会把光源余弦重复乘一次，造成偏暗。只有在使用面积域 PDF `p_A` 时，才应直接写：

\[
L_e f_r\frac{\cos\theta_x\cos\theta_L}{r^2} \frac1{p_A}
\]

两种写法二选一，不能混用。

---

## 5. 点光源：为什么不能硬套面积光 PDF

点光源的位置固定为 `y`，没有面积：

```text
它没有一个普通的有限面积 A
p_A = 1/A 没有意义
它的方向分布是 Dirac delta，而不是普通函数 pω(ω)
```

因此点光源直接使用确定性贡献。令点光源强度为 `I`，单位为 `W/sr`，距离为 `r`：

\[
L_o^{point}
=I\frac{\rho}{\pi}
\frac{\cos\theta_x}{r^2}V
\]

代码：

```cpp
return intensity
     * (rho / pi)
     * cos_surface
     / dist2;
```

这里的 `1/r²` 是点光源的几何衰减；不要把它和面积光源 PDF Jacobian 混为一个来源。

### 5.1 为什么点光源先给出辐照度，再得到出射辐亮度

更准确的关系不是对任意材质都写 `Lo = fr * E`，而是从渲染方程推出：

\[
L_o(x,\omega_o)=\int_{\Omega^+}f_r(x,\omega_i,\omega_o)L_i(x,\omega_i)\cos\theta_i\,d\omega_i
\]

辐照度定义为：

\[
E(x)=\int_{\Omega^+}L_i(x,\omega_i)\cos\theta_i\,d\omega_i
\]

只有当 `fr` 与入射方向无关时，才能把它从积分中提出。Lambert BRDF 正是：

\[
f_r=\frac{\rho}{\pi}
\]

因此：

\[
\boxed{L_o=\frac{\rho}{\pi}E}
\]

一般 GGX、镜面或其他方向相关 BRDF 不能只根据总辐照度 `E` 得到 `Lo`，因为它们还需要知道光从哪些方向来。

点光源的辐射强度定义为：

\[
I=\frac{d\Phi}{d\omega}
\]

距离 `r` 处，接收面微元 `dA_x` 对点光源张开的立体角是：

\[
d\omega=\frac{\cos\theta_x}{r^2}dA_x
\]

所以该面片收到的通量为：

\[
d\Phi=I\,d\omega
=I\frac{\cos\theta_x}{r^2}dA_x
\]

除以接收面积得到点光源辐照度：

\[
\boxed{E_x=I\frac{\cos\theta_x}{r^2}V(x,y)}
\]

再代入 Lambert 关系：

\[
\boxed{
L_o=\frac{\rho}{\pi}E_x
=I\frac{\rho}{\pi}\frac{\cos\theta_x}{r^2}V(x,y)
}
\]

这里没有 `cosθL`：点光源没有面积和发光表面法线，只有位置与辐射强度；`cosθ_x` 是接收表面的投影余弦。

单位也要对上：

```text
I       W/sr
E       W/m²
fr      1/sr
Lo      W/(m²·sr)
fr * E  W/(m²·sr)
```

这就是 `direct_point()` 中点光源公式的来源，不是把面积光源公式令面积趋近于零后机械套用。

```text
点光源：固定方向 + 反平方衰减 + delta 光源
面积光源：抽面积点 + pA 转 pω + 几何项由 Jacobian 产生
```

PT.6 讲 BSDF-only 与 NEE/MIS 时，会再次看到 delta 光源为什么需要特殊处理。

---

## 6. 阴影射线：它不是“再求一次无限远命中”

给定着色点 `x` 和光源点 `y`：

\[
d=y-x,
\qquad r=|d|,
\qquad \omega_i=d/r
\]

阴影射线的有效区间必须是：

\[
\boxed{t\in(\epsilon,r-\epsilon)}
\]

代码：

```cpp
Vec3 origin = x + n * eps;
Ray shadow = make_ray(
    origin,
    y - origin,
    eps,
    distance - eps);
```

### 6.1 起点为什么沿法线偏移

如果射线从浮点求交点 `x` 原样出发，理论上它在表面上；由于浮点舍入，第二次求交可能立刻重新命中当前表面：

```text
shadow origin = x
→ t≈0 再次命中自己
→ 永远认为被遮挡
```

因此沿着着色法线偏移：

\[
x'=x+\epsilon n
\]

这就是 self-intersection epsilon。

但它不是越大越好：

```text
epsilon 太小：仍可能自相交
epsilon 太大：光源附近/薄几何可能漏光，射线起点被推到另一侧
```

本节使用固定 `1e-5` 作为教学尺度；生产渲染器通常根据场景尺度、浮点误差、法线方向和 ray-origin offset 方法自适应计算。

### 6.2 `tmax=r-epsilon` 为什么重要

如果阴影射线只设置一个很大的 `tmax`，它可能击中光源本身，误判为遮挡。

有限段测试只关心：

```text
从 x 到 y 之间有没有物体
```

不关心：

```text
光源 y 之后还有没有物体
```

所以必须把 `tmax` 截断到光源前。

---

## 7. 单面与双面发光

本节矩形光源采用单面发光：

\[
\cos\theta_L=\max(0,n_L\cdot(-\omega_i))
\]

如果光源背面对着着色点：

```text
cos_light = 0
该样本无贡献
```

双面发光的约定可以改成：

\[
\cos\theta_L=|n_L\cdot(-\omega_i)|
\]

但这不是一个无关紧要的代码开关，它改变了光源物理定义和总能量。引擎通常把 emissive 材质的双面/单面约定、背面剔除和光源采样规则明确分开；教学程序必须先声明约定，不能把两者混用。

---

## 8. 固定辐亮度下，面积变化意味着什么

本节矩形光源固定 `Le=5`。将面积从 `4` 改成 `1` 时：

- 每单位面积发出的辐亮度不变；
- 光源覆盖的立体角通常变小；
- 直接光照通常变小；
- 阴影边界和半影形状会改变；
- 不是简单地“面积变小，Le 自动变大”或“总功率固定”。

如果需求是固定总功率，则应随面积改变 `Le`，这是另一种实验约定。本节选择固定辐亮度，是为了清楚验证面积光源积分的几何覆盖。

---

## 9. 程序结构和验收结果

`pt5_direct_lighting.cu` 的主要函数：

```text
sample_rect       在矩形面积域均匀采样，返回 q、wi、cos、pA、pω
visible           有限长度阴影射线，负责 epsilon 与 blocker
nee_area          Le * (rho/pi) * cos_surface / pω
 direct_point      delta 点光源的 I * (rho/pi) * cos / r²
rect_reference    用高分辨率中点面积积分作独立参考
```

本机 Windows + RTX 5070 / CUDA 13.3，使用 `sm_120` 编译运行：

```text
rectangle area/normal and one-sided orientation            PASS
area PDF -> solid-angle PDF Jacobian                       PASS
point light inverse-square direct term                     PASS
point shadow ray rejects blocker                           PASS
point shadow ray unoccluded                                PASS
rectangle free: reference=0.431611749 mean=0.431504924
unoccluded area-light NEE matches area reference           PASS
rectangle blocked: reference=0.241079345 mean=0.241050407
partial blocker produces correct soft-shadow mean          PASS
one-sided emitter rejects back-facing samples              PASS
fixed-radiance area change affects direct energy           PASS
PT.5 Direct lighting: PASS
```

`reference` 是 512×512 面积中点积分，`mean` 是 64 个独立 run、每个 4096 个面积样本的 NEE 均值；二者不同是有限样本误差，不是两种积分目标。遮挡后均值变低但不为零，说明球体只挡住了矩形光源的一部分，形成软阴影。

---

## 10. 常见错误

### 错误 A：面积 PDF 直接当方向 PDF

```cpp
pdf = 1 / A;
contribution = Le * fr * cos_surface / pdf;
```

错。渲染方程的方向测度是 `dω`，必须使用：

\[
p_\omega=\frac{r^2}{A\cos\theta_L}
\]

或者直接在面积测度下写完整 Jacobian：

\[
L_e f_r\frac{\cos\theta_x\cos\theta_L}{r^2}\frac1{p_A}
\]

### 错误 B：`cos_light` 重复乘

已经使用 `pω=pA*r²/cosL` 时，`1/pω` 已带 `cosL`。再次乘 `cosL` 会偏暗。

### 错误 C：阴影射线无限长

会把光源后的物体当成遮挡物。必须 `tmax=distance-epsilon`。

### 错误 D：忘记距离平方

面积光源从面积域换到方向域时会出现 `r²`；显式面积形式有 `1/r²`。没有它，远近光源能量明显错误。

### 错误 E：点光源套面积采样

点光源是 delta，不存在普通有限 `p_A`；直接用它的强度和 `1/r²` 公式。

### 错误 F：把软阴影理解成滤波

本节的软阴影来自：不同面积光源点的可见性不同，面积积分中 `V(x,y)` 在光源面上只有一部分为 1。它不是对硬阴影图像做模糊。

---

## 11. 与商业引擎的对照

教学程序把矩形光源、球体 blocker、单个着色点全部写在 CPU 中，目的是看清测度转换和有限区间射线。UE/Unity 等生产渲染器通常会：

```text
离线/运行时构建光源采样分布或 alias table
使用 BVH/DXR 做阴影可见性
支持纹理化发光面、IES、光源类型、重要性采样
在 GPU wave/线程中批量发射 shadow rays
再用 MIS/ReSTIR 处理多个光源候选
```

但共同底层机制没有变：

```text
选择光源样本
→ 得到同一测度下的 PDF
→ 计算几何项和可见性
→ 用 BRDF/PDF 形成无偏或明确标注偏差的估计
```

---

## 12. 本节小结

```text
点光源：I * (rho/pi) * cos_surface / r² * V
面积光源采样：pA = 1/A
Jacobian：dω = cos_light/r² dA
方向 PDF：pω = pA*r²/cos_light
NEE 样本：Le * fr * cos_surface * V / pω
阴影射线：origin=x+eps*n，tmax=distance-eps
单面发光：cos_light=max(0,nL·(-wi))
```

最重要的一句话：

> 面积光源不是“抽到一个点后直接乘 BRDF”；你必须把“在面积上抽点”的概率转换成“在方向上抽这条光线”的 PDF，或者始终在面积测度下保留完整 Jacobian。

下一节 PT.6：`BSDF sampling + NEE + MIS`。届时两种抽样策略会同时存在：一种从 BSDF 抽方向，一种从光源抽方向；只有先把两边的 PDF 转到同一测度，Balance/Power Heuristic 才有意义。

自测题：

1. 矩形光源均匀面积采样时，为什么 `p_ω=p_A*r²/cos_light`？`cos_light/r²` 和 `r²/cos_light` 哪个是 Jacobian，哪个是 PDF 转换？
2. 阴影射线为什么同时需要 `origin=x+eps*n` 和 `tmax=distance-eps`？二者分别防什么错误？
3. 如果已经使用 `p_ω=p_A*r²/cos_light`，再在贡献里额外乘一次 `cos_light`，结果偏亮还是偏暗？
4. 点光源为什么不能直接套 `p_A=1/A`？
