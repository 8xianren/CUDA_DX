# PT.2 相机射线、几何求交与可见性

## 1. 本节目标

PT.1 已经证明半球立体角是 `2π`、投影立体角是 `π`、Lambert 在均匀入射下 `Lo = ρ Li`。
那些积分还没有“这条射线打到了谁”。本节把渲染方程里的 `Li(p, ωi)` 往前推一步：
先能回答可见性。

学完应能回答：

1. 求交发生在哪个空间？为什么不是 NDC，也不是 D3D12 Viewport 之后？
2. 像素中心如何变成世界空间射线 `P(t) = O + t D`？`tMin` / `tMax` 裁什么？
3. 球体、三角形、AABB 为什么是三种不同算法，而不是“三角形求交的三个变体”？生产里主流用哪一种图元、哪一种三角形测试？
4. 同一条射线穿过多个物体时，为什么必须比 `t`？自相交 epsilon 解决的是哪一类数值误差？

可运行代码：

- `learning/sandbox/path_tracing/pt02-ray-geometry/pt2_ray_geometry.cu`

诊断图（程序运行后写在源文件旁边）：

- `learning/sandbox/path_tracing/pt02-ray-geometry/results/pt2_normals.ppm`
- `learning/sandbox/path_tracing/pt02-ray-geometry/results/pt2_depth.ppm`
- `learning/sandbox/path_tracing/pt02-ray-geometry/results/pt2_primid.ppm`

本节不采样路径、不乘 BRDF、不建 BVH。PT.3 才引入蒙特卡洛；PT.9 才用加速结构
替换本节的暴力最近命中。

官方 / 标准资料：

- [PBRT v4, Camera Models](https://www.pbr-book.org/4ed/Cameras_and_Film/Camera_Coordinate_Spaces)
- [PBRT v4, Shapes](https://www.pbr-book.org/4ed/Shapes)
- [Scratchapixel, Ray-Sphere Intersection](https://www.scratchapixel.com/lessons/3d-basic-rendering/minimal-ray-tracer-rendering-simple-shapes/ray-sphere-intersection.html)
- [Möller–Trumbore 1997](https://fileadmin.cs.lth.se/cs/Personal/Tomas_Akenine-Moller/pubs/raytri_tam.pdf)

## 2. 先钉死：求交在哪个空间

着色器补充 2 已经把光栅化链条写过一遍。把它完整列出来，求交只落在其中一层：

```text
模型 / 物体空间     顶点相对模型原点。DXR 的 BLAS 通常活在这里
        ↓ Model
世界空间            ★ 本课求交发生在这里
        ↓ View
观察 / 相机空间     也可以求交（把几何变到相机前），本课不做
        ↓ Projection
裁剪空间 Clip       齐次坐标，还没除 w。不求交
        ↓ xyz / w
NDC                 透视已经把空间压扁。不求交
        ↓ Viewport 变换（RSSetViewports）
屏幕像素            2D 矩形。不求交；只决定“从哪个像素发出射线”
```

**结论先写死：本课 `intersect_sphere` / `intersect_triangle` / `intersect_aabb` 全部在世界空间做。既不是 NDC，也不是 Viewport 之后。**

像素坐标只出现在 `camera_ray` 里，用来生成世界空间射线。射线一旦生成，后面的求交再也不看像素、NDC、裁剪空间。

二次射线更明显：阴影、反射从世界空间命中点出发，根本没有对应像素，更没有 NDC。

### 2.1 为什么不能在 NDC 求交

透视除法 `ndc = clip.xyz / clip.w` 是非线性的。世界空间里：

- 球是球，半径处处相同
- 直线是直线，`t` 是欧氏距离
- 角度、`cosθ`、Lambert 的 `n · ω` 都有物理意义

进了 NDC 之后：

- 球被压成椭球，越靠近屏幕边缘越歪
- 相等的世界距离在 NDC z 上不再相等（near/far 把深度压进 `[0,1]` 或 `[-1,1]`）
- `t` 不再是米，BRDF 的余弦项会错

NDC 是光栅化拿来做覆盖测试和深度测试的归一化立方体，不是欧氏几何空间。路径追踪要的是欧氏几何，所以必须停在投影之前。

观察空间可以求交：它只是世界空间做了一次刚体变换（旋转+平移），球还是球，`t` 还是米。有的 CPU 光线追踪器会把几何变到相机空间再打。本课不这么做，避免和“已经投影”搞混。**观察空间 ≠ NDC。**

### 2.2 Viewport 有两个完全不同的意思

这是上一节讲糊的根源。同一个词指两件无关的事：

```text
D3D12 Viewport（RSSetViewports）
  把 NDC 的 xy 映射到后台缓冲区的像素矩形
  参数：TopLeftX/Y、Width/Height、MinDepth/MaxDepth
  发生在投影和透视除法之后
  光栅化才走这一步

本课 camera 里的 viewport_height / viewport_width
  虚拟胶片在世界空间里的尺寸，单位是世界单位，不是像素
  viewport_h = 2 * tan(vfov/2) * focus_distance
  胶片放在相机前方 1 个世界单位处
  用来把像素中心反推成世界空间里胶片上的一个点
```

`camera_ray` 用的是第二种。它看起来“从像素出发”，但做的是**反投影到世界**，不是“在 Viewport 变换之后的像素平面上求交”。

像素平面是 2D。球、三角形、AABB 都是 3D 物体。2D 屏幕上没有这些物体可打。

### 2.3 物体空间求交：生产里真正发生的事

网格顶点通常存在**模型空间**。生产路径不是把所有三角形先乘 Model 矩阵变到世界再打，而是：

```text
世界空间射线
    × inverse(objectToWorld)     射线变到该实例的物体空间
物体空间三角形测试               BLAS / Möller–Trumbore / 硬件单元
命中点、法线再变回世界           给 BRDF 用
```

DXR 的 TLAS 管实例变换，BLAS 管物体空间三角形。语义仍是欧氏 3D 求交，只是坐标系从世界换成了物体。**仍然不是 NDC。**

本课三个物体没有 Model 矩阵，顶点直接写世界坐标，所以求交函数吃的就是世界空间射线。

## 3. 游戏开发类比：把光栅化反过来，但停在世界空间

光栅化问：这个三角形投影到屏幕后，盖住哪些像素？
路径追踪问：这个像素朝世界射出一条射线，最先碰到谁？

同一套针孔，方向相反，而且路径追踪**不到投影那一步**：

```text
光栅化     世界点 --MVP--> 裁剪 --> NDC --> Viewport --> 像素覆盖 + 深度测试
路径追踪   像素中心 --> 世界空间胶片点 --> 世界射线 --> 世界/物体空间求交
           ↑ 只用像素当“从哪发出”
           ↑ 求交不再经过 NDC / Viewport
```

游戏里你已经见过这些亲戚，不要当成同一件事：

```text
深度缓冲 Z-Test     光栅化在 NDC/窗口空间比深度。不是射线求交。
射线检测 LineTrace  UE Gameplay 查询，通常走 Chaos，世界空间，但不是渲染积分器。
DXR Closest Hit     硬件加速结构上的最近命中。物体空间三角形测试，世界空间着色。
本课 PT.2           CPU 世界空间暴力求交，每个测试都能手算。
```

Lumen 可以用 SDF 软件追踪或 DXR 硬件追踪；UE Path Tracer 走完整 DXR pipeline。
本节先把“最近命中”做成可手算的事实，再谈加速结构。

## 4. 射线：点、方向、有效区间

一条射线不是一根无限直线。本课约定：

```text
P(t) = O + t D
D 已经单位化
t ∈ [tMin, tMax]
```

三个后果：

1. **`t` 是欧氏距离**。`D` 不单位化，`t` 就不是米，后面的深度图、自相交 epsilon
   都会按错比例缩放。
2. **`tMin > 0`**。`t=0` 是相机或表面起点本身。阴影射线、反射射线如果从命中点出发
   且 `tMin=0`，会立刻再打到自己。
3. **`tMax` 是当前最近命中**。遍历场景时，已经找到 `t=1.2` 的三角形，再测后面的
   球体可以把 `tMax` 收到 `1.2`。这既是正确性（最近命中），也是早期退出。

`tMin` / `tMax` 不是“近裁剪面 / 远裁剪面”的别名。光栅化的 near/far 裁的是投影
体积；射线的区间裁的是**这条查询自己的有效段**。相机主射线可以用很小的 `tMin`
（本课默认 `1e-4`）和很大的 `tMax`；阴影射线的 `tMax` 则是到灯的距离。

失败路径：

- `D = 0`：不能归一化。本课 `make_ray` 要求调用方传入非零方向。
- `tMin > tMax`：空区间，任何求交都应漏过。
- 设备移除、NaN：CPU 教学代码用 `fabs` 比较；生产路径追踪器必须把 NaN 当漏过，
  不能让 NaN 比较把最近命中“赢走”。

## 5. 针孔相机：把像素中心逆变换回世界空间成像平面

你的直觉是对的，先把几何钉死：

```text
世界空间里有一张矩形成像平面，立在针孔前方。
图像上的每个像素，对应这张平面上的一小块。
像素中心对应那一小块的中心点。那个中心点是世界坐标。
射线 = 从针孔射向这个世界点。
```

这就是光栅化投影的逆。光栅化问“世界点落到哪个像素”；这里问“这个像素对应成像平面上的哪个世界点”。
求交仍然在世界空间做，不是在像素平面上做。

针孔没有透镜，所以这张平面**不是光学焦平面**。光学焦平面是薄透镜里“对焦物体所在的那张面”，后面景深才用。
本课这张是虚拟胶片 / 成像平面，英文常见名字是 image plane / film plane。

### 5.1 先看正变换，再反过来

光栅化把一个世界点投到像素，本质是：

```text
世界点  --View-->  相机前方的点  --透视投影-->  NDC  --Viewport-->  像素
```

针孔相机的透视投影有一个很具体的几何含义：从针孔 `O` 看过去，世界点沿着 `O → 点` 这条线，
打在成像平面上的那个落点，就是它的像。NDC / Viewport 只是把这张矩形平面线性铺到图像的像素格子上。

所以逆变换只有两步：

```text
1. 像素中心  →  成像平面上对应的世界点 P_film     （线性，铺格子）
2. 射线      =  origin → P_film，再单位化           （透视的逆）
```

### 5.1.1 UE 怎么做：不是手摆胶片，是乘已经算好的逆矩阵

本课直接在世界里把成像平面摆出来，是为了看见几何。UE 已经有光栅化用的 `ViewProjection`，不会再手写 `tan(fov)` 摆矩形。

几何上仍是同一件事：像素对应成像平面上的一个点，从相机原点射向那个点。只是“那个点”用矩阵求回来。

先分清三条路径，不要混：

```text
Gameplay 点选 / LineTrace     CPU：屏幕像素 → 世界射线 → Chaos 物理查询
编辑器几何工具                 CPU：GeometryCore 的 watertight 三角形测试
Path Tracer / 硬件 RT 主射线   GPU：RayGen 里反投影 → DXR TraceRay
```

**Gameplay（CPU，公开 API）**

`APlayerController::DeprojectScreenPositionToWorld(ScreenX, ScreenY, WorldLocation, WorldDirection)`
把 2D 屏幕坐标变成世界空间的一个点和一个方向。文档写明：Convert 2D screen position to World Space 3D position and direction。

内部就是反投影，不是 Chaos 自己发明的相机模型。随后的 `LineTrace` 走物理场景，不是渲染积分器。

**渲染 / Path Tracer（GPU）**

UE 着色器不构造胶片矩形，而是用 View uniform 里已经算好的逆矩阵。常见量是：

```text
View.ClipToTranslatedWorld
View.SVPositionToTranslatedWorld
View.WorldCameraOrigin          或 TranslatedWorld 下的相机原点
```

`TranslatedWorld` 不是 NDC，也**不是 World Partition**。它是渲染里的相机相对坐标系：每帧把世界点平移，让相机附近落在 float 能精确表示的范围。UE 源码写死：

```text
World           = TranslatedWorld - PreViewTranslation
TranslatedWorld = World + PreViewTranslation
PreViewTranslation 通常 = -ViewOrigin     // SceneView.cpp
```

于是 `TranslatedWorldCameraOrigin = ViewOrigin + PreViewTranslation ≈ (0,0,0)`。
GPU 主射线、深度、阴影都在这个坐标系里用 `float3`。这和关卡怎么切块加载是两层事，详见 5.1.2。

主射线生成的典型步骤（Path Tracer / 硬件 RT 的 RayGen 都是这一套）：

```text
1. 像素中心（可加 TAA jitter）→ SVPosition / 视口位置
2. 线性映射到 clip / NDC：xy ∈ [-1,1]
   UE 投影约定：clip Z=1 是近平面，Z=0 是无穷远（SceneView.h 注释）
   这和 D3D12 常见的 near=0、far=1 相反，不要套 DirectX 默认
3. clip = float4(ndc.xy, 1, 1)               近平面上的齐次点
4. translated = mul(clip, View.ClipToTranslatedWorld)
   P = translated.xyz / translated.w          成像平面（近平面）上的点
5. O = View.TranslatedWorldCameraOrigin      ≈ (0,0,0)
6. D = normalize(P - O)
7. TraceRay：Origin 用世界或 Translated 原点，Direction=D
```

第 4 步就是 `inverse(ViewProjection) * ndc_point`，只是逆矩阵已经带上 PreViewTranslation。
齐次 `w` 不能省：透视的逆仍是透视，近平面上的点除完 `w` 才是欧氏点。

和本课对照：

```text
本课     手摆世界矩形，P_film 直接是世界点
UE       同一张矩形已经编进投影矩阵；乘 ClipToTranslatedWorld 把它取回来
相同机制 像素 → 成像平面上的点 → 从针孔连出去
```

UE Path Tracer **不会**在积分器里解三角形。RayGen 只负责这条世界射线；三角形测试在 DXR BLAS 里，硬件走 watertight。TAA jitter、过扫描、镜头畸变都加在第 1–2 步的 NDC 上，不改变“求交在世界/物体空间”这件事。

本课不构造投影矩阵，直接在世界里把那张矩形摆出来。代数上等价，几何上看得见。

### 5.1.2 三层不要并成两层：Origin Rebase ≠ TranslatedWorld ≠ LWC 双 float

你的对照方向对：**目标**都是“别让 GPU 的 `float` 去减两个很大的世界坐标”。但 UE4 的 Origin Rebase、渲染每帧的 TranslatedWorld、UE5 的 LWC 双 float，是三套独立机制。不能说 TranslatedWorld 就是 UE4 rebase，也不能说它就是 UE5 用两个 float 模拟 double。

IEEE 754 单精度只有 23 位尾数。绝对值越大，相邻两个可表示数的间距（ulp）越大：

```text
|x| ≈ 1          ulp ≈ 1.2e-7     毫米级场景完全够
|x| ≈ 1e5 米     ulp ≈ 0.008 米    厘米开始抖
|x| ≈ 1e6 米     ulp ≈ 0.06 米     相机和胶片点相减，低位被吃掉
```

如果 GPU 用 `float3` 直接存世界坐标，相机在 `(1000000, 0, 0)`，成像平面上的点也在附近。
两个大数相减得到射线方向时，有效数字只剩“相机附近那一点相对偏移”，方向会抖，闪烁、阴影裂缝都来了。

#### 1. World Origin Rebase（UE4 World Composition 那套，UE5 还在）

这是**真的搬世界原点**。World Settings 注释写死：

```text
World origin will shift to a camera position when camera goes far away from current origin
bEnableWorldOriginRebasing     默认 false，且 EditCondition = bEnableWorldComposition
```

实现：`UWorld::RequestNewWorldOrigin` → `SetNewWorldOrigin`。源码会：

```text
Offset = 旧原点 - 新原点
OriginOffsetThisFrame = Offset
Scene->ApplyWorldOffset(Offset)          渲染场景里的 primitive 一起搬
PhysicsScene->ApplyWorldOffset(Offset)   物理一起搬
再遍历可见 Level，把 Actor 坐标一起加 Offset
```

Gameplay 看到的世界原点变了。网络、保存、流式子关卡都要跟着对这笔平移。所以它是偶发、贵、有副作用的。UE5 默认关，World Partition 项目通常也不靠它过日子。

#### 2. TranslatedWorld（渲染每帧换原点，不搬 Actor）

这才是上次那句“平移收到 TranslatedWorld”说的东西。公式在 `SceneView.h`：

```text
World           = TranslatedWorld - PreViewTranslation
TranslatedWorld = World + PreViewTranslation
PreViewTranslation 通常 = -ViewOrigin     // SceneView.cpp，透视相机
TranslatedWorldCameraOrigin = ViewOrigin + PreViewTranslation ≈ (0,0,0)
```

几何没变，Actor 的世界坐标也不改。只是 GPU 这一帧用的 View/Projection 从“相机附近”开始算，`float3` 减法还在。

和 Origin Rebase 的共性：都让相机附近变成小坐标。
差别：Rebase 改世界；TranslatedWorld 只改这一帧着色器看到的坐标系。每帧都做，Gameplay 无感。

#### 3. LWC 双 float（UE5：两个 float 拼出接近 double 的绝对坐标）

CPU 上 UE5 的 `FVector` 已经是 `double`。GPU 没有便宜的 fp64 路径，绝对世界位置如果还要送进 shader，就拆成两个 `float`：

```text
// Engine/Source/Runtime/Core/Public/Math/DoubleFloat.h
struct FDFScalar {
    float High;   // 把 double 先转成 float，吃掉高位
    float Low;    // (double - High) 再转 float，保住残余
    // GetDouble() = (double)High + (double)Low
};
struct FDFVector3 { FVector3f High; FVector3f Low; };
```

View uniform 里因此同时有：

```text
ViewOriginHigh / ViewOriginLow
PreViewTranslationHigh / PreViewTranslationLow
TranslatedWorldCameraOrigin          ← 仍是单个 float3，相机附近用
```

这是**表示法**：一个大数拆成 High+Low。不是换原点。
主射线、深度、常规材质仍然优先走 TranslatedWorld 的单个 `float3`。只有确实需要绝对世界位置（大世界里的行星、超远物体、LWC 材质）才走 DF。

#### 对照表

```text
                 Origin Rebase              TranslatedWorld              LWC 双 float (DF)
哪一代出名       UE4 World Composition      UE4 就有，UE5 仍是主路径      UE5 LWC 才成为常规
做什么           真的移动世界原点           每帧把 GPU 坐标系挪到相机     两个 float 拼绝对坐标
改 Actor 吗      改（物理/网络/保存都跟）    不改                           不改
频率             偶发，相机离原点很远才搬    每帧                           按需
主射线 P-O       搬完后 float 暂时够用       直接在小坐标里减               一般不用 DF 做 P-O
还在吗           UE5 仍有，默认关            透视相机默认开                 shader 需要绝对位置时用
```

World Partition / 网格分区是第四层，更无关：它管磁盘和内存里哪些 Actor 现在在，不解决 `float` 减法。

所以正确说法是：

```text
TranslatedWorld  ≈  “渲染侧、每帧、不搬世界的 rebase”
Origin Rebase    =  “Gameplay 真搬世界原点”（UE4 大世界常用，UE5 默认不用）
LWC 双 float     =  “GPU 上用 High/Low 模拟 double”，和换原点正交
```

打开大世界分区，不等于 GPU 就能用绝对世界坐标做 `P - O`。关掉 Origin Rebase，TranslatedWorld 照样每帧在做。

### 5.2 这张世界平面怎么摆

只需要回答四个几何问题：

```text
针孔在哪？     origin
平面朝哪？     看向 look_at，平面垂直于视线
哪边是图像上？  world_up 决定“图像向上”
平面有多大？   垂直 FOV：在固定距离处，能看见多高的世界矩形
```

本课把平面放在针孔前方 1 个世界单位处。方向稍后单位化，这个距离只用来定平面大小，不定景深。

```text
视线后方 w = normalize(origin - look_at)     前向是 -w
相机右   u = normalize(world_up × w)
相机上   v = w × u

平面中心 = origin - w                      针孔前方 1 单位
平面高度 = 2 * tan(vfov / 2)               世界单位，不是像素
平面宽度 = 高度 * (width / height)
```

90° FOV、正方形图像：`tan(45°)=1`，平面就是边长 2 的世界正方形。
像素格子把这个正方形均匀切开。`+0.5` 只是取格子中心，不是搬到世界；搬到世界的是“这个格子在矩形里的比例”。

图像 `y=0` 在顶，矩形的 `v` 却从下往上，所以垂直方向要用 `1 - 比例`。

代码：

```text
P_film = 左下角 + 右方向 * (x+0.5)/width + 上方向 * (1 - (y+0.5)/height)
D      = normalize(P_film - origin)
```

`s`、`ty`、`horizontal`、`vertical`、`lower_left` 不是新概念，只是上面这句话的变量名：

```text
horizontal = u * 平面宽度     从左到右的世界向量
vertical   = v * 平面高度     从下到上的世界向量
lower_left = 平面中心 - horizontal/2 - vertical/2
```

### 5.3 手算核对这张图

相机在原点，看向 `-Z`，上向量 `+Y`，FOV 90°，图像 2×2。

```text
平面中心 = (0,0,-1)
平面     = x,y ∈ [-1,1]，z = -1
```

左上像素占平面左上 1/4，中心在：

```text
P_film = (-0.5, 0.5, -1)
D      = (-0.5, 0.5, -1) / √1.5
```

1×1 图像只有一个像素，中心就是平面中心 `(0,0,-1)`，方向 `(0,0,-1)`。本机两项都 PASS。

像素滤波、jitter 是 PT.3 / F.4。今天每像素中心一枪，图会有锯齿。这不是 bug。

## 6. 三种图元，三种算法；主流用哪一种

上一节最容易读错的地方：以为球体、三角形、AABB 是“三角形求交的三个变体”，
或者以为要先选一种通用算法再套到三种形状上。不是。

它们是**三种不同的隐式几何**。每种有自己的方程，所以有自己的闭式测试。
共同的只有查询本身：

```text
输入：世界空间射线  P(t) = O + t D，t ∈ [tMin, tMax]
输出：最近合法 t、命中点、几何法线、（三角形才有）重心
```

| 图元 | 几何定义 | 代入射线后变成什么 | 本课函数 |
|---|---|---|---|
| 球体 | `\|P - C\|^2 = r^2` | 一元二次方程，0/1/2 个根 | `intersect_sphere` |
| 三角形 | 三个顶点张成的平面多边形 | 3×3 线性方程组，未知数 `(t,u,v)` | `intersect_triangle` |
| AABB | 三对轴对齐平面围成的盒子 | 三对区间求交（slab） | `intersect_aabb` |

不能把球当三角形打：解析球一个二次方程就结束，三角化成几百个面既慢又不圆。
不能把三角形当 AABB 打：AABB 没有斜边，斜三角形会被盒子“加厚”。
不能把 AABB 当球打：盒子有棱有角。

### 6.1 生产里主流着色图元是三角形

游戏网格、glTF、Nanite 输入、电影资产，几乎全部是**三角形网格**。
实时光线追踪（DXR / Vulkan RT / OptiX）硬件单元加速的也是**三角形**。
所以“主流求交”这句话要拆开两层：

```text
着色几何（真正打到、要插值 UV/法线的东西）
  主流：三角形
  少数解析图元：球、圆盘、用于面积灯；毛发曲线是另一套

加速结构节点（只回答“这条射线要不要进这堆三角形”）
  主流：AABB（有时 OBB）
  不着色，只做剔除
```

本课把 AABB 也画进法线图，是为了单独验收 slab。生产 BVH 里的盒子通常不可见。
球体留下来，是因为它的二次方程最容易手算，后面当解析光源或玻璃球很方便。
真正进 glTF 网格之后，主路径会变成：AABB 剔除 → 三角形测试。

### 6.2 三角形本身也有好几代测试，主流是哪一种

三角形求交不是只有一种写法：

1. **先打平面，再投影到 2D 做内测**
   求 `t` 打无限平面，再把命中点投影到面积最大的坐标面，做 2D 包含。
   步骤多，要选投影轴，数值在掠射时差。教材早期常见，生产少用。
2. **Möller–Trumbore（1997）——本课采用，CPU 软件主流**
   一次解 `O + tD = (1-u-v)v0 + u v1 + v v2`。
   不预存平面方程，重心 `(u,v)` 和 `t` 一起出来，正好给插值用。
   Embree 的快速路径、多数教学 CPU 追踪器、很多软件 BLAS 都从它或其变体来。
3. **Watertight / 边函数（Woop, Benthin, Wald 2013）——硬件与高质量 CPU 主流**
   不把“点是否在三角形内”交给浮点重心的 `u≥0,v≥0,u+v≤1`。
   先把射线变成局部 `+Z`，再在这个 2D 投影上做边函数。共享边两侧用同一组顶点算同一条边，
   保证不会两边都漏过。DXR / RTX 三角形单元、Embree 的 watertight 模式走这一路。
   详见下面 6.4。本课不实现。

所以：

```text
本课三角形          Möller–Trumbore，CPU 上能手算、带重心
生产软件 CPU        多数仍是 MT 或 MT 的 SIMD 变体
生产硬件 RTX/DXR    watertight 边函数，你写不到，BLAS 构建时交给驱动
生产加速结构        AABB slab 做节点剔除，叶子才是三角形
```

UE Path Tracer、Unity HDRP Ray Tracing 都不会在积分器里手写 MT 当主路径。
积分器只发世界空间射线；三角形测试在 BLAS 里。本课强制手写，是为了看见查询。
相同的底层机制：欧氏 3D 里解 `O + tD` 与图元方程，取最小合法 `t`。

### 6.3 三角形求交就是解 3×3 线性方程组

光栅化对三角形做的是：投影到屏幕 → 2D 边函数 / 重心 → 深度缓冲比 z。
那是 **NDC / 像素空间** 的覆盖测试，不是射线求交。游戏开发里最常见的“另一种三角形算法”
就是这一套。路径追踪不走投影，所以不能用它。

射线打三角形要同时满足两件事：点在射线上，点在三角形平面的凸包内。写成一个方程：

```text
O + t D = (1-u-v) v0 + u v1 + v v2
        = v0 + u e1 + v e2
        其中 e1 = v1-v0，e2 = v2-v0
```

三个未知数 `(t, u, v)`，三维向量等式，正好 3 个标量方程。移项：

```text
-t D + u e1 + v e2 = O - v0

[-D  e1  e2]  [ t ]   [ O - v0 ]
              [ u ] = [        ]
              [ v ]   [        ]
```

解法有好几代，问的是**同一组未知数**：

```text
显式求逆 / 高斯消元     写出 3×3，求 M^{-1} * rhs。正确，但慢、分支多
克拉默法则              t,u,v = 三个替换行列式 / det(M)。本课这一路
Möller–Trumbore 1997    克拉默法则的向量写法：用两次叉积代替组矩阵
先打无限平面再 2D 内测  先求 t，再把命中点投影到面积最大的坐标面做包含
Watertight 边函数 2013  换一组更稳的包含测试，硬件 DXR 走这一路
光栅化边函数            投影之后的 2D 覆盖，不是射线求交
```

Möller–Trumbore **就是克拉默法则**，不是另一种几何。它不显式构造矩阵，
因为 3×3 行列式等于标量三重积 `a · (b × c)`：

```text
det(M) = det([-D, e1, e2]) = e1 · (D × e2)     （代码里的 det）
```

克拉默：把某一列换成右端，再除以 `det`。对应到代码：

```text
pvec = D × e2                  给 u 和 det 共用
tvec = O - v0                  右端
qvec = tvec × e1               给 v 和 t 共用

u = (tvec · pvec) / det        克拉默的 u
v = ( D  · qvec) / det        克拉默的 v
t = (e2  · qvec) / det        克拉默的 t
```

`|det|≈0`：射线与平面平行，方程组退化，漏过。
命中还要求 `u≥0, v≥0, u+v≤1`，且 `t ∈ [tMin, tMax]`。
`(1-u-v, u, v)` 分别是 `v0, v1, v2` 的权重。

和光栅化边函数是代数亲戚（都在问重心是否在三角形内），坐标系不同：
这里的 `(u,v)` 是**世界空间三角形上的重心**，不是屏幕像素里的重心。

### 6.3.1 边函数回忆：光栅化那套到底在算什么

边函数是 2D 有向面积，不是 3D 射线方程。问的是：平面上的点 `P` 在有向边 `A→B` 的哪一侧。

```text
E_AB(P) = (B.x - A.x)(P.y - A.y) - (B.y - A.y)(P.x - A.x)
        = 2 * 有向面积(△ABP)
```

几何：

```text
E > 0   P 在边的左侧（约定 CCW 三角形的内侧）
E = 0   P 在边上
E < 0   P 在边的右侧（外侧）
```

三角形三条边各算一次。点在三角形内，当且仅当三个值同号（含零）：

```text
E_AB(P) ≥ 0 且 E_BC(P) ≥ 0 且 E_CA(P) ≥ 0     // CCW，含边
```

重心就是把边函数除掉三角形面积：

```text
area = E_AB(C)                 整个三角形的 2 倍面积
α    = E_BC(P) / area         顶点 A 的权重
β    = E_CA(P) / area         顶点 B 的权重
γ    = E_AB(P) / area         顶点 C 的权重
α + β + γ = 1
```

光栅化硬件对每个像素中心（或采样点）算这三条。`E=0` 的共享边用填充规则（top-left）判给其中一个三角形，所以屏幕上也不会漏缝。这就是光栅化自己的 watertight。

和射线求交的关系：

```text
光栅化边函数     所有三角形投到同一张相机屏幕；P 是像素
本课 MT          不投影；3D 克拉默，第三条边用 u+v≤1
Watertight 2013  每条射线自己的 +Z 平面上做边函数；P 永远是 (0,0)
```

三者问的都是“重心在不在三角形内”。坐标系不同，不能把屏幕边函数拿来打世界射线。

### 6.4 Watertight：Woop / Benthin / Wald 2013 到底在算什么

论文：[Watertight Ray/Triangle Intersection, JCGT 2013](https://jcgt.org/published/0002/01/05/)

Watertight 不是另一种三角形方程。未知数仍是 `(t, u, v)`。它修的是：**相邻三角形共享边、共享顶点时，浮点不能两边都漏。**

#### 为什么 Möller–Trumbore 会漏缝

MT 用克拉默算出 `u, v`，第三条边用便宜的 `u + v ≤ 1` 代替独立边测试。论文明确写了：凡是用这个技巧的算法，都无法保证邻接边 watertight——同一条共享边，在左边三角形里走 `u+v`，在右边三角形里走另一条边的 `u` 或 `v`，浮点舍入可以一正一负，两边都判在外。

共享边还经常方向相反（`v1→v2` vs `v2→v1`）。如果边测试对 `a×b` 和 `b×a` 的浮点结果不反交换，又是一条裂缝来源。

先求世界命中点再投影到 xy/xz/yz 做 2D 内测（Badouel 一类）也不行：命中点依赖**整个三角形**，不只依赖共享边，邻接两边算出来的“同一条边”不是同一组运算。

单个孤立三角形看不出来。闭合网格、细长针状三角、远离原点的小三角才会爆：背景漏光、阴影亮线。本课一个三角形测不出。

#### 算法分两阶段

**阶段 1：只依赖这条射线的仿射变换。** 把射线变成单位射线 `O'=(0,0,0), D'=(0,0,1)`。变换对这条射线打到的所有三角形都相同，所以邻接三角形被送到同一套 2D 坐标里。

论文用平移 + 剪切 + 缩放，不用旋转：舍入更小，也更快。

```text
1. 选 |D| 最大的轴当局部 Z（维度重命名，保持绕向）
   若 Dz < 0，再交换 x/y，避免剪切把三角形绕向翻掉
2. 顶点先减射线原点：  A - P, B - P, C - P
3. 再乘剪切缩放矩阵（以 |Dz| 最大为例）：

       [ 1  0  -Dx/Dz ]
   M = [ 0  1  -Dy/Dz ]
       [ 0  0   1/Dz  ]

   A' = M (A - P),  B'、C' 同样
```

几何直观：站在射线原点，把视线剪成局部 `+Z`。三角形三个顶点落到这个坐标系后，射线就是“从原点沿 +Z 打去”。剩下的包含测试变成 **xy 平面上原点 (0,0) 在不在三角形投影里**。

这和光栅化边函数像，但光栅化把所有三角形投到**同一张相机屏幕**；这里每条射线有自己的 +Z，阴影/反射射线也能用。

**阶段 2：三条独立的 2D 边测试，得到未归一化重心。** `D'=(0,0,1)` 时三重积退化成：

```text
U = C'x B'y - C'y B'x     对应顶点 A 的权重（对边 BC）
V = A'x C'y - A'y C'x     对应顶点 B 的权重（对边 CA）
W = B'x A'y - B'y A'x     对应顶点 C 的权重（对边 AB）
```

每条边只用它自己的两个顶点。共享边 `AB` 在两个三角形里用的是同一对坐标、同一种 `x1 y2 - y1 x2`。

```text
背面剔除版：U<0 或 V<0 或 W<0  → 漏过
双面版：有的 <0 且有的 >0     → 漏过（穿过边的外侧）
边测试恰好 = 0               → 算在内（关键）

det = U + V + W
det = 0                       → 共面或退化，本算法当漏过

T = U A'z + V B'z + W C'z     未归一化的 t
先用 T 和 det * t_hit 做深度测试，通过后再除：
u = U/det, v = V/det, w = W/det, t = T/det
```

`u+v≤1` 被丢掉了。第三条边是真的边测试 `W`，不是 `1-u-v` 的代数简化。这是和 MT 最大的结构差别。

#### 为什么这样能 watertight

论文用 IEEE 754：乘法先按无限精度算再舍入；任何舍入模式都保持序，`x ≥ y` 推出 `round(x) ≥ round(y)`。于是：

```text
精确运算判在内  →  浮点也判在内
浮点判在外      →  精确运算也在外
两个乘积舍入后相等（边 = 0）→  无法判断真实哪一侧，保守算命中
```

边上和顶点上不会漏。漏光比误报更难看，所以宁可保守。

`det=0` 的共面射线被当漏过，几何上不严格；论文的理由是：贴着三角形平面穿过去的射线，会打到邻居。退化成点或线段的三角形三条边都是 0，没有这个测试会“所有射线都命中”。

单精度边测试为 0 时，论文允许回退双精度：两个 float 的乘积能精确放进 double 的 53 位尾数。他们测下来大约百万次求交才遇到一次。**整段算法改用 double 不能从根上解决 watertight**，只是把裂缝变稀。

因为边决策发生在变换后的三角形上，世界空间里的 AABB 必须略微胀开，否则保守命中可能落在未胀开的盒子外面。这是 BVH 的事，不是积分器的事。

#### 和本课 / 引擎对照

```text
               Möller–Trumbore              Watertight 2013
解什么         (t,u,v)                       同一组 (t,u,v)
怎么解         3D 克拉默 / 三重积            先把射线变成 +Z，再 2D 边测试
第三条边       u+v ≤ 1（便宜，不 watertight） 独立的 W = B'x A'y - B'y A'x
边 = 0         随实现                        必须算在内
共面           |det|≈0 漏过                  det=0 漏过（靠邻居补）
保守性         无                            有；BVH 盒子要胀
谁用           本课、Embree 快速路径         Embree watertight、DXR/RTX 硬件
```

UE Path Tracer 的积分器看不见这一层。GPU 主路径是 DXR，三角形测试在 BLAS / 硬件单元。CPU 几何工具则有 `TIntrRay3Triangle3::FindWatertightIntersectionInternal`（GeometryCore），和渲染器不是同一条代码。

本课继续用 MT：一个三角形、手算克拉默更清楚。闭合 glTF 网格再换成 watertight。

## 7. 球体：二次方程

射线打到球面 `|O + t D - C|^2 = r^2`。`D` 单位化后：

```text
b = D · (O - C)
c = |O - C|^2 - r^2
Δ = b² - c
```

```text
Δ < 0   漏过
Δ = 0   擦边，一个根
Δ > 0   近根 t = -b - √Δ，远根 t = -b + √Δ
```

有效根必须落在 `[tMin, tMax]`。常见四种：

1. **外部正面**：近根合法。法线 `(P - C) / r` 指向外侧，`n · (-D) > 0`。
2. **`tMin` 裁掉近根**：从球外出发但起点已经越过前表面，或阴影射线跳过自己。
   改用远根。远根是背面，`front_face = false`。
3. **从内部出发**：近根为负，远根是出去的那面。
4. **擦边**：`Δ = 0`。本课手算：原点 `(0,1,0)` 打向 `-Z`，球心 `(0,0,-2)` 半径 1，
   `t = 2`，点 `(0,1,-2)`。

本课手算主射线：球心 `(0,0,-2)`，半径 1，原点在原点沿 `-Z`：

```text
(t - 1)(t - 3) = 0
近根 t = 1，点 (0,0,-1)，外侧法线 (0,0,1)
```

`tMin = 1.5` 时近根被裁，远根 `t = 3`，背面。

## 8. 三角形：同一方程组的代码路径

上一节已经说明：射线打三角形就是解 `(t,u,v)`。这里只把代码和手算对上。

```text
det = e1 · (D × e2)
```

`|det| ≈ 0`：射线与三角形平面平行（含共面）。共面时本课直接漏过。薄片数值上
几乎没有厚度，共面命中不稳定，生产代码同样当漏过或改用更稳的 Watertight
三角形测试。那是后话。

重心坐标：

```text
P = (1 - u - v) v0 + u v1 + v v2
```

命中要求 `u ≥ 0`、`v ≥ 0`、`u + v ≤ 1`，且 `t ∈ [tMin, tMax]`。
`(1-u-v, u, v)` 分别是 `v0, v1, v2` 的权重。插值法线、UV、切线都用这组权重。
本节只验证重心本身，不插值属性。

法线 `n = normalize(e1 × e2)`，右手螺旋。本课**不背面剔除**：透射、阴影射线
都可能从背面进来。只标记 `front_face = n · (-D) > 0`。光栅化 PSO 的 CullMode
是另一套规则，不要搬过来。

手算：`A=(0,1,-1), B=(-1,-1,-1), C=(1,-1,-1)`，沿 `-Z` 打 `(0,0,-1)`：

```text
t = 1
bary = (0.5, 0.25, 0.25)
n = (0, 0, 1)
front_face = true
```

从 `(0,0,-2)` 沿 `+Z` 打回来：同一个点，`front_face = false`。
射线躺在 `z = -1` 平面上：平行，漏过。

## 9. AABB：三对 slab

轴对齐盒子是三对平行平面。每对把射线裁成 `[t_enter, t_exit]`，三段求交。
空集就是漏过。

某轴方向分量 ≈ 0：射线平行于该对平面。原点在 slab 外则漏过，在内则这轴不裁。

**不要把 `tMin` 当成进入时间的初值。** `tMin` 是射线有效区间。原点在盒子里时
真正的 `t_enter` 为负；若用 `tMin` 当初值，会把起点本身当成墙。本课先算未经
裁剪的进入/离开，再和 `[tMin, tMax]` 求交：

```text
从外面进来：最近墙 = t_enter
从里面出去：t_enter < tMin，最近墙 = t_exit
```

手算：盒子 `[-0.5,-0.5,-2.5] .. [0.5,0.5,-1.5]`，沿 `-Z`：

```text
前墙 z = -1.5，t = 1.5，法线 +Z
原点在盒内 (0,0,-2) 沿 -Z：离开 t = 0.5
平行且 X 在盒子外：漏过
```

AABB 法线按命中点离哪块墙最近估计。这是教学用的轴对齐法线，不是解析梯度。
BVH 里的 AABB 通常只做**包围体剔除**，不作为着色几何；真正着色的是里面的
三角形/球体。本节把 AABB 当可见物体，是为了单独验收 slab。

## 10. 最近命中与自相交

`closest_hit` 不是“三个 if 都跑完取最小”。每命中一次就把 `tmax` 收到这个 `t`：

```text
shrinking.tmax = candidate.t
```

后面的图元如果更远，会被自己的 `t > tmax` 裁掉。本课三个物体时，沿 `-Z`：

```text
三角形 t = 1
球体   t = 1   （和三角形同一点，但三角形先写入后被自己替换？不：
                 手算场景里三角形在 z=-1，球体近根也在 z=-1。
                 代码先测球体再测三角形；两者 t 相同，后写入者覆盖。
                 验收场景把三角形当“更近或同样近的表面”，prim_id 以
                 三角形为准是因为第二次写入。真正的最近命中必须在 t
                 严格更小时才替换；相等时要有稳定规则。）
AABB   t = 1.5
```

手算主场景里三角形和球体近根都是 `t=1`。代码先测球体、再测三角形，相等时
后写入覆盖，验收期望 `prim_id == 2`。这是**稳定次序**，不是“三角形更近”。
去掉三角形后，球体 `t=1` 仍比 AABB `t=1.5` 更近。不要把“先写的物体”和
“更近的物体”混为一谈。

自相交是另一件事。从球体正面命中点沿同一方向再出发：

```text
tMin = 0      立刻再打到同一点，t ≈ 0
tMin = 1e-4   跳过表面，打到背面 t ≈ 2
```

这不是物理上的第二层表面，是浮点把“刚好在面上”算成“还在面里或刚出面”。
阴影射线、反射射线都必须带 `tMin`。epsilon 太大：薄物体被戳穿，阴影漏光。
epsilon 为 0：表面长痤疮，阴影斑点。本课 `1e-4` 对单位尺度场景够用；世界很大
或很小就要改成相对 epsilon（相对 `t` 或相对原点到场景尺度）。PT.9 再谈。

`front_face` 不翻转几何法线。着色时 Lambert 用 `n · ωi`，背面是负的，积半球
时本来就该是 0。需要双面材质再翻转。DXR 的 `HitKind` 是同一信息的硬件版。

## 11. 代码在测什么

文件：`learning/sandbox/path_tracing/pt02-ray-geometry/pt2_ray_geometry.cu`

相机基向量：

```179:191:learning/sandbox/path_tracing/pt02-ray-geometry/pt2_ray_geometry.cu
  const Vec3 w = normalize(origin - look_at);
  const Vec3 u = normalize(cross(world_up, w));
  const Vec3 v = cross(w, u);
  ...
  cam.lower_left = origin - cam.horizontal * 0.5f - cam.vertical * 0.5f - w;
```

球体近/远根：

```227:242:learning/sandbox/path_tracing/pt02-ray-geometry/pt2_ray_geometry.cu
  float t = -b - sqrt_disc;  // 较近根
  if (t < ray.tmin || t > ray.tmax) {
    t = -b + sqrt_disc;
    ...
  }
  const Vec3 n = (p - sphere.center) * (1.0f / sphere.radius);
```

三角形重心：

```261:286:learning/sandbox/path_tracing/pt02-ray-geometry/pt2_ray_geometry.cu
  const float det = dot(e1, pvec);
  if (absf(det) < 1.0e-8f) {
    return false;  // 平行或共面
  }
  ...
  finish_hit(hit, ray, n, tri.prim_id, PrimType::Triangle, v3(1.0f - u - v, u, v));
```

最近命中收缩 `tmax`：

```363:381:learning/sandbox/path_tracing/pt02-ray-geometry/pt2_ray_geometry.cu
  if (intersect_sphere(shrinking, scene.sphere, &candidate)) {
    shrinking.tmax = candidate.t;
    *hit = candidate;
  }
```

诊断图 64×64：法线编码为 `n*0.5+0.5`，深度用 `1 - t/6` 压成灰度，primitive ID
用红/绿/蓝。本机覆盖：

```text
miss=3275  sphere=272  triangle=141  aabb=408
pixel (32,32) hits sphere
```

漏过必须占大多数：FOV 90° 的相机看着三个小物体，背景是空的。如果 miss=0，
说明求交把空气也算命中了。

## 12. 本机实测

```text
.\build.ps1 path_tracing\pt02-ray-geometry\pt2_ray_geometry.cu

camera u/v/w, 1x1 中心 -Z, 2x2 像素 (0,0)     PASS
sphere t=1 / tmin 裁近根 t=3 / miss / graze   PASS
triangle bary=(0.5,0.25,0.25) / 平行 / 背面    PASS
AABB t=1.5 / miss / 平行 / 内部离开 t=0.5     PASS
closest hit / 自相交 tmin=0 与 1e-4           PASS
64x64 三张 PPM + 中心像素打到球               PASS

29 passed, 0 failed
PT.2 ray geometry: PASS
```

## 13. 商业引擎 vs 本课

| | UE5 / 生产路径 | 本课 PT.2 |
|---|---|---|
| 相机射线 | View 逆矩阵 × NDC，带 jitter / TAA / 过扫描 | 手写针孔，像素中心，无 jitter |
| 求交空间 | 物体空间三角形（BLAS）+ 世界空间着色；不是 NDC | 世界空间，无 Model 矩阵 |
| 着色图元 | 三角形为主；球/曲线是特例 | 球 + 三角形 + 当物体画的 AABB |
| 三角形测试 | DXR watertight 边函数，积分器看不见 | 手写 Möller–Trumbore |
| 加速节点 | BVH 的 AABB slab，通常不着色 | AABB 当可见盒子验收 slab |
| 最近命中 | DXR Closest Hit shader；任何命中 Any Hit | `closest_hit` 收缩 tmax |
| 自相交 | 世界空间 bias、射线 TMin、或 RTX 的 tmin | 固定 `1e-4` |
| 背面 | 网格有 Cull；DXR 可 Cull 或双面 | 不剔除，只标 `front_face` |

相同的底层机制：世界空间射线 `O + t D`，合法区间 `[tMin, tMax]`，最近命中是
最小合法 `t`。引擎用加速结构和硬件遍历逼近同一查询；本课先把查询本身算对。

Unity HDRP Ray Tracing、UE Path Tracer 都不会在积分器里手写 Möller–Trumbore
作为主路径；那是 BLAS 构建时已经交给 DXR。教学必须先看见这个函数，否则
“硬件命中”会变成黑盒。

## 14. 本节明确暂缓

- **像素内随机样本 / 滤波**：PT.3。今天每像素中心一枪。
- **BRDF、余弦、吞吐量**：PT.4 起。命中点还没有颜色。
- **阴影射线到灯**：PT.5。`tMax` 将变成到灯的距离。
- **BVH / DXR**：PT.9。三个图元不需要加速结构；一千个三角形才需要。
- **Watertight 三角形、相对 epsilon、运动模糊**：生产细节，需要时再补。
- **D3D12 显示这三张 PPM**：PT.10。现在用文件查看器看即可。

## 15. 小结

```text
求交在世界空间（生产可在物体空间）。不是 NDC，不是 Viewport 之后
像素只生成射线；二次射线甚至没有像素
P(t) = O + t D，D 单位化，t ∈ [tMin, tMax]
三种图元三种方程：球=二次方程，三角形=线性(t,u,v)，AABB=slab
着色主流是三角形；加速结构主流是 AABB；本课三角形用 Möller–Trumbore
硬件 RTX/DXR 用 watertight 边函数，积分器里看不见
最近命中比的是 t；tMin=0 会自相交
```

## 16. 自测题

1. 像素中心 `(x+0.5, y+0.5)` 是世界坐标吗？第一次出现世界点的是哪一步？2×2 左上像素的 `on_film` 是多少？
2. 求交在 NDC、Viewport 之后，还是世界空间？阴影射线有没有像素？
3. 射线打三角形要解哪三个未知数？Möller–Trumbore 和克拉默法则是什么关系？光栅化边函数为什么不能拿来做这件事？
4. 从命中点沿入射方向再追踪，`tMin = 0` 和 `tMin = 1e-4` 分别打到什么？这和 ResourceBarrier 有关系吗？
