# R.13 第一部分：针孔相机与几何属性诊断

> 2026-10-10 按学习者要求重新规划 R.13。本文保留为旧版解析相机/诊断实验记录；新课堂入口为 `R.13-重启计划与相机约定.md`，本文的运行结果不代表新版各小节完成。新版统一使用行向量矩阵约定，本文补正中的列向量公式仅属于旧版讲解。

2026-10-10。R.12收束后正式进入本节；仅验证相机像素射线和世界空间命中属性，NEE图像/渐进累积仍待后续，不把诊断图称为完整Path Tracer。

## 上节三题答案与R.12收束

1. rho*Li简化要求实际方向PDF为cosθ/π。面积采样使用pω=pA*r²/cosL，不能进行同样抵消。
2. 被遮挡样本属于零贡献，分母仍是全部N；只除以可见数量会条件化分布，导致偏亮。
3. 样本数量不是嵌套深度，每个样本只有主TraceRay→shadow TraceRay两层，因此深度2。

R.12已验证点光和矩形灯NEE、有限范围、mask/flags/payload、单面朝向、CPU/GPU对照。2026-10-10完成课堂收束，不据此宣称学习者答题已掌握；后续可继续回顾。

## 文件与可运行入口

- `learning/sandbox/d3d12/r13-legacy-camera/dxr_camera.hlsl`：相机主射线、三角形属性读取、世界几何法线、48B逐像素输出。
- `learning/sandbox/d3d12/r13-legacy-camera/dxr_camera_pipeline.cu`：沿用R.12独立宿主结构，扩展root绑定与三实例场景；编译sm_120但没有CUDA kernel。
- `learning/sandbox/d3d12/r13-legacy-camera/dxr_camera_reference.h`：CPU相机基、场景变换、双精度最近命中、逐像素验收、诊断PPM输出。
- `learning/sandbox/d3d12/r13-legacy-camera/dxr_camera_preview.py`：Pillow把实际读回生成的PPM无缩放转换PNG并排版；不重新计算场景或修补图像。

从仓库根目录执行，每步成功后再执行下一步：

```powershell
& 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\dxc.exe' -T lib_6_3 -Fo learning/sandbox/d3d12/r13-legacy-camera/dxr_camera.dxil learning/sandbox/d3d12/r13-legacy-camera/dxr_camera.hlsl
& .\learning\sandbox\build.ps1 learning\sandbox\d3d12\r13-legacy-camera\dxr_camera_pipeline.cu -NoRun
& .\learning\sandbox\d3d12\r13-legacy-camera\dxr_camera_pipeline.exe .\learning\sandbox\d3d12\r13-legacy-camera\dxr_camera.dxil wide
& .\learning\sandbox\d3d12\r13-legacy-camera\dxr_camera_pipeline.exe .\learning\sandbox\d3d12\r13-legacy-camera\dxr_camera.dxil square
python learning/sandbox/d3d12/r13-legacy-camera/dxr_camera_preview.py
```

## 1. 从像素反推世界方向

CPU给出世界位置C、观察目标target、参考上向(0,1,0)，构造：F=normalize(target-C)，R=normalize(cross(F,worldUp))，U=cross(R,F)。本课F是前向，而PT.2变量w是后向，所以F=-w。单位正交基只是约定，不把它泛化成所有引擎的坐标轴。

相机参数要求C!=target且F不平行worldUp；本例固定两套有效输入，没有通用退化输入回退。

像素(x,y)，宽高W/H：u=(x+.5)/W，v=(y+.5)/H；+0.5取中心，尚无jitter。成像平面放在前方1单位，垂直FOV记作α，半高h=tan(α/2)，宽高比a=W/H，半宽ah。

sx=(2u-1)ah，sy=(1-2v)h；D=normalize(F+sxR+syU)，O=C。

sy翻转源自图像y向下、U向上。a用于保持水平/垂直角尺度正确，不能在宽屏下把两个方向都当作同样FOV。

这等价于PT.2在世界成像平面上取点再减相机位置；本节没有求逆矩阵。生产渲染器也可用逆ViewProjection做反投影，需统一矩阵/裁剪空间/深度约定，当前用显式基把几何关系展开。

RayDesc Direction为单位向量，所以RayTCurrent对应世界距离；TMin=.001、TMax=100均为本课距离区间，并非光栅化near/far投影矩阵的自动作用。求交不发生在NDC，也不调用RSSetViewports。

偶数分辨率中心位于四个像素之间，不存在一个恰好对准F的中心像素；257×257的(128,128)则恰好对准F。像素中心一枪只验证方向，不能称为像素面积的完整积分或抗锯齿。

## 2. 相机参数布局与Root绑定

CameraData四个float4，共64B：eyeTan.xyz=C、w=h；rightAspect.xyz=R、w=a；up.xyz=U；forward.xyz=F；未用w为0。

HLSL cbuffer Camera:register(b0)与上述排列对应。CPU调用：

`void SetComputeRoot32BitConstants(UINT RootParameterIndex, UINT Num32BitValuesToSet, const void* pSrcData, UINT DestOffsetIn32BitValues)`。

本例(4,16,&camera,0)：根参数索引4、16个DWORD、CPU源地址、从该根常量块第0项开始。根常量值被记录到命令列表，不是让GPU稍后解引用栈上的camera；也未创建CBV资源，不适用CBV地址256B对齐要求。

根索引与shader寄存器不是同一编号系统：0=t0 TLAS，1=u0输出，2=t1顶点SRV，3=t2索引SRV，4=b0相机常量。4个root descriptor占8 DWORD，常量16 DWORD，总24 DWORD。

VB是4个float3、stride12、48B；IB是6个uint32、24B。它们既提供BLAS构建输入，也以SRV提供ClosestHit属性读取；加速结构不会自动给应用原始顶点数组。资源继续保持到Fence后释放。

## 3. 命中着色器读取什么

`uint PrimitiveIndex()`得到当前geometry中的三角形序号；本例只有一个geometry、两个三角形，所以0/1，不是InstanceID。索引读取`indices.Load3(primitive*3*4)`：ByteAddressBuffer地址单位是字节，每组三个uint32占12B。再用三项索引读取StructuredBuffer<float3>顶点。

本例三个实例共享同一个局部平面BLAS、VB/IB与HitGroup，应用InstanceID=1/2/3：左板绕Y -25°并非均匀正缩放，右板绕Y +35°并非均匀正缩放，地板绕X -90°。使用同一SBT记录不意味着实例ID相同。

`float3x4 ObjectToWorld3x4()`给当前实例从BLAS局部到世界的变换。`mul(M,float4(p,1))`把顶点变到世界；本课是矩阵乘列向量的数学约定，不与内存排列混为一谈。

世界几何法线Ng=normalize(cross(Bw-Aw,Cw-Aw))。用变换后的边叉积可以正确处理本例非均匀正尺度；不能将局部法线直接乘一般物体变换就当正确。平滑法线需顶点插值及法线变换，负行列式/朝向/faceforward另外处理；当前输出保留三角形绕序的几何法线，不按视线翻转，也没有法线贴图。

位置使用WorldRayOrigin()+RayTCurrent()*WorldRayDirection()。内建三角形属性attr.barycentrics=(u,v)，顶点权重=(1-u-v,u,v)。CPU用GPU给出的重心与triangle/instance重建世界位置，检查它与射线表达式一致。

## 4. 输出与同步

PixelResult为3个float4，stride48；positionT=(世界xyz,t)，normalID=(世界法线xyz,小整数ID)，baryPrim=(u,v,PrimitiveIndex,hit标志)。ID只使用1..3，本例可精确装float，通用较大ID应使用uint字段。

Miss写t=-1、ID0、hit0；未写入哨兵t=-2，检查失败。每像素写output[y*W+x]，行主序连续，无原子操作。320×180输出2764800B；257×257输出3170352B。

本节仅主射线，所以MaxTraceRecursionDepth=1，MaxPayloadSizeInBytes=48，内建attributes8B。Miss表仅PrimaryMiss；SBT=RayGen@0、PrimaryMiss@64、HitGroup@128，各32B，无local参数。

Build BLAS→UAV barrier→Build TLAS→UAV barrier→输出COMMON转UAV→DispatchRays(W,H,1)→输出转COPY_SOURCE→CopyResource到Readback→Execute/Signal1→CPU等待Fence1→Map/校验/写图→Unmap。Map不等于GPU完成。原始Upload网格、实例、SBT及加速结构保持存活到Fence之后。

缺DXIL、参数非法、HRESULT失败、等待超时、缺shader导出、Debug warning/error、数值不匹配或写PPM失败都会失败退出。未测试设备移除恢复、GPU-based validation和窗口resize。

## 5. 诊断图解释

左：InstanceID固定伪彩色，检查命中谁与遮挡覆盖。
中：normalRGB=.5Ng+.5，检查法线朝向。当前平面每块为常色是正确结果；相机变化时世界法线颜色保持相同。
右：灰度clamp((12-t)/10,0,1)，近亮远暗。t是沿单位射线的距离，不是NDC z、深度缓冲值或相机前向深度。对单位前向F，相机前向距离为t*dot(D,F)。

图像是数值诊断编码，不是辐亮度；没有经过tone mapping、曝光或sRGB光照显示管线。PPM转PNG保持字节码值，组合图保持原像素尺寸。输出`dxr_camera_diagnostics.png`已实际查看并修正排版截断。

## 6. CPU/GPU验收结果

CPU使用PT.2 lower-left成像平面形式生成射线，在double中对3实例×2三角形进行Moller-Trumbore最近命中；GPU使用中心基展开公式和DXR。CPU读取同一份量化后的float相机/矩阵参数，以排除输入量化差。所有像素都检查，不跳过轮廓像素；共享边上不强制相同三角形编号，但ID、位置、法线及重心重建必须一致。

|项目|wide|square|
|---|---:|---:|
|分辨率|320×180|257×257|
|垂直FOV|60°|50°|
|眼睛位置|(0,1,5)|(2,1.8,5)|
|Miss像素|37454|29466|
|ID1像素|2788|4197|
|ID2像素|1651|6065|
|ID3像素|15707|26321|
|ID不一致|0|0|
|非法输出|0|0|
|最大t误差|2.24e-6|2.04e-6|
|最大位置误差|1.83e-6|1.98e-6|
|最大法线误差|8.21e-8|8.21e-8|
|重心重建最大位置差|1.42e-6|1.20e-6|

两次均RTX5070/Tier1.1、camera basis PASS、Fence1/1、Debug0/0、进程exit0。本次先DXC lib_6_3再build.ps1 sm_120真编译；图像由实际GPU读回产生。

这两套配置同时改变分辨率/纵横比、FOV和相机位置，不能把两张图的全部差别只归因于某一个变量。

## 7. 下一部分

2026-10-10 学习者指出：应明确相机假设，并直接采用现代引擎的 View/Projection 流程。先补齐下文的相机约定与逆投影，再继续 NEE 成像；现有程序仍是解析基向量实现，尚未改成矩阵版。

将R.12面积灯NEE作用于本节每个像素的命中点，并接入线性HDR逐帧累积、相机变化后的history reset。窗口整合、像素jitter/抗锯齿、环境背景与发光面、白炉和渐进收敛验收属于R.13后续部分；MIS/多次反弹仍按后续PT.6/PT.7路线推进。

自测：+0.5为什么必要？16:9为什么乘aspect？几何法线图为何换相机仍保持同一物体颜色？射线距离为什么不是NDC深度？

来源：[DispatchRaysIndex](https://learn.microsoft.com/en-us/windows/win32/direct3d12/dispatchraysindex)、[PrimitiveIndex](https://learn.microsoft.com/en-us/windows/win32/direct3d12/primitiveindex)、[ObjectToWorld3x4](https://learn.microsoft.com/en-us/windows/win32/direct3d12/objecttoworld3x4)。

## 8. 相机模型补正：成像平面与逆 ViewProjection

阅读顺序补充（2026-10-10）：本节主要记录实现约定，不能代替矩阵来源的解释。先读第 9 节的几何要求与约束推导，再回到本节对接 UE/D3D 的符号和 API。

当前代码的 E/F/R/U 都在世界空间。F/R/U 是单位正交基，世界参考上向是 +Y；这不是 UE 的 Z-up 世界坐标约定。当前假设为对称针孔透视、垂直 FOV、方形像素、全幅 viewport、像素中心采样、无投影偏移/jitter、无镜头畸变或景深。eye 不等于 target，参考 up 不平行 F。

令 h=tan(vFOV/2)、a=W/H、xN=2u-1、yN=1-2v。虚拟成像点 Q=E+F+xN*a*h*R+yN*h*U，因此 dot(Q-E,F)=1。成像平面是相机前方 1 个世界单位的虚拟平面，不是 near plane、NDC，也不是物理感光面。若改到距离 d>0，需要把横纵尺寸同时乘 d；方向 normalize(Q-E) 不变。方向归一化后的 E+D 位于单位球面，不能把它误当成原来的平面点。

这套解析方法实质是在对称透视约束下展开逆投影与视图逆变换。按列向量数学约定：clip=P*V*world，H=inverse(P*V)*float4(xN,yN,zN,1)，worldPoint=H.xyz/H.w。输入是 NDC 点的齐次代表，不是恢复原来的 clip.w；除以 H.w 才得到有限位置。H.w=0 表示无穷远方向，不能做普通位置除法。

UE 官方 FViewMatrices 文档说明其近端 Z=1、无限远端 Z=0 的投影约定，并提供逆 VP 和 translated-world 矩阵。因此后续示范选择 D3D 深度 [0,1]、reversed-Z、透视相机，先用 zN=1 反投影近面有限点 Qnear，再取 D=normalize(Qnear-E)。这是明确约束下的教学流程，不声称逐字复现某个 UE shader。矩阵布局、mul 顺序及 RHI 差异仍需显式处理。

固定 TMin/TMax 是射线参数界限。当前 D 单位化，所以它们是沿射线的距离。若要匹配前向距离 near/far 的裁剪面，必须用 tNear=near/dot(D,F)、tFar=far/dot(D,F)。离轴射线的 dot(D,F)<1，不能把 near/far 原样当 t。也可以明确保留光追自有距离范围，但不能声称与光栅裁剪一致。

矩阵版本还必须约定：像素坐标相对于 ViewRect（非必然整张纹理）；jitter 由矩阵或像素偏移实现一次，不能重复；若矩阵输出 Translated World，射线原点、方向和 TLAS 必须处于一致坐标系；正交相机应逐像素改变原点，不能套针孔相机公式。本次只修正注释和讲义，矩阵 GPU 路径尚未实现或验收。

官方参考：[FViewMatrices](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/FViewMatrices)、[DeprojectScreenToWorld](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/FSceneView/DeprojectScreenToWorld)、[UE 坐标空间](https://dev.epicgames.com/documentation/unreal-engine/coordinate-system-and-spaces-in-unreal-engine)。

## 9. 从几何约束推导 View、透视、正交标准化与 viewport

### 9.1 本次教学修正与教材依据

2026-10-10，学习者指出：直接给出 View/Projection、NDC 范围和深度公式，再解释它们会产生什么结果，不等于说明矩阵为什么必须或可以这样构造。此前讲解把透视和正交标准化合并过早，跳过了最重要的几何设计过程。

以后采用：**要解决的问题 -> 假设与约定 -> 几何约束 -> 求系数 -> 组成矩阵 -> 验证 -> 对接引擎**。严格区分“由约束推出的结论”和“为了便利而选定的约定”，不能把验证已有公式当成推导来源。

依据为 [Fundamentals of Computer Graphics, Fourth Edition](C:/xf/图像图形/fundamentals-of-computer-graphics-4th.pdf) 第 7 章：书内页 141–145（PDF 页 156–160）的 viewport、正交变换和相机换基；书内页 146–153（PDF 页 161–168）的齐次投影、视锥到盒子的变换及组合。重点参考图 7.12、7.13。以下为结合课堂问题的中文推导，不是教材逐字译文。

本节先使用教材符号：列向量；相机位于原点，朝 -Z 看，Y 向上；近、远平面坐标满足 **f < n < 0**。n、f 是带符号坐标，不是正的距离。最后再单独转换到 UE/D3D 约定。

### 9.2 为什么先选择标准盒子

正交观察时，可见范围是轴对齐盒子 `[l,r] × [b,t] × [f,n]`。沿 Z 轴方向投影，深度不会改变横纵图像尺寸。

不同相机的盒子大小和位置不同。如果先把它们变到统一的标准盒子，后续的越界判断和屏幕映射就可以复用，不必了解每个相机的参数。教材选择 `[-1,1]^3`，中心在原点、边界对称，便于计算。

**选择固定标准形式有工程目的；选择恰好 -1 和 1 并非物理定律。** 也可以选 `[0,1]^3`，或对 Z 单独选 `[0,1]`。改变标准范围以后，重新解端点映射即可。NDC 是这种标准化后的坐标；这里的“归一化”不是让向量长度变成 1。

### 9.3 正交矩阵：从端点映射求出每个系数

要求用缩放和平移把 x=l 映到 -1，把 x=r 映到 1。设 x'=ax+b：

$$
al+b=-1,\qquad ar+b=1.
$$

相减并代回得到：

$$
a=\frac{2}{r-l},\qquad b=-\frac{r+l}{r-l},
\qquad x'=\left(x-\frac{l+r}{2}\right)\frac{2}{r-l}.
$$

也就是先把盒子中心移到原点，再把宽度缩放到 2。Y、Z 同理；本教材选择 z=n 映到 1、z=f 映到 -1：

$$
M_{\mathrm{orth}}=
\begin{pmatrix}
\frac{2}{r-l}&0&0&-\frac{r+l}{r-l}\\
0&\frac{2}{t-b}&0&-\frac{t+b}{t-b}\\
0&0&\frac{2}{n-f}&-\frac{n+f}{n-f}\\
0&0&0&1
\end{pmatrix}.
$$

此矩阵保留了三维深度，并未真的把所有点压在一个二维平面上。绘制位置使用 X/Y，但遮挡仍然需要 Z。

### 9.4 View 矩阵：为什么基向量成为矩阵的行

相机眼睛为 e，右、上、后向的单位正交基为 u、v、w。w 与视线相反。点的相机坐标定义为：

$$
p_{\mathrm{world}}=e+x_cu+y_cv+z_cw.
$$

把基向量排成列，记 B=[u v w]，则：

$$
p_{\mathrm{world}}-e=Bp_{\mathrm{camera}},
\qquad p_{\mathrm{camera}}=B^{-1}(p_{\mathrm{world}}-e).
$$

因为 B 的列是单位正交基，B 的逆等于转置，所以：

$$
x_c=u\cdot(p-e),\quad y_c=v\cdot(p-e),\quad z_c=w\cdot(p-e).
$$

View 的行中出现 u/v/w，不是背诵规则，而是相机坐标到世界坐标这一关系的逆运算。若基不正交，不能用转置替代逆；若眼睛与目标重合或参考 up 平行视线，基构造会退化。

### 9.5 透视的几何要求：让眼睛射线变成平行线

透视可见范围是视锥截体。近面 z=n 上的观察窗口为 `[l,r] × [b,t]`，连接眼睛与窗口边界得到视锥侧面。

从眼睛原点穿过点 (x,y,z) 的线为 q(λ)=λ(x,y,z)。与近面相交要求 λz=n，因此：

$$
x'=\frac{nx}{z},\qquad y'=\frac{ny}{z}.
$$

除以 z 来自射线与近面求交的要求。此处选择近面作为虚拟成像平面是明确的设计选择，不是必须把所有针孔成像平面都放在 near 上。

如果同时让 z'=n，所有点就压在近面上，丢失前后关系。教材的做法是保留一个重新编码的 z'：同一条眼睛射线的点得到相同 x'/y'，但保留不同 z'，从而把汇聚射线变成平行于 Z 轴的线。这样透视观察就能复用之前的正交观察流程。

### 9.6 齐次坐标为什么能实现除以 z

仿射表达式 ax+by+cz+d 不能直接产生 nx/z。齐次坐标 (X,Y,Z,W) 在 W 非零时表示普通坐标 (X/W,Y/W,Z/W)。为了得到 nx/z、ny/z，可以选择 X=nx、Y=ny、W=z，先确定矩阵第一、第二、第四行：

$$
S=\begin{pmatrix}
n&0&0&0\\
0&n&0&0\\
?&?&?&?\\
0&0&1&0
\end{pmatrix}.
$$

这里将教材的透视变换暂记作 S，突出其“视锥到盒子”的职责，避免与引擎中合并后的 Projection 混淆。齐次除法与单位方向 normalize 不是同一个操作。

### 9.7 深度第三行：用近远面约束求解

要求同一深度平面上的点仍有相同深度，因此第三行不依赖 x/y。矩阵乘法分子为 Az+B，而分母已经由透视横纵关系确定为 z：

$$
z'=\frac{Az+B}{z}.
$$

为了让视锥变成原先会处理的盒子，选择近面和远面深度保持不变：

$$
\frac{An+B}{n}=n,\qquad\frac{Af+B}{f}=f.
$$

即 An+B=n²、Af+B=f²。两式相减，得到 A=n+f；代回得到 B=-nf。故：

$$
S=\begin{pmatrix}
n&0&0&0\\
0&n&0&0\\
0&0&n+f&-nf\\
0&0&1&0
\end{pmatrix},
\qquad
(x',y',z')=\left(\frac{nx}{z},\frac{ny}{z},n+f-\frac{nf}{z}\right).
$$

不能同时要求所有 z 都原样保留：那将要求 Az+B=z²，一次式不可能对所有 z 等于二次式。第三行的非线性并非随意添加，而是共用透视分母后的约束结果。

前后顺序仍保留：dz'/dz=nf/z²>0，因为 f<n<0，所以 nf>0。

### 9.8 为什么视锥确实变成了盒子

视锥右侧面满足 x/z=r/n，因此 x'=nx/z=r，变成固定的右侧面。其余侧面同理变成 x'=l、y'=b、y'=t。结合近远面不变以及深度单调性，视锥被映射到 `[l,r] × [b,t] × [f,n]`。

于是可以复用正交标准化：

$$
M_{\mathrm{perspective}}=M_{\mathrm{orth}}S,
\qquad M_{\mathrm{full}}=M_{\mathrm{viewport}}M_{\mathrm{orth}}SM_{\mathrm{camera}}.
$$

S 实现视锥到盒子的透视几何，Morth 实现盒子到标准范围的平移缩放。执行时可以合并矩阵，理解时必须先解释各自目的。矩阵乘法结果是齐次坐标，读取普通坐标时仍需除以 w；不能把这件事漏掉。

### 9.9 手算验证与每个中间空间的含义

取 n=-1、f=-5、l=b=-1、r=t=1，点 p=(1,0,-2)。S 变换后的齐次结果是 (-1,0,7,-2)，除以 w 得到 (0.5,0,-3.5)。它的横向投影缩小一半，但没有被压到近面。

再经过正交标准化：zN=(2×(-3.5)-(-6))/4=-0.25，最终为 (0.5,0,-0.25)。原始 z=-2、压盒后的 z'=-3.5、标准深度 -0.25 是不同阶段的量，不能混称“距离”。这是代数示例，不是新的 GPU 实测。

### 9.10 NDC、reversed-Z、viewport 是端点约定的具体选择

如果对压盒后的 z' 改为 near 映到 1、far 映到 0，重新解一次线性区间映射即可：

$$
d=\frac{z'-f}{n-f}=\frac{n-nf/z}{n-f}.
$$

令正的近远距离 N=-n、F=-f，正的前向距离 s=-z，则：

$$
d=\frac{NF/s-N}{F-N},\qquad\lim_{F\to\infty}d=\frac{N}{s}.
$$

这说明 reversed-Z 的倒数形式如何从透视变换与深度端点约定组合而来。改变 near/far 数字对应关系，不等于翻转世界 Z 轴；NDC 范围不决定世界坐标的左右手性。浮点 reversed-Z 的精度收益还涉及浮点数分布，是另一个需要单独解释的问题。

Viewport 同样由端点约束确定。教材采用整数像素中心，W 个像素的横向边界是 [-0.5,W-0.5]，所以：

$$
x_s=\frac W2x_N+\frac{W-1}{2}.
$$

D3D 的整数 viewport 原点下，像素中心为 i+0.5，边界为 [0,W]；再考虑 viewport 偏移以及屏幕 Y 向下：

$$
x_s=X_0+\frac W2(x_N+1),\qquad
y_s=Y_0+\frac H2(1-y_N).
$$

这是端点与方向约定不同产生的差异，不是教材公式少写了 0.5。Viewport 输出是连续屏幕坐标，不自动取整为像素索引。MinDepth/MaxDepth 是标准深度到缓冲深度的范围，不是世界单位下的 near/far。

### 9.11 对接 UE/D3D 前必须做的约定转换

- UE 世界轴为 X 前、Y 右、Z 上；本节教材相机基为右、上、后且朝 -Z 看。世界轴、相机组件局部轴、渲染 View 轴必须分别声明，不能只因为某个分量叫 Z 就认为含义相同。
- 本文采用列向量数学；CPU/HLSL 的乘法侧、矩阵内存布局和是否转置要独立核对。
- 教材的 n/f 是负坐标；引擎接口常传正距离，必须先换符号。教材齐次结果在可见区域 W=z<0，不能把这个矩阵未经调整直接交给要求正 clip.w 的 D3D 裁剪管线。相同笛卡尔投影的齐次表示，并不意味着任意符号表示都满足 API 裁剪约束。
- 现代 API 中要区分除法前四维 Clip 与除法后三维 NDC；教材部分地方对 canonical/clip/NDC 使用较宽泛的命名，对接 API 时不可因此省略这个区别。
- NDC 深度范围、near/far 对应值、viewport Y 方向、像素中心、ViewRect、投影 jitter、Translated World、深度比较方式必须统一。当前解析相机实现的运行结果不能代替矩阵版本验收。

后续实现应先逐点验证相机换基、S、Morth 的中间结果，再验证合并矩阵与解析射线一致；同时检查 near/far 与屏幕边界，不能仅凭出图相似判定推导或实现正确。
