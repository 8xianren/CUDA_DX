# R.13.4 从命中约束推导位置与法线

2026-10-13。继续新版R.13矩阵相机和双槽帧资源主线。教学顺序按“问题→假设→约束→求解→代码→验证”，本节推导表面位置与法线。实际代码为扩展后的dxr_view，不另建一套相机。

## 1. 上节答案

128B是有效参数大小，256B是CBV槽地址对齐步长；绑定root CBV记录GPU地址，不冻结数据，覆盖前必须完成对应Fence；root索引2指params[2]，该项ShaderRegister=0所以映射b0。

## 2. 几何问题与假设

GPU已经知道最近命中哪个实例/三角形及其参数t，接下来要得到世界位置、几何法线、可插值属性和深度。设三角形非退化；物体变换为可逆仿射；本节三实例行列式均正；世界+X前/+Y右/+Z上；世界主射线方向单位化；保留原索引绕序，不自动faceforward。

只用一个BLAS内一个geometry、uint32索引和float3顶点位置，三个TLAS实例共享VB/IB/HitGroup。一般引擎还需要由实例和geometry寻址各网格属性；本课没有假设PrimitiveIndex是整个场景全局三角形编号。

## 3. 从二维平面坐标推导重心权重

三角形顶点A、B、C的两条独立边e1=B-A、e2=C-A张成其平面。任意平面点Q=A+u e1+v e2，展开得Q=(1-u-v)A+uB+vC，因此三个权重是(1-u-v,u,v)。三角形内部要求u>=0、v>=0、u+v<=1；权重和为1保证仿射平移只施加一次。

射线命中必须同时满足Q=O+tD。于是约束方程是O+tD=A+u(B-A)+v(C-A)。这是关于t/u/v的三元线性系统；DXR三角形求交返回相应结果，CPU参考用独立double Moller-Trumbore（标量三重积形式）求解六个三角形。

BuiltInTriangleIntersectionAttributes的barycentrics给u/v；不是纹理UV，不是三个完整权重。它已经来自三维三角形求交，不再额外做光栅屏幕插值的透视校正。UV、颜色和顶点法线等属性可以用这三个权重插值，但本节实际VB只有位置。

## 4. 原始顶点和两条世界位置重建路径

PrimitiveIndex()返回当前geometry内三角形序号p。每三角形3个uint32索引，每项4B，所以ByteAddressBuffer.Load3(p*12)读对应的3个顶点编号。StructuredBuffer<float3>用这些编号读取局部位置，stride12。这里不是cbuffer的float3打包规则。

BLAS接口不替shader暴露可索引的原始顶点属性。VB/IB须另绑定t1/t2，且应用维持其生命周期。

路径一：Qray=WorldRayOrigin()+RayTCurrent()*WorldRayDirection()。因为本课世界D单位化，t是米；一般未单位化时t只是参数。DXR物体空间方向在非均匀缩放下不保证单位长度，不应擅自normalize后继续使用原t。

路径二：Qobj=(1-u-v)A+uB+vC，Qworld=ObjectToWorld(Qobj)。仿射变换保持这组重心权重，也可先变换三个顶点再插值。两条路径应在浮点误差内一致，可发现索引、stride、实例变换、重心顺序等错误。

ObjectToWorld3x4返回3×4矩阵，此接口按mul(M,float4(p,1))计算位置。CPU DirectXMath行向量4×4转写D3D12实例Transform时，代码明确做out.m[i][j]=raw.m[j][i]，不能因相机使用row_major就把不同API的矩阵直接混用。

## 5. 从垂直约束推导几何法线

要找n满足n·e1=0、n·e2=0。两条边独立时解空间是一条直线，因此n与e1×e2平行。规定按索引A→B→C选择正负，得到ng=normalize((B-A)×(C-A))。交换B/C会翻转符号；零面积三角形不能normalize零叉积。

代码先把A/B/C变到世界，再对世界边叉积，直接得到世界几何法线。这条路径自动涵盖本课旋转和非均匀缩放。法线伪彩色采用0.5*n+0.5，不是光照强度。

## 6. 从保持垂直推导逆转置

本节继续行向量约定，令物体线性变换为A（3×3），切向量e'=eA。原法线n满足en^T=0。要求新法线n'满足eA(n')^T=0。

可令A(n')^T=n^T，解出(n')^T=A^-1 n^T，即n'=n A^-T。这里选择了一个未归一化解；满足垂直约束的任何非零比例都可，最后再单位化。矩阵必须可逆。平移不参与边/法线方向的变换。

反例：e=(1,1,0)，n=(1,-1,0)，A=diag(2,1,1)。e'=(2,1,0)。错误nA=(2,-1,0)，点积=3；正确nA^-T=(.5,-1,0)，点积=0。归一化只改变长度，不能把非零点积的方向修复成垂直。

shader取ObjectToWorld3x4的列向量线性块B=A^T，WorldToObject3x4左上块就是B^-1=A^-T。因此mul(no,(float3x3)WorldToObject3x4())正好计算行向量nA^-T，并非忘记转置。保留显式转置时也可以写等价列向量式B^-T n。

本课det(A)>0，逆转置局部几何法线与世界边叉积方向一致。若det(A)<0，镜像会翻转绕序法线，需明确方向政策并考虑行列式符号；逆转置仍保持垂直，不能因两法线符号相反就说垂直变换错误。本课未实现负尺度实例测试。

几何法线ng由真实三角形决定。着色法线ns可来自插值顶点法线与法线贴图，它表达期望的着色朝向，不必垂直当前三角形。若已有顶点法线，可先插值未归一化向量，再施加同一逆转置并归一化；不要先把每个变换结果各自单位化再声称与插值完全等价。本节演示实际使用ng，不将三块平面伪称为平滑曲面材质。生产引擎还会处理切线空间、双面材质、镜像和法线贴图，留在材质/glTF章节。

## 7. 三种深度的联系

单位世界D下Q=E+tD，前向深度zv=(Q-E)·F=t(D·F)。本课投影的NDC深度zn=near/zv。它们分别是沿射线距离、前向距离、投影深度；不能直接互换。GPU输出zv和zn，CPU分别用独立求交位置检查。

深度图显示的是zn*20后截到[0,1]，只是放大便于观察；原始输出未乘20。距离图显示clamp((10-t)/10,0,1)。两个图均不是新的深度缓冲，也未走HDR显示管线。Miss在图中使用背景色，不能用未初始化位置计算深度。

## 8. 数据、绑定与同步

View cbuffer仍128B，两槽各256B，Fence生命周期沿用R.13.3。新增root参数3 SRV t1=VB、4 SRV t2=IB；root2仍是CBV b0。5个root descriptor共10 DWORD。

SetComputeRootShaderResourceView(UINT RootParameterIndex,D3D12_GPU_VIRTUAL_ADDRESS BufferLocation)绑定GPU地址，本课无需descriptor heap。shader声明决定结构化顶点的12B stride；ByteAddressBuffer.Load3(uint address)读连续三个uint，address为4B对齐字节偏移。

VB和IB在Upload/GENERIC_READ中创建，本节同时作为BLAS构建输入和ClosestHit SRV；构建完成不能据此释放shader仍要读取的数据。三个实例和单一几何都共享它们，直到全部帧Fence完成才结束生命周期。

内建接口均无参数：uint PrimitiveIndex()、uint InstanceID()、float RayTCurrent()、float3 WorldRayOrigin()/WorldRayDirection()、float3x4 ObjectToWorld3x4()/WorldToObject3x4()。它们取当前DXR调用上下文，不是应用分配的属性buffer；其可用shader阶段遵从DXR接口规则，本节在ClosestHit中使用。

payload从8B扩为5个float4+uint，共84B，对应State Object MaxPayloadSizeInBytes=84；三角形属性仍8B，最大TraceRay递归深度仍1。结果buffer为原48B射线/序号加5个float4，总stride128；DXC dump已核验。大的payload用于教学诊断，不能称为生产性能最优设计。

失败检查覆盖已有API/HRESULT/等待、shader无效射线标记、逐字段非有限值、非法ID/重心/primitive、输出图片写入失败。静态顶点和实例由本例固定构造，尚未实现资产导入后的退化网格清洗。CPU严格检查所有像素，不跳过轮廓；共享边上不强求CPU/GPU返回同一三角形号，只要求GPU选择的合法三角形重建正确。

## 9. 本机验收

2026-10-13，DXC lib_6_3、build.ps1/sm_120重编译，RTX5070/Tier1.1实际运行8提交。两槽复用6次，Fence9/9、Debug0/0、exit0。467200条有效射线，所有组mismatch=0、invalid=0。

|量|8组最大误差|
|---|---:|
|射线方向|2.43e-7|
|命中t|4.43e-6|
|GPU世界位置 vs CPU求交|4.76e-6米|
|世界边叉积法线 vs CPU|4.09e-8|
|逆转置法线 vs 世界边叉积|6.14e-8|
|重心/射线位置交叉重建|2.33e-6米|

错误的普通方向变换最大偏差72.43度。基线Miss/ID1/ID2/ID3=34625/5294/1917/15764；旋转相机为38107/6026/1800/11667。Near5时仍有右板/远地板命中，本次场景已含跨越5米的实例，不能沿用R.13.3单个x=4矩形应全Miss的旧预期。

输出两套实际GPU读回诊断：`dxr_surface_diagnostics_1.png`（基线）、`dxr_surface_diagnostics_3.png`（相机旋转）。每图六格：ID、正确世界法线、错误方向变换法线、重心权重、射线距离、放大显示的reversed-Z深度。Pillow仅转格式和排版，已查看两图确认无截断。物体没有旋转，因此相机改变后同一平面的世界法线颜色保持一致。

## 10. 运行与动手

在仓库根目录逐步执行：

```powershell
& 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\dxc.exe' -T lib_6_3 -Fo learning/sandbox/d3d12/r13-renderer/dxr_view.dxil learning/sandbox/d3d12/r13-renderer/dxr_view.hlsl
.\learning\sandbox\build.ps1 .\learning\sandbox\d3d12\r13-renderer\dxr_view_pipeline.cu -NoRun
.\learning\sandbox\d3d12\r13-renderer\dxr_view_pipeline.exe .\learning\sandbox\d3d12\r13-renderer\dxr_view.dxil
python learning/sandbox/d3d12/r13-renderer/dxr_surface_preview.py
```

手算：u=.2/v=.3时求三个重心权重；将切向量e=(1,1,0)按X方向放大2倍，分别检查正确/错误法线与e'的点积。比较两张相机配置的法线图，区分覆盖变化和法线数值变化。

自测：为什么DXR重心插值不再除一次clip.w？为什么法线不能只乘模型矩阵再归一化？为什么t、视图深度、NDC深度不同？下一节R.13.5将这些世界位置与几何法线接到R.12 NEE，生成Lambert直接光图像。

来源：[PrimitiveIndex](https://learn.microsoft.com/en-us/windows/win32/direct3d12/primitiveindex)、[ObjectToWorld3x4](https://learn.microsoft.com/en-us/windows/win32/direct3d12/objecttoworld3x4)、[WorldToObject3x4](https://learn.microsoft.com/en-us/windows/win32/direct3d12/worldtoobject3x4)、[RayTCurrent](https://learn.microsoft.com/en-us/windows/win32/direct3d12/raytcurrent)、[Load3](https://learn.microsoft.com/en-us/windows/win32/direct3dhlsl/sm5-object-byteaddressbuffer-load3)。
