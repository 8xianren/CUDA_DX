# R.12 第二部分：矩形面积光 NEE 与 CPU 对照

日期：2026-10-09。接续第一部分有限阴影查询；本节目标是把 PT.5 的面积采样和 PDF 转换放入真实 DXR ClosestHit，并区分实现误差与有限样本误差。

## 1. 上一节自测答案

1. ShadowPayload 初值 visible=0。接受遮挡后跳过 ClosestHit，值仍是0；无命中才执行 ShadowMiss 写1。
2. SKIP_CLOSEST_HIT_SHADER 只抑制命中后的 shader，不撤销已接受命中，也不触发 Miss。
3. MaxTraceRecursionDepth=2 是两层同时嵌套的 TraceRay：主射线尚未返回时发阴影射线。没有计算第二次表面反射，不等于两次路径反弹。

## 2. 文件、编译与范围

- `learning/sandbox/d3d12/r12-02-area/dxr_area.hlsl`：哈希生成二维灯面样本、几何量和 PDF、有限 Shadow TraceRay、写每样本结果。
- `learning/sandbox/d3d12/r12-02-area/dxr_area_pipeline.cu`：独立 D3D12 宿主，沿用第一部分的初始化、BLAS/TLAS、SBT、同步链；创建八组场景并读回。
- `learning/sandbox/d3d12/r12-02-area/dxr_area_reference.h`：双精度 CPU 相同样本对照、独立平面三角形可见性、512²/1024²中点面积参考。

保留第一部分原文件。没有 CUDA kernel；GPU 使用 DXR，nvcc sm_120 只构建宿主。

```powershell
& 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\dxc.exe' -T lib_6_3 -Fo learning/sandbox/d3d12/r12-02-area/dxr_area.dxil learning/sandbox/d3d12/r12-02-area/dxr_area.hlsl
& .\learning\sandbox\build.ps1 learning\sandbox\d3d12\r12-02-area\dxr_area_pipeline.cu -NoRun
& .\learning\sandbox\d3d12\r12-02-area\dxr_area_pipeline.exe .\learning\sandbox\d3d12\r12-02-area\dxr_area.dxil
```

必须上一阶段编译成功再执行下一步，避免运行陈旧产物。本次三阶段退出均成功，末尾 PASS，Debug0/0、Fence1/1。

## 3. 数学到代码的完整映射

点光的唯一连接目标变成矩形光源上的随机点q。基准场景：x=(0,0,0)、N=+Z，灯中心(0,0,3)，U=+X、V=-Y、法线normalize(cross(U,V))=-Z；半边长h=1，面积A=4；Le=5，rho=.7。

两个均匀随机变量xi1/xi2，生成 q=C+(2xi1-1)hU+(2xi2-1)hV。两轴单位正交，因此 pA=1/(4h²)。一般非正交轴要按叉积长度算面积，不能直接套本例公式。

wi=(q-x)/r；cosS=max(0,N·wi)；cosL=max(0,NL·(-wi))。cosS来自接收面，cosL来自发光面。仅支持单面发光；背面直接返回零，不能用abs偷偷改成双面模型，也不能先除以零再处理。

dω=cosL/r² dA。因概率质量守恒 pA dA=pω dω，所以 pω=pA r²/cosL。

HLSL使用方向形式：Y=V Le (rho/pi) cosS / pω。

CPU使用等价面积形式：Y=V Le (rho/pi) cosS cosL A/r²。

二者是同一个积分，不是两种物理模型。使用pω后，不要再次乘cosL或除r²；更不能把PT.4余弦采样的rho*Li化简公式套到本例，因为实际采样分布不同。

中心样本r²9、cosS=cosL=1、pA=.25、pω2.25，Y≈.495148712。角落样本r²11、两余弦3/sqrt11，Y≈.331463187。随机平均才估计整个灯的积分。

## 4. 采样器与GPU工作划分

`float uniform_dimension(uint sample,uint dimension)` 输入样本编号及维度0/1，哈希32位整数后取高16位，用(整数+.5)/65536映射到(0,1)。没有可变全局RNG状态；不同case复用相同二维样本，便于成对对照。固定哈希序列用于可复现，不保证严格独立；离散随机数也不是连续分布的数学实现。生产采样器选择与维度管理留待后续。

`DispatchRays` 的 Width=4096、Height=8、Depth=1；x是样本，y是测试场景，不能把它叫4096×8像素图。每个RayGen做一次主TraceRay，ClosestHit至多发一次shadow。每个调用只写output[case*4096+sample]，不需要atomicAdd；读回CPU平均所有样本，不只平均可见样本。

HLSL输出float4=(样本贡献，有效可见标志，方向PDF，cosL)。有效可见标志对背面样本也为0，表示没有有效发光贡献，不应把背面组的0说成DXR检测到物体遮挡。主Miss或非法距离输出-1哨兵，CPU据此验收失败。

输出stride16，4096×8×16=524288B=512KiB。CPU `GpuResult` 四个float，static_assert(sizeof==16)。主payload uint test+float4 result共20B，配置MaxPayloadSizeInBytes=20；shadow为4B。不要套用常量缓冲打包规则或把逻辑payload字节等同于硬件寄存器数。

## 5. 遮挡、范围和同步

起点x+.0001N；偏移后重算到q的距离和单位方向，TMin=.001、TMax=shadowDistance-.001；物理dist²仍从真实x算。复用 FIRST_HIT|SKIP_CLOSEST，mask3，Miss索引1。着色点/灯过近则失败哨兵；本课不是任意尺度稳健射线方案。

接收mask1、挡板mask2，主mask1，阴影mask3。八组相隔8单位。一个三角形BLAS复用为8接收面+3挡板共11个TLAS实例。三角形局部顶点(0,1),(-1,-1),(1,-1)；partial挡板z1.5、XY scale .35；behind挡板z4、scale4；full挡板z1.5、scale2。

无新增Root参数：t0 TLAS root SRV、u0输出root UAV；SBT仍RG@0、PrimaryMiss@64、ShadowMiss@96、HitGroup@128；无local root。嵌套深度仍2，因为并行多发样本不会增加单条调用的嵌套深度。

Build BLAS→UAV barrier→Build TLAS→UAV barrier→输出转UAV→DispatchRays→转COPY_SOURCE→CopyResource到READBACK→Execute→Signal1→CPU等Fence1→Map/校验→Unmap。每个输出唯一写者只消除了相互写竞争，不替代资源状态和CPU等待。资源保持到Fence后释放。

## 6. 两层CPU参考和验收阈值

第一层逐样本：CPU与GPU使用相同二维样本；CPU以double计算几何，并用射线与挡板平面求交后的二维三角形包含判断，独立于DXR遍历。GPU用方向PDF权重，CPU用面积权重。要求可见性完全一致，非有限/负贡献0个，样本光照绝对误差、PDF归一化差值、cosL误差均小于3e-5。PDF误差实际按max(1,pdf)归一化，不把小PDF分母放大。

第二层积分：512²与1024²中点灯面积积分，不复用随机样本。打印两网格差，不将1024²称解析真值。MC均值允许5*SE+2*网格差+1e-5；SE根据单样本方差/sqrtN估计，是理想独立模型的诊断尺度，不是哈希序列的严格置信证明；两网格差也不是严格误差上界。

## 7. RTX5070本次结果

|case|GPU均值|同样本CPU|1024²面积参考|有效可见样本|
|---|---:|---:|---:|---:|
|0 无遮挡|0.431056223|0.431056228|0.431611609|4096/4096|
|1 部分遮挡|0.317436074|0.317436077|0.316725934|3106/4096|
|2 背面发光|0|0|0|0/4096|
|3 光源后挡板|0.431056223|0.431056228|0.431611609|4096/4096|
|4 半边长.5|0.119332067|0.119332068|0.119373786|4096/4096|
|5 距离6|0.119332067|0.119332068|0.119373786|4096/4096|
|6 斜灯|0.378177589|0.378177590|0.376212281|4096/4096|
|7 完全遮挡|0|0|0|0/4096|

各组visibility_mismatch=0、invalid=0。最大单样本贡献误差1.97e-7，最大PDF归一化误差2.97e-7，最大光源余弦误差1.4e-7。

```text
Cross-case energy/orientation/finite-shadow checks: PASS
Fence target=1 completed=1; samples=4096 cases=8 output_bytes=524288
InfoQueue: errors=0 warnings=0
R.12 area NEE: PASS
```

面积缩小至1/4与距离扩大2倍的均值相同并非偶然：本例灯面平行、Le固定、无遮挡，两种灯相对于着色点具有相同的方向覆盖。整个目标点向量相差比例2，对应A/r²不变、余弦不变。不能推广成任意近距离面积光都严格按中心距离反平方衰减。

部分遮挡样本零贡献也计入4096分母。可见面积比例不是一般性的光照比例，因为灯面各点的几何权重不同。

## 8. 教学边界与下一步

这是GPU直接光NEE数值验收，尚未输出二维软阴影图；部分遮挡组验证单点部分光源可见所产生的积分。灯是采样参数、不在TLAS中，不能被主射线看见；固定+Z法线、诊断主射线来自下方，不能当通用正反面材质。没有纹理/透明、MIS、多次反弹、窗口/渐进累积、GPU-based validation或设备移除恢复。

商业渲染器通常在GPU上累加线性HDR并最终显示，支持统一灯/材质表和成熟采样器；本课逐样本回读便于把PDF、可见性、舍入误差分别核对，底层TraceRay与积分权重相同。

R.12核心API/数学验收已齐；保持进行中，待课堂收束。随后R.13将接入相机像素与线性HDR渐进累积；不要从本次样本并行误称已实现完整Path Tracer。

自测：面积采样能否用rho*Li？一半样本遮挡应除N还是除N/2？4096样本为什么不需要递归深度4096？

参考：[Microsoft DispatchRays 描述](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ns-d3d12-d3d12_dispatch_rays_desc)、[PBRT 面积/方向采样](https://www.pbr-book.org/4ed/Shapes/Basic_Shape_Interface)。
