# R.13.1–2：View、Projection 与逆投影射线

2026-10-10。按学习者要求将新版 R.13.1、R.13.2 合讲。目标是理解并验证世界点→屏幕→射线的闭环。本节完成 CPU 数学层；不宣称新版 DXR 主射线已经接入。

## 1. 约定和成像模型

世界 +X前/+Y右/+Z上，视图 +x右/+y上/+z前，1单位=1米。行向量乘法；世界点 pClip=pWorld*V*P。CPU float矩阵按行存储，未来HLSL显式row_major和mul(v,M)，数学乘法与内存布局分别约定。DXR实例3×4 Transform仍按API布局，不直接拷贝本课4×4。

相机是无缩放、无剪切的刚体；透视针孔、垂直FOV、方形像素、对称视锥、无jitter。当前绝对世界小场景；UE Translated World的相对基准与大世界精度后续另议。UE Actor本地前/右/上轴与本课视图右/上/前轴顺序不同，因此不能省略轴对应就将Actor矩阵求逆称为本课View。

E是世界相机位置，F是单位前向，R是单位右向，U是单位上向。参考上向A不要求与F正交，但不得平行；F=normalize(forward)，R=normalize(A×F)，U=F×R。默认A=+Z/F=+X给R=+Y/U=+Z；叉积顺序应按该结果核验，不照抄旧Y-up版本。LookTo接收方向；LookAt接口才接收目标位置。本例自己构造方向后调用LookTo。

## 2. View本质是换坐标基

对世界点Q，先计算相对位移d=Q-E，再投影到单位正交基：xv=dot(d,R)，yv=dot(d,U)，zv=dot(d,F)。相机局部点反过来映射到世界：Q=E+xvR+yvU+zvF。

行向量下，CameraToWorld矩阵C与View矩阵V为：

```text
C = [ Rx Ry Rz 0 ]       V = [ Rx Ux Fx 0 ]
    [ Ux Uy Uz 0 ]           [ Ry Uy Fy 0 ]
    [ Fx Fy Fz 0 ]           [ Rz Uz Fz 0 ]
    [ Ex Ey Ez 1 ]           [-E·R -E·U -E·F 1]
```

V=C^-1。旋转块可转置求逆，是因为正交单位基；整个4×4有平移，不能直接转置整个矩阵当逆。一般含缩放/剪切的矩阵也不能只转置3×3。本课相机不含这些变换。

点使用齐次w=1，方向使用w=0，因此仿射平移只影响点。齐次坐标的一般位置是(X/W,Y/W,Z/W)，W非零；乘同一非零比例仍表示同一点。W=0描述无穷远方向，不是可除法求出的有限位置。

## 3. Projection从透视比例推导

令h=tan(thetaY/2)、a=ViewWidth/ViewHeight。前向距离d的截面半高dh、半宽dah。可以选d=1作虚拟成像平面，但近面位置由near=n定义，两者不是同一概念；不同d下同步缩放平面宽高，射线方向不变。

视图点(x,y,z)在z>0时：xN=x/(z*a*h)，yN=y/(z*h)。令sx=1/(a*h)、sy=1/h。要通过一次线性矩阵乘法加齐次除法得到x/z、y/z，让clip.w=z。

无限远reversed-Z投影矩阵（行向量）：

```text
P = [ sx 0  0 0 ]
    [ 0 sy  0 0 ]
    [ 0  0  0 1 ]
    [ 0  0  n 0 ]
```

[x y z 1]*P=[sx*x sy*y n z]。除以w得到(xN,yN,zN)=(sx*x/z,sy*y/z,n/z)。近面z=n对应1，z趋无穷对应0。深度值不是世界距离。near=.1时z=.1/1/10/1000对应1/.1/.01/.0001。

有限far=f>n时，将P的第三行第三项设为A=n/(n-f)，第四行第三项设为B=n*f/(f-n)，得到zN=A+B/z；代入n、f分别为1、0。令f趋无穷便回到上式。因此不应随便把far=无穷传入一个只接受有限far的函数期待正确结果；本课直接构造所需矩阵。

光栅裁剪发生在透视除法之前：D3D合法范围-w<=xclip<=w、-w<=yclip<=w、0<=zclip<=w。本课zclip=n、w=z，因此z>=n。相机背后z<=0的点不能仅凭除法后的xy判断可见。本节数学投影示例选取视锥内点；没有执行光栅裁剪或创建Depth Buffer。

## 4. ViewRect和像素中心

屏幕原点在左上，y向下；NDC y向上。ViewRect左上(vx,vy)、尺寸(W,H)：screenX=vx+(xN+1)*W/2，screenY=vy+(1-yN)*H/2。

连续屏幕点(sx,sy)逆变换：u=(sx-vx)/W、v=(sy-vy)/H；xN=2u-1、yN=1-2v。整数像素局部编号(i,j)的中心为(vx+i+.5,vy+j+.5)。已经是连续坐标时不要再加.5。投影出的世界点可以落在像素边界，不必总是像素中心。

ViewRect不等于资源整图尺寸；例子在纹理/窗口里的视口偏移为(100,50)，宽高800×400。计算aspect用视图宽高；是否保持垂直FOV是相机政策，不是所有UE模式的默认政策。

## 5. 逆VP生成射线

VP=V*P，InvVP=P^-1*V^-1。只给屏幕xy没有唯一世界点；选择zN=1取近面有限参考点：H=[xN yN 1 1]*InvVP，Qnear=H.xyz/H.w。使用w=1是给NDC点选齐次代表，不是在恢复原始clip.w。

O=E；D=normalize(Qnear-E)。射线r(t)=O+tD。齐次除法确定位置，单位化确定方向长度，二者不能混称一个“归一化”。若输入原表面深度而非1，才能恢复原表面位置。无限远投影下zN=0产生H.w=0；其xyz可作为世界方向，禁止作为有限点除以w。

射线原点放在E时，匹配近面的tNear=n/dot(D,F)。离轴60度时dot=.5，因此n=.1对应tNear=.2。用固定TMin=.1只到前向深度.05，会允许近面之前的几何。另一种实现把原点放到近面，但此时t的参考起点也变了，不能与相机距离混用。无限far投影和DXR有限tMax是不同约束，本节尚未创建RayDesc。

正交相机没有公共针孔，通常逐像素原点不同、方向相同；不能套normalize(Q-E)生成正交射线。景深会采样镜头位置，当前不包含。

## 6. 完整数值例子

E=(3,-2,1)，F=(1,0,0)，R=(0,1,0)，U=(0,0,1)。世界点Q=(7,0,2)，Q-E=(4,2,1)，所以视图坐标=(2,1,4)。垂直FOV=90度，aspect=2，near=.1：sx=.5、sy=1。

clip=(1,1,.1,4)，NDC=(.25,.25,.025)。ViewRect=(100,50,800,400)，连续屏幕点=(600,200)。用原深度.025反投影恢复原点Q；用1反投影得到Qnear=(3.1,-1.95,1.025)，D约(.87287156,.43643578,.21821789)，tNear约.11456439。浮点实测与手算略有差别，见下文。

## 7. 实际API与资源边界

```cpp
XMMATRIX XM_CALLCONV XMMatrixLookToLH(
    FXMVECTOR EyePosition, FXMVECTOR EyeDirection, FXMVECTOR UpDirection) noexcept;
XMMATRIX XM_CALLCONV XMMatrixInverse(
    XMVECTOR* pDeterminant, FXMMATRIX M) noexcept;
XMVECTOR XM_CALLCONV XMVector4Transform(
    FXMVECTOR V, FXMMATRIX M) noexcept;
```

LookToLH的三个参数都是世界空间相机位置/朝向/参考上向，返回WorldToView。FXMVECTOR/FXMMATRIX是DirectXMath传参约定，XMVECTOR是4分量计算值、XMMATRIX是4×4计算值；不要把这些SIMD类型直接当作GPU常量缓冲协议。

Inverse输入M，pDeterminant可为空；非空时每个lane输出同一行列式。API不返回HRESULT，奇异矩阵可能返回无穷矩阵，调用者检查行列式与结果。本课1e-12阈值只适合给定小尺度输入，不声称是通用病态矩阵检测。

Vector4Transform计算V*M，保留w，不自动执行本课的有限点齐次除法。代码使用XMStoreFloat4/Float4x4检查结果。普通XMFLOAT4X4为16个float的64B存储表示；GPU CBV的256B对齐与矩阵本身64B是不同层次，下一节R.13.3才处理上传与绑定。

本程序全部数据由CPU栈/返回值管理，无设备、命令队列、上传、跨帧所有权或Fence。沿用build.ps1和sm_120编译是项目约定，不代表本数学工作在GPU上执行。失败通过runtime_error到main捕获，stderr打印FAIL并返回1；成功返回0。

## 8. 本机运行记录

代码：`learning/sandbox/d3d12/r13-01-02-camera-math/r13_camera_math.cu`。在`learning/sandbox`执行`./build.ps1 d3d12/r13-01-02-camera-math/r13_camera_math.cu`。

2026-10-10重新编译并运行：20组检查PASS，exit0。两个相机覆盖默认轴向和旋转姿态，320×180与257×257共123649条像素射线。

|检查|实测|
|---|---:|
|View与独立double点积最大误差|3.71e-7|
|View/InvView往返最大位置误差|4.00e-7|
|数值例子屏幕位置|(599.999994,200.000003)|
|数值例子D|(.87287116,.43643641,.21821821)|
|数值例子tNear|.11456444|
|原世界点到反投影射线距离|3.72e-6|
|全部像素矩阵/解析方向最大差|2.29e-6|
|逆投影近面前向距离最大误差|1.91e-7|
|near从.1改成1时最大方向差|2.35e-6|

正常路径还检查near=.1时视图z=.1/1/10/1000的深度映射、无穷远w=0及其方向、离轴near。失败路径检查零前向、平行up、FOV=0/180、aspect=0、near=0、空ViewRect、奇异矩阵和将无穷远当有限点除法。像素遍历是CPU float矩阵对double解析方向，不是CPU/GPU比较。

## 9. 动手与自测

保持FOV和ViewRect不变，将near从.1改成1：射线方向应不变，但近面参考点离相机更远，tNear增加10倍。保持矩阵不变只改变ViewRect偏移：同一局部像素方向不变，绝对屏幕位置改变。

自测：为什么View的平移项不是简单把eye.xyz放进去？为什么矩阵乘法后必须除w才能得到透视？为什么near=.1不能直接用于所有射线的TMin？下一节R.13.3将这些CPU数据及约定真正接到DXR。

参考：[XMMatrixLookToLH](https://learn.microsoft.com/en-us/windows/win32/api/directxmath/nf-directxmath-xmmatrixlooktolh)、[XMMatrixInverse](https://learn.microsoft.com/en-us/windows/win32/api/directxmath/nf-directxmath-xmmatrixinverse)、[XMVector4Transform](https://learn.microsoft.com/en-us/windows/win32/api/directxmath/nf-directxmath-xmvector4transform)、[UE FViewMatrices](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/FViewMatrices)。
