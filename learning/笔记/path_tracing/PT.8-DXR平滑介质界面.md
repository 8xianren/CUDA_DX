# PT.8 DXR平滑介质界面

2026-10-21。单个平滑介质界面的反射/透射GPU验收完成，PT.8继续进行中。
代码与命令：[pt08-materials](../../sandbox/path_tracing/pt08-materials/README.md)；实测：[summary.csv](../../sandbox/path_tracing/pt08-materials/results/glass/summary.csv)、[paths.csv](../../sandbox/path_tracing/pt08-materials/results/glass/paths.csv)。

## 上节答案

按F选择分支，反射weight=F/F=1；空气1→玻璃1.5透射weight=(1-F)(1/1.5)²/(1-F)=4/9。F已经在发生频率中，不再乘.04/.96。
玻璃→空气weight=2.25是Radiance模式的立体角变换，不是总功率增益。
进入玻璃etaScale乘9/4，仅在RR生存概率估计中使用beta*etaScale；实际L仍用beta。

## 问题、约定与解析目标

前两节得到数学采样器，现在要验证它控制真实DXR路径时，求交、材质分支与辐亮度更新是否一致。
用游戏中双色测试灯的直觉：反射路径看见上方灯，透射路径看见下方灯，颜色就能区分两条路径的来源；CPU仍逐字段核算，不把颜色看起来合理作为验收。

场景只有三个glTF矩形网格：

- 界面z=0，x/y∈[-16,16]，几何外向法线ng=(0,0,1)，内部介质z<0、外部z>0。
- 上灯z=+2，半宽8，朝下发光Le+=(.8,.3,.1)。
- 下灯z=-2，半宽8，朝上发光Le-=(.2,.6,1)。

这是一个单界面局部实验，不是闭合玻璃薄片；不存在第二次出界面。相机在z=+1或-1，64²主射线起点中心覆盖x/y∈[-.5,.5]。正向斜率a=tan(theta)，d=normalize(a,0,-side)。本节所有网格变换为单位矩阵，法线由fixture固定给出，没有任意网格插值法线。

第一次求交下降/上升1米，解析命中p=(ox+a,oy,0)，t_hit=sqrt(1+a²)。材质输出方向v后，下一个候选灯平面在z=sign(vz)*2，行进参数tau=2/abs(vz)，交点q=p+tau*v；检查abs(qx)<8且abs(qy)<8来决定是否命中有限矩形。
对每条主射线的解析目标为C=F*Vr*Le_r+(1-F)*qIOR²*Vt*Le_t，其中V是对应方向是否命中灯的0/1可见性。这个qIOR是IOR比，与位置q区分。

正入射时两方向都命中灯，F=.04、qIOR²=4/9：
C=.04(.8,.3,.1)+.96*(4/9)(.2,.6,1)=(.1173333,.268,.4306667)。
80度空气→玻璃时，反射方向全部错过有限上灯，透射方向仍命中下灯；因此Vr=0，不能因为反射miss就删除样本或只平均成功命中的路径。

## 材质采样与路径执行

`dielectric.hlsli`提供：

```hlsl
DielectricSample SampleDielectric(
    float3 d, float3 ng,
    float outside, float inside,
    float u, uint mode);
```

d指向当前交点；ng为几何外向法线，二者单位。outside/inside为正实数IOR；u∈[0,1)，mode0按F抽样、mode1在两分支非零时半半抽样。宿主限制本实验输入域；这不是接受任意不可信参数的通用材质API。
结果含direction、F、weight、mass、pr、etaScale、q²、etaI/etaT和event。event1反射、2透射、0无效；成功事件都是delta，连续方向密度为0。weight已经除过mass。F0/F1先处理为确定事件，避免0/0或选中不存在的透射方向。

RayGen每路径按顺序执行：
1. 从相机发第一条TraceRay，取得最近交点的材料ID和t；要求命中Glass。
2. 重建p，对本固定平面做p.z=0的浮点投影；以CPU可重放的hash得到u。
3. 根据d·ng选择etaI/etaT和朝当前介质的法线，计算k、F、分支、方向和weight。
4. 从p沿新方向发第二条TraceRay。
5. 命中相应朝向的灯则L=weight*Le；miss时L=0。前一次为delta，灯命中MIS权重1；不发普通NEE射线。

本节初始beta=1，所以输出weight也是一次散射后的beta。etaScale写入并验证，但本节仅一散射，没有执行RR随机终止。两次TraceRay都在RayGen中顺序调用，ClosestHit只写payload，不嵌套追踪，因此管线最大递归深度仍为1。

## OPAQUE不等于物理不透光

代码调用`TraceRay(scene,RAY_FLAG_FORCE_OPAQUE,255,0,0,0,ray,payload)`：
scene为TLAS；flag禁止AnyHit；255为实例mask；三个0依次是ray contribution、geometry multiplier、Miss index；ray提供起点/方向/TMin/TMax；payload为inout命中结果。
所有实例共用一个HitGroup且instance contribution=0，所以命中表索引始终0；靠对象表区分材质。

OPAQUE在求交层控制是否调用AnyHit，不会自动把材质定义成吸收体。玻璃界面必须被命中，然后材质决定生成反射或折射射线。IgnoreHit通常适用于alpha镂空等拒绝候选交点的场景；直接忽略玻璃界面会保持原方向并丢掉Fresnel/介质切换。这里未设置ACCEPT_FIRST_HIT，仍寻找最近有效交点。
参考：[Microsoft Ray Flags](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ne-d3d12-d3d12_ray_flags)、[TraceRay](https://learn.microsoft.com/en-us/windows/win32/direct3d12/traceray-function)。

## 数据布局、所有权与同步

Config为80B StructuredBuffer元素：0字节uint4(width,height,glassID,upperID)，16字节uint4(lowerID,seed,mode,pad)，32字节float4(斜率,side,外IOR,内IOR)，48/64字节float4上下灯Le。
每条路径输出128B，均为连续16B行：

| 偏移 | 内容 |
|---:|---|
|0|position.xyz和第一段t|
|16|outgoing.xyz和F|
|32|weight、etaScale、q²、eventMass|
|48|u、pr、etaI、etaT|
|64|灯交点xyz和第二段t；miss全零|
|80|正确L.rgb和灯命中MIS权重|
|96|漏掉透射q²的错误RGB，仅诊断|
|112|uint4(event,首次材料ID,第二次材料ID,TraceRay计数)|

C++ static_assert验证80B/128B与关键偏移。这里没有CBV的256B槽对齐要求。每线程独占一个输出记录，无跨线程读写依赖；所有返回路径都写初始化后的记录。
根签名t0 TLAS、t1 80B对象表、t2配置、u0输出；payload16B仅含material/t/padding。ClosestHit经InstanceID查对象表，写material+1，0留给Miss。真实网格身份通过payload传回，不能只根据反射/透射标签假设命中了哪个灯。

宿主拥有GpuScene、BLAS、InstanceFrame；全程活到最后读回Fence完成。配置经UPLOAD复制，输出DEFAULT UAV转COPY_SOURCE，拷到READBACK COPY_DEST，同一DIRECT队列提交并等Fence后Map复制到CPU vector。Map不承担等待。上传staging/BLAS scratch在构建Fence完成后释放；helper临时资源在读回完成后析构。
HRESULT/等待失败由共享后端抛异常；首次命中错误、事件无效、结果超差或调试层报告会使程序退出1，脚本停止。未实现设备恢复或异步帧资源退役池。

## 实机结果

2026-10-21 RTX5070，C++ VS2022，HLSL DXC lib_6_3。6种情况×2种抽样模式×8 seed×4096路径=393216路径；每条2次TraceRay，共786432。
Khronos Validator0错误/0警告；D3D debug/GPU validation0；Fence97/97；逐字段最大差4.64916229248e-6，阈值3e-5。所有命中身份、随机数重放、方向、位置、权重、etaScale和L检查通过。
CPU先独立验证GPU的F/pr误差，再按实际GPU float阈值核对选中事件；统计均值另与double解析目标比较。避免把临界于随机阈值的舍入误差与错误概率混为一谈。

以下mode0均按F抽样，每行32768路径：

| 用例 | 反射数 | miss数 | 实测红均值 | SE | 解析红值 |
|---|---:|---:|---:|---:|---:|
|空气→玻璃0°|1313|0|.117382815044|.000770453447447|.117333335082|
|空气→玻璃60°|2986|0|.153689245925|.00113055324733|.152310552047|
|空气→玻璃80°|12820|12820|.0541124190404|.000239647521249|.0544262804206|
|玻璃→空气30°|1824|0|1.71093734422|.00202652654167|1.71169576012|
|玻璃→空气45°全反射|32768|0|.20000000298|0|.20000000298|
|同IOR|0|0|.20000000298|0|.20000000298|

mode1半半抽样的全部RGB均值也通过6SE+2e-6容差；不宣称Fresnel模式总是更低方差。均值包含所有零贡献miss。
正视正确RGB=(.117382815,.268002333,.430642703)，漏q²错误红均值=.224041751，对应错误目标约.224。该错误对照只写诊断，不反馈给正确路径。
内部30度的红均值超过1，保留线性HDR浮点值；本节没有色调映射、窗口或性能计时，不作视觉质量/性能结论。

## 边界与下一节

glTF提供几何和灯emissiveFactor；名称Glass由宿主显式映射为教学介质，IOR来自配置，未声称支持KHR_materials_transmission/ior等扩展。固定ng、单位变换、有限平面、TMin=1e-5与p.z=0只适用于本米尺度fixture，非任意网格鲁棒起点偏移。
引擎通常使用通用材质表、命中属性、介质状态及多帧资源；其底层仍遵循求交→采样→更新路径。alpha透明与折射是不同机制，不能靠交换链混合模式实现本课的光路。
下一节处理有厚度玻璃的进入/离开、内部反射与介质状态，复用本节HLSL采样器；GGX和完整glTF映射仍待后续。

自测：1. 为什么使用FORCE_OPAQUE仍能产生折射？直接IgnoreHit玻璃会漏掉什么？
2. 80度反射样本miss后，平均值分母应包含这些路径吗？
3. 相机→界面→灯包含两次TraceRay，为什么最大递归深度仍为1？
