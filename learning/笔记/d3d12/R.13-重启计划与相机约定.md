# R.13 重启计划与相机约定

2026-10-10：学习者要求重启，随后完成R.13.1–3。2026-10-13完成R.13.4命中属性与法线，并继续完成R.13.5矩形灯NEE线性成像、白炉及8组GPU/CPU对照，详见`R.13.5-Lambert矩形灯NEE与线性光照图.md`。2026-10-14继续完成R.13.6像素采样、GPU线性累积与多种子误差验证，以及R.13.7历史有效性与重置，详见对应小节笔记。2026-10-15完成R.13.8a SDR显示变换与sRGB编码的CPU参考和数值实验；同日完成R.13.8b GPU显示通道、交换链与96帧窗口验收；随后完成R.13.8c窗口输出resize、最小化恢复与全章回归；当前内部网格固定，下一章C.1 glTF对象模型。旧版基向量相机保留对照。

## 1. 目标与课程顺序

目标：用一套明确定义的相机/场景数据，生成 DXR 主射线，读取表面属性，估计 Lambert 直接光，再逐帧在线性 HDR 中平均并显示。形成相机→场景求交→光照估计→累积→显示的完整链路。采用 UE 风格的机制组织，不冒称复刻某个 UE 版本的私有 shader，也不引入整个 UE 工程。

1. R.13.1 世界/相机/视图坐标与 View/InvView；先做纯数学往返验证。
2. R.13.2 Projection、reversed-Z、ViewRect、逆投影与裁剪；闭环验证世界点→像素→射线。
3. R.13.3 相机常量布局和 DXR 接入；逐像素对照独立解析参考。
4. R.13.4 命中属性/法线与诊断图；世界法线、视图深度、NDC 深度各自解释。
5. R.13.5 Lambert 和矩形灯 NEE 成像；先固定随机样本验证单帧数值。
6. R.13.6 像素面积采样、采样维度、线性 HDR 逐帧平均和收敛统计。
7. R.13.7 History 有效性与 reset；变化的是积分目标还是仅样本序号，分别处理。
8. R.13.8 显示变换、真实窗口、resize/资源同步和全章验收。

每次只推进一个小节中的一个完整问题。先说明前提，再推导、实现、实测。验证产物详见主计划 R.13 表格。

## 2. 新版统一约定（设计决定，尚非已实现状态）

|项目|约定及边界|
|---|---|
|世界轴|采用 UE 风格：+X 前、+Y 右、+Z 上，左手世界轴约定。旧 demo 为 Y-up，迁移时转换场景/灯/法线/相机，不能只改变量名|
|世界单位|本教学场景明确 1 单位=1 米；不声称等于 UE 默认内容单位。近距离等所有参数统一用此单位|
|视图轴|+x 右、+y 上、+z 前；世界轴与视图轴是不同空间约定|
|数学约定|新版统一行向量：pClip=pWorld*View*Projection，InvViewProjection=inverse(View*Projection)。上一轮列向量讲解只是另一套合法约定，新版不可混用|
|存储与 shader|CPU 按行保存 4×4 float；HLSL 显式 row_major，使用 mul(v,M)。行向量数学与按行存储分别声明，不认为二者互相必然推出。DXR 实例 Transform 仍遵从其 API 的 3×4 布局，需要明确转换|
|镜头|透视针孔，对称视锥，垂直 FOV，方形像素；无畸变、景深和运动模糊。偏心/正交先讲差异，暂不实现完整接口|
|投影|D3D NDC x/y 范围 [-1,1]，z 范围 [0,1]；基线采用 reversed-Z、near=0.1 米、无限远透视投影。数学无穷远不代表 DXR TMax 可无限，实际追踪上限另设有限值并声明|
|视口|像素坐标先换到 ViewRect 局部；uv=(localPixel+sampleOffset)/ViewSize。样本偏移初始(0.5,0.5)；纹理尺寸、ViewRect 尺寸、Dispatch 尺寸不默认相等|
|逆投影|以 near 的 zN=1 得有限近面点；H=mul(float4(ndcXY,1,1),InvViewProjection)，Q=H.xyz/H.w；从相机 E 向 Q 发单位方向。区分齐次除法和向量单位化|
|裁剪|为了对齐光栅 near，射线从 E 出发且 tMin=near/dot(D,F)。有限 tMax 是独立追踪距离上限，不称为投影 far；专测离轴区别|
|采样|R.13.1–5 关闭 jitter。R.13.6 将像素子采样放在像素位置，投影矩阵保持无 jitter；若演示矩阵 jitter，须验证等价并禁止叠加两次|
|世界位置精度|首版使用小场景绝对世界 float。讲清 UE Translated World 的用途及坐标一致性，但暂不实现 LWC；若后续引入，TLAS 和射线必须采用一致基准|
|辐亮度与显示|积分/累积使用线性浮点；曝光/tone mapping/输出编码随后执行。改变后处理曝光不必清空未曝光的线性历史；改变物理光源强度则需要 reset|

必要输入校验：非空 ViewRect、0<FOV<180 度、near>0、相机位置与目标不重合、参考 up 不平行前向、矩阵可逆；反投影有限点检查 w 和非有限值。不能以 normalize 掩盖零向量或奇异矩阵。

## 3. 开篇：同一条成像关系的两个方向

光栅正向：世界点→View→视图点→Projection→齐次裁剪坐标→除以 w→NDC→Viewport→像素。

光追逆向：像素样本→逆 Viewport 得 NDC xy→选择近面深度→逆 VP→齐次除法得世界近面点→从相机到近面点的射线。

只有屏幕 xy 不能恢复唯一世界点；透视投影丢失了沿射线的深度。选 near 是选取同一条射线上的一个有限参考点，不是宣称场景表面在 near，也不需要先读深度缓冲。DXR 求交随后决定最近表面位置。

新版不再用“把成像平面放到前方 1”作为主接口。该参数化仍用于独立解析验证；主接口由明确的 View/Projection/ViewRect 定义。近面位置变化且 FOV 不变时，同一像素的主射线方向不变，但允许命中的近端范围改变。

## 4. 验证与已有代码的关系

旧 dxr_camera GPU 测试记录仍有效，仅证明旧配置下实现与其 CPU 参考一致，不能证明新矩阵流程已实现。dxr_area 复用 R.12 NEE 公式和测试案例；dxr_window 复用 R.11 窗口/同步经验。正式主线逐节形成连续实现，独立参考负责交叉验证，不将多个临时程序的存在当成一套完整渲染器。

数学检查先于图像；几何诊断先于光照；固定同样本比较先于统计收敛。单次增加样本后的误差不保证单调下降，评估需指定参考、误差度量、种子与容差。白炉检查限定无额外遮挡、常量入射环境下 Lambert Lo=rho*Li，不把“有背景颜色”当作“环境参与照明”。

重规划时仅更新文档；随后R.13.1–2完成CPU数学验证，R.13.3的新版dxr_view shader已由DXC编译并在RTX5070实际执行。相机/帧资源通过不代表完整成像、累积和窗口已完成。

## 官方对照

- [UE FViewMatrices](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/FViewMatrices)：View/Projection、逆变换、jitter 和 Translated World。
- [UE 坐标系统](https://dev.epicgames.com/documentation/unreal-engine/coordinate-system-and-spaces-in-unreal-engine)：世界轴与空间。
- [DirectXMath 约定](https://learn.microsoft.com/en-us/windows/win32/dxmath/pg-xnamath-getting-started)：CPU 矩阵和向量约定。教学 shader 显式声明布局，不依赖默认布局猜测。
