# R.13.3 矩阵相机接入 DXR 与帧资源

> 2026-10-13：同名dxr_view代码已在R.13.4扩展为三实例/属性诊断，结果stride128、payload84B、增加VB/IB SRV。本文记录R.13.3当时的布局与单矩形实测；当前运行结果请对照`R.13.4-从命中约束推导位置与法线.md`。

2026-10-10。新版R.13第三节。目标：把上节View/Projection的数学结果，以明确的CPU/HLSL布局和资源生命周期交给真实DXR RayGen。本课无窗口、无光照、无累积；“8帧”指8次相机参数与命令提交，不代表执行了Present。

## 1. 上节三题答案

1. View的坐标是dot(Q-E,R/U/F)，展开后常量项自然是-E·R、-E·U、-E·F。直接用-E.xyz只在相机基与对应世界轴一致等特殊条件下成立。
2. 固定FOV、宽高比和姿态，near改变时近面宽高同步变化，所以同一像素的近面点仍在原射线上；方向不变，允许命中的起始范围变了。
3. 本课reversed-Z中深度1对应近面点。表面真实深度对应表面位置，前提是使用生成该深度时一致的View/Projection/ViewRect。只有xy时深度不确定，只能确定射线。

## 2. 新代码与本节边界

- `learning/sandbox/d3d12/r13-renderer/dxr_view_reference.h`：ViewData布局、8组单变量相机配置、DirectXMath矩阵、独立double解析射线和矩形求交参考。
- `learning/sandbox/d3d12/r13-renderer/dxr_view.hlsl`：cbuffer、矩阵反投影、有限近端主射线、8B payload、48B诊断输出。
- `learning/sandbox/d3d12/r13-renderer/dxr_view_pipeline.cu`：DXR设备/AS/State Object/SBT；两槽Upload CB、帧命令资源与Fence、GPU读回验收。

作为新版R.13后续扩展起点；旧dxr_camera/r13_camera_math实验保留对照。无CUDA kernel；nvcc编译宿主，DXC编译真正执行的DXR shader。

世界+X前/+Y右/+Z上，矩形位于x=4，y范围±1.375、z范围±.9375，一个BLAS含两个三角形，一个TLAS实例ID1且变换为单位矩阵。不改变场景，只改变相机，因此只构建一次AS。ClosestHit只写RayTCurrent和InstanceID；属性/法线详解留在R.13.4。

## 3. 二进制协议与三种大小

|字段|CPU/HLSL对应|offset|bytes|
|---|---|---:|---:|
|invViewProjection|XMFLOAT4X4 / row_major float4x4|0|64|
|eyeNear|float[4] / float4，相机xyz、near|64|16|
|forwardMax|float[4] / float4，单位前向xyz、TMax|80|16|
|viewRect|uint32_t[4] / uint4，左上xy、宽高|96|16|
|targetInfo|uint32_t[4] / uint4，画布宽高、提交序号、0|112|16|

有效数据128B，CBV起始地址按256B对齐，因此每槽步长256B，两个槽总分配512B。128/256/512不能互相替代。HLSL字段打包以16B寄存器行组织，256B是D3D12常量缓冲地址/分配层要求，不是要求每个float4占256B。

CPU用sizeof/offsetof静态断言；本次DXC -dumpbin确认实际offset=0/64/80/96/112、cbuffer Size128、输出元素Size48。CPU按行保存矩阵；shader声明row_major，使用mul(v,M)，上传前不再transpose。存储约定与数学乘法方向分别指定。

## 4. Upload与root CBV

创建512B Upload buffer，状态GENERIC_READ，Map后持续保留CPU地址。每帧仅在对应槽完成后写128B；没有CopyBufferRegion到Default的步骤，GPU直接读取Upload资源中的常量。本课为看清小量动态参数的生命周期采用此路径；大型引擎会封装uniform buffer/上传分配器，并按平台与性能选择存储路径，不保证逐字使用本例API组合。

```cpp
HRESULT Map(UINT Subresource,const D3D12_RANGE* pReadRange,void** ppData);
void SetComputeRootConstantBufferView(UINT RootParameterIndex,
                                     D3D12_GPU_VIRTUAL_ADDRESS BufferLocation);
```

Map的Subresource=0，因为是buffer；pReadRange={0,0}表示CPU不读，只写；ppData接收CPU可访问地址。它不等待GPU，也不复制一份快照。CPU地址用于memcpy，GPU VA用于root绑定，不能互换。最终所有使用完成才Unmap/释放资源。

Root Signature有3个全局root descriptor：索引0 SRV t0=TLAS；索引1 UAV u0=输出；索引2 CBV b0=View。每个占2 DWORD，共6 DWORD。root参数索引2不是b2，ShaderRegister=0才与b0对应。绑定前先SetComputeRootSignature。

SetComputeRootConstantBufferView(2,baseVA+slot*256)记录GPU地址，不复制128B参数。这里不用descriptor heap、CreateConstantBufferView或SetDescriptorHeaps。API也不接收SizeInBytes，shader访问范围与有效资源由应用保证。若使用descriptor-table CBV，才另有CBV描述符及其大小字段，不混为一谈。DXR使用compute root绑定方法，实际执行仍为SetPipelineState1+DispatchRays。

## 5. 为什么要两个资源槽

GPU异步执行，ExecuteCommandLists返回不意味着完成；CPU随后不能覆写GPU还要读取的常量。槽内资源包括：一个256B常量区段、command allocator/list、Default输出、Readback输出、retireFence和该次case编号。

静态AS构建提交后signal1并等待完成。随后：帧1使用slot0/offset0并signal2；帧2使用slot1/offset256并signal3；帧3复用slot0前必须等待completed>=2，然后读取旧结果、覆盖参数、Reset allocator/list并提交。依此类推，最后signal9。

`frame % 2`只选槽，不证明槽可写；`completed >= slot.retireFence`才证明GPU结束使用。即使Map保持有效、命令列表已经Close或者CPU已经切换到下一帧，也不能替代Fence判断。单队列按序执行，可有最多两个槽在途，不声称本次实测证明了CPU/GPU性能重叠。

资源状态：Upload始终GENERIC_READ；TLAS/BLAS保持AS状态；每槽Default输出首次COMMON→UAV，Dispatch后UAV→COPY_SOURCE，再CopyResource到一直COPY_DEST的Readback；槽复用时COPY_SOURCE→UAV。输出的transition建立GPU写→copy读顺序；Fence负责CPU读写与资源复用，两者职责不同。

CPU读回前等待槽Fence。Map Readback范围覆盖整个输出，Unmap写范围{0,0}表示CPU未写。最后两槽全部retire后才释放共享View Upload、SBT、AS和事件。能力/HRESULT/DXIL/export/等待/数值错误均明确报错；等待检查设备移除哨兵和10秒超时。本例失败即退出，不实现设备重建恢复。

## 6. RayGen映射与射线

画布/Dispatch为384×256，基线ViewRect仅320×180。DispatchRaysIndex表示画布绝对像素；先判断是否在ViewRect内，再减去左上偏移。视口外仍写零记录和ID=0xffffffff，以便检查每个输出槽确实由本次提交写入。

```hlsl
float2 uv=(float2(pixel-viewRect.xy)+0.5)/float2(viewRect.zw);
float2 ndc=float2(2*uv.x-1,1-2*uv.y);
float4 h=mul(float4(ndc,1,1),invViewProjection);
float3 direction=normalize(h.xyz/h.w-eyeNear.xyz);
float tNear=eyeNear.w/dot(direction,forwardMax.xyz);
```

实际shader在除w、单位化和TraceRay前检查有限值、非零长度、前向和合法范围；错误ID=0xfffffffe交由CPU验收报错。TMax=20沿射线米数，与无限远投影无关。随后TraceRay主射线，不剔除背面；主Miss写(-1,0)，命中写(t,1)。MaxTraceRecursionDepth=1；只有8B payload，不把48B诊断记录误设成payload。

每像素输出：float4 originNear、float4 directionHit、uint4 stamp，共48B。stamp包含绝对像素xy、提交序号和hitID。它能检查上传槽过早覆盖、CBV绑定错误或遗留输出，不能仅凭画面“看起来正常”推断同步正确。

## 7. 独立参考与实测

CPU参考不读取上传矩阵：从相机姿态、FOV与ViewRect用double解析式构造方向，独立解x=4平面及矩形边界，再应用tNear与20米上限。所有画布像素均检查序号/地址/有限值；视口内还检查原点、方向、TMin、hitID和hitT；没有忽略轮廓不一致。

2026-10-10 DXC lib_6_3编译成功；宿主build.ps1/sm_120编译成功。RTX5070/DXR Tier1.1实际执行：

|提交|相对基线变化|有效射线|命中数|
|---:|---|---:|---:|
|1|基线，FOV60、near.1、320×180|57600|7992|
|2|平移E到(0,.25,.125)|57600|7811|
|3|朝向改为normalize(1,.12,.08)|57600|8110|
|4|垂直FOV改50度|57600|11880|
|5|ViewRect高度改200，宽保持320|64000|9840|
|6|ViewRect左上改(37,19)|57600|7992|
|7|near改5米，矩形x=4被近面排除|57600|0|
|8|恢复基线|57600|7992|

8组全部PASS；总有效射线467200，画布记录786432；每组mismatch=0/invalid=0。最大方向误差2.43e-7、原点误差0、TMin误差1.53e-6（near5组）、命中t误差8.91e-7。两槽复用6次、验证8次、Fence目标9/完成9、Debug0错误0警告、exit0。

ViewRect移位只改变像素写入位置，本例局部投影/覆盖不变；FOV变小使矩形占更多像素。第三/四/五组分别单独改变朝向/FOV/宽高比，不把多变量差异错误归因给某一参数。

## 8. 运行与后续

在仓库根目录：

```powershell
& 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\dxc.exe' -T lib_6_3 -Fo learning/sandbox/d3d12/r13-renderer/dxr_view.dxil learning/sandbox/d3d12/r13-renderer/dxr_view.hlsl
.\learning\sandbox\build.ps1 .\learning\sandbox\d3d12\r13-renderer\dxr_view_pipeline.cu -NoRun
.\learning\sandbox\d3d12\r13-renderer\dxr_view_pipeline.exe .\learning\sandbox\d3d12\r13-renderer\dxr_view.dxil
```

本课输出读回数值，不输出新的法线图；下一节R.13.4在这一矩阵相机主线上读取VB/IB和重心属性，生成位置/法线/深度诊断图。R.13.5才加入NEE，R.13.6–7累积和history，R.13.8窗口显示。两槽不等于两个采样历史，不与渐进累积混同。

自测：128B数据为什么用256B槽？绑定了CBV后能立即覆盖同一内存吗？root索引2为什么可以对应b0？

来源：[root CBV](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12graphicscommandlist-setcomputerootconstantbufferview)、[Map](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12resource-map)、[上传与对齐](https://learn.microsoft.com/en-us/windows/win32/direct3d12/uploading-resources)、[HLSL常量打包](https://learn.microsoft.com/en-us/windows/win32/direct3dhlsl/dx-graphics-hlsl-packing-rules)。
