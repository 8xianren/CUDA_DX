# PT.6：GPU采样、MIS积分与正交相机

2026-10-21。前课：[两种估计器与MIS推导](PT.6-两种直接光估计器与MIS推导.md)。[代码/运行入口](../../sandbox/path_tracing/pt06-mis/README.md)。本节完成PT.6的漫反射直接光GPU闭环，下一节PT.7。没有实现多次反弹、一般glTF材质或delta专项渲染。

## 先回答上节问题

1. MIS的灯估计与BSDF估计相加之后不再除以2。每个估计器已经按自己的样本数平均；同一方向的两个权重之和为1，积分期望已经等于目标。再除以2会把期望减半。
2. 对一个BSDF采样到、BSDF PDF大于0但光源策略PDF等于0的方向，BSDF的balance/power权重均为1。两边PDF都为0时，不能用0/0；这种方向不应由这些连续采样器生成。
3. 不能比较单位面积PDF和单位立体角PDF。灯面微元的投影面积为cos(thetaL)dA，从距离r看占据dω=cos(thetaL)dA/r²；由pA dA=pω dω，得pω=pA r²/cos(thetaL)。还要检查单面灯的发光侧和采样支持域。

## 本节计算问题与假设

上一节CPU事先给出receiver上的表面点并产生样本。本节让每个RayGen根据像素坐标生成相机射线，真实命中receiver后，自己生成样本、查询DXR、计算PDF与权重、写线性辐亮度。

固定测试几何：receiver z=0、x/y∈[-1,1]、法线+Z；灯z=2、x/y∈[-h,h]、朝-Z；blocker z=1、x∈[0,.5]、y∈[-.4,.4]。CPU通过Assimp读glTF，复用C/D上传、BLAS/TLAS；GPU求交用真实三角形。灯位置/尺寸、receiver法线仍是fixture约定，不是从任意网格提取的通用灯系统。材质rho和Le取glTF因子的红通道，这些fixture为灰度。

相机位于z=.5，方向-Z，故在遮挡板下面；相机主射线看见receiver，向上的光照射线仍会遇见blocker。背景无环境光。像素中心固定，无抗锯齿抖动。

## 从像素到正交主射线

图像坐标i向右、j向下，分辨率W×H。像素中心比例为u=(i+.5)/W，v=(j+.5)/H。要求u=0/1映射观察矩形左/右端cx-a/cx+a，设x=Au+B，解端点得到A=2a、B=cx-a。世界Y向上，因此y=cy+a-2av。

于是原点o=(cx+(2u-1)a, cy+(1-2v)a, zc)，方向d=(0,0,-1)，射线r(t)=o+td。本课a=1.2，观察范围比receiver大，所以边缘是真实miss，不是显示裁切。

命中平面z=0的约束zc-t=0给t=zc。本机GPU不直接代入它，而由DXR的RayTCurrent返回t，再由o+td重建世界位置；CPU解析参考才直接求平面与矩形交点。这里没有透视除法，也没有重新定义D3D的NDC约定，是直接构造世界空间正交射线。

## 执行职责与payload

`gpu_integrator.hlsl:31`的RayGen按像素运行。先Shoot主射线；Miss返回material=0，ClosestHit返回objects[InstanceID()].material+1和RayTCurrent。加1是为了让合法material0与miss可区分。

payload是一次TraceRay携带并返回的小数据结构，非整张图像：uint material、float t、uint2 padding，共16B。填充维持共用管线的payload约定。三角形命中属性float2为8B，由DXR提供；当前只要材质身份与t，未读取重心属性。

ClosestHit不发起新TraceRay。RayGen在一次TraceRay完全返回后才发下一条，因此同时嵌套层数只有1。每个命中像素实际发1+64×4=257条射线，并不需要MaxTraceRecursionDepth=257。递归深度是调用嵌套，不是总射线数，也不是物理反弹数。

## TraceRay接口与参数

```hlsl
void TraceRay(RaytracingAccelerationStructure AccelerationStructure,
    uint RayFlags, uint InstanceInclusionMask,
    uint RayContributionToHitGroupIndex,
    uint MultiplierForGeometryContributionToHitGroupIndex,
    uint MissShaderIndex, RayDesc Ray, inout payload_t Payload);
```

本课`TraceRay(scene,RAY_FLAG_FORCE_OPAQUE,255,0,0,0,ray,hit)`：scene为TLAS；force opaque跳过alpha/AnyHit透明逻辑；255与实例8bit mask相交；两个hit group地址计算参数为0，配合当前实例贡献0使所有三角形使用唯一HitGroup；miss索引0使用唯一Miss；ray为原点/方向/TMin/TMax；hit为上述16B输入输出。

RayDesc方向归一化，所以t具有场景长度单位。TMin=1e-5减少本fixture的表面自相交，TMax=1e6覆盖场景；这不是适用于任意尺度的鲁棒偏移算法。本课向灯方向追到最近几何，根据是否命中Emitter判定可见。常见shadow接口会在目标灯点附近截断，我们这里保留最近命中身份，便于对照。

## 采样、PDF和归一化

灯采样：均匀u/v映射q=((2u-1)h,(2v-1)h,2)，pA=1/(4h²)，方向normalize(q-x)。BSDF采样：r=sqrt(u)，phi=2πv，方向(r cos(phi),r sin(phi),sqrt(1-u))，pB=cos(theta)/π。本fixture局部法线就是世界+Z，暂不构造任意法线的切线基。

对任一采样方向，需要同时评估pL与pB。先解到灯平面的t=(2-position.z)/direction.z，再判交点是否在灯面；若不在，pL=0。灯采样自身必在支持域内，代码显式保留该事实，避免重建边界舍入导致自己PDF变0。

本fixture两平面平行，cosLight=cosSurface=direction.z，距离=t，因此pL=t²/(4h²cosLight)。遮挡只让被积函数F=(rho/π)Le cosSurface V变0，不改变采样器生成方向的概率。绝不能因遮挡把pL改为0并重新把能量分给另一个策略。

每轮生成灯样本L0/L1与BSDF样本B0/B1。BSDF-only用B0+B1；NEE-only用L0+L1；balance与power各用L0+B0。每个估计器每轮均用两个方向，公平比较方向预算。程序为了同时输出四种估计器，实际追四条射线，并非单个MIS估计器必须追四条。

BSDF/NEE累加后除以2×rounds；MIS累加两个加权估计后除以rounds。不同策略生成的是不同方向，因此某一对随机样本的两个权重不一定加到1；权重和为1指在同一方向上评估两种策略。

随机数使用32bit加法/整数混合，每像素/seed初始化自己的状态，输出23bit开区间浮点数，避免u=1导致方向落在地平线上。CPU相同整数序列用于逐样本验证，double计算方向/几何/权重。它与前课PCG不同，不能逐像素比较两次seed0；当前验证不证明随机数质量最优。

## 数据布局、提交与所有权

`gpu_mis.h`的配置64B：偏移0是width/height/rounds/seed；16是receiver/emitter/两个padding；32是halfLight/rho/le/halfView；48是panX/panY/cameraZ/padding。此处为StructuredBuffer显式布局，不是cbuffer打包；static_assert核对大小和关键偏移。

每像素32B输出：前16B为四个估计值，后16B为主命中材质+1、灯采样命中数、BSDF采样命中数、保留。32×32共32768B。像素按index=y×width+x存放，每个RayGen只写自己的元素，无数据竞争，不需要atomic。

`gpu_mis_dispatch.cpp`创建四个根参数：SRV t0 TLAS、t1对象表、t2配置；UAV u0输出。配置在UPLOAD/GENERIC_READ中由CPU初始化后保持只读；对象表步长80B；TLAS保持AS状态。没有纹理读取，因此不绑定texture/sampler heap。

```cpp
void ID3D12GraphicsCommandList4::DispatchRays(
    const D3D12_DISPATCH_RAYS_DESC* pDesc);
```

它录制RayGen调度，返回void，并非CPU等待。pDesc包含RayGen记录、Miss/HitGroup/Callable表和Width/Height/Depth。本课Width=Height=32、Depth=1；Callable为空。共用SBT占192B，三个标识符各32B，记录位于0/64/128偏移；Miss/HitGroup的表大小与stride为64B。使用GPU地址，根签名和管线均先绑定。

提交顺序：已有TLAS构建/UAV barrier→DispatchRays→输出UAV转COPY_SOURCE→复制到READBACK/COPY_DEST→Execute→Signal→等待Fence→Map→复制到CPU vector→Unmap。Map不自动等待GPU；读范围覆盖输出，Unmap写范围为空。局部根签名/管线/SBT/config/output/readback持有到Fence完成；场景、BLAS、TLAS由上层持有。当前逐次同步读回是验收路径，不是交互渲染的性能方案。

创建、序列化、Map等HRESULT失败会抛异常；维度/rounds/几何假设参数先检查；等待超时、device removed、Debug警告、非有限输出或比较失败都令进程非零退出，不把失败结果当成正常图像。设备恢复没有实现。

## 本机实测

RTX5070，32×32，64轮，每个估计器128方向，16seed。另跑Le×2、rho=0、相机平移三个变体；每场景19次积分Dispatch，连同上传共Fence20/20。

|指标|小灯h=.25|大灯h=4|
|---|---:|---:|
|射线数，含主射线及变体|3321088|3321088|
|主命中/两类采样计数不一致|0|0|
|CPU/GPU估计值最大绝对差|1.490116119e-8|8.344650269e-7|
|独立512²面积求积图像均值|.004771251290|.4063385863|
|BSDF MSE|2.996031356e-5|5.777890652e-4|
|NEE MSE|7.167546016e-8|3.104489685e-3|
|Balance MSE|1.584494098e-7|8.986049956e-4|
|Power MSE|1.498546286e-7|1.094059076e-3|

Le翻倍逐值精确翻倍、黑材质精确0；相机pan=(.2,-.1)改变205个像素的主命中覆盖，CPU/GPU仍一致；glTF Validator 0 errors/0 warnings，Debug/GPU Validation 0。

MSE是每seed全图像素均方误差再平均，包含黑背景；SE是16个图像均值的标准误，不是每像素方差。256²/512²参考最大差小灯4.65e-5、大灯.001737，这只是数值稳定性观察而非严格误差界。统计回归用宽松6SE+2倍求积差+1e-6阈值，不能用测试证明无偏性；无偏性来自估计器推导。

当前图像含相机miss边界，坐标网格/随机序列也改变，所以不应把均值/MSE与前课24²表面点实验直接作性能比较。小灯MIS远优于BSDF，但NEE最好；大灯MIS远优于NEE，但BSDF最好。没有测GPU计时，不作性能结论。

[GPU比较图](../../sandbox/path_tracing/pt06-mis/results/gpu/comparison.png)、[小灯日志](../../sandbox/path_tracing/pt06-mis/results/gpu/small/gpu.txt)、[大灯日志](../../sandbox/path_tracing/pt06-mis/results/gpu/large/gpu.txt)。图像每行同曝光，线性数值用于统计；上排曝光16，下排1，背景黑边来自真实miss。

## 复现、自测与后续

仓库根运行`& ./learning/sandbox/path_tracing/pt06-mis/verify_gpu.ps1`和`python ./learning/sandbox/path_tracing/pt06-mis/preview_gpu.py`。脚本自身使用PSScriptRoot，工作目录不影响产物位置。编译失败曾发现HLSL关键字technique不能用作局部变量，已改为sampleKind；最终构建运行通过。

自测：257条射线为什么只需递归深度1？被遮挡时pL是否该置0？为什么MIS除64而单策略除128？下一课PT.7从当前RayGen执行模式推导多次反弹与路径吞吐量beta，再讨论俄罗斯轮盘赌。

面向交互渲染会将管线/根签名持久化，使用GPU历史缓冲和多帧资源；本实验为清楚核对每次结果，逐次创建局部对象并等待读回。两者共享同样的GPU资源状态与队列同步约束。任意材质法线、纹理与高光在PT.8，渐进显示在PT.10；delta事件目前仅完成理论解释，没有专项渲染验收。

官方参考：[TraceRay](https://learn.microsoft.com/en-us/windows/win32/direct3d12/traceray-function)、[DispatchRays](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12graphicscommandlist4-dispatchrays)、[管线递归深度](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ns-d3d12-d3d12_raytracing_pipeline_config)。
