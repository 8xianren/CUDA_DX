# R.11 第四部分：Geometry × RayType × Instance 的 Hit 表寻址

## 范围与真实验收

2026-10-08：新增独立 `dxr_geometry_raytype_pipeline.cu` / `dxr_geometry_raytype.hlsl`。保留R.11前三部分和R.12全部文件。一个BLAS含两个Geometry，每Geometry一个三角形；两个TLAS实例共享BLAS，InstanceID均7，contribution基址0/4。八个RayGen调用覆盖2实例×2geometry×2raytype。

RTX5070 / Tier1.1：DXC lib_6_3真编译，build.ps1默认sm_120编译宿主。normal与--swap-bases均真实运行Exit0、stderr空、无超时/截断、Fence target1 completed1、InfoQueue errors0 warnings0。Shadow仅为第二种应用用途标签、使用独立ClosestHit输出身份，不实现阴影算法，不进入R.12。

## 概念与直觉

像每个场景实例拥有一组材质槽，每个几何槽再有Primary/Shadow两个程序选项。DXR不会认识这些名称，也不会自动替应用排列槽位；应用必须让TLAS基址、TraceRay参数和SBT布局相互一致。

公式（均以record条数而非字节计）：

`index = InstanceContributionToHitGroupIndex + GeometryIndex * MultiplierForGeometryContributionToHitGroupIndex + RayContributionToHitGroupIndex`

本例index=4*i+2*g+t。GPU地址才是 `HitGroupTable.StartAddress + index * StrideInBytes`。不能把instance contribution写成字节偏移，也不能把geometry乘数2与record字节stride64混淆。

GeometryIndex是BLAS输入Geometry数组序号，不是PrimitiveIndex；每个Geometry在本例都只有primitive0。InstanceID是应用标识，不参与上述公式。InstanceIndex是TLAS实例序号，也不是contribution。

## 真实代码布局

宿主117–134行：VB含6个float3（每顶点12B），Geometry0用前三个顶点，Geometry1用后三个顶点；共享IB 0/1/2，索引相对于各Geometry的VertexBuffer.StartAddress。两个descriptor都OPAQUE，NumDescs=2、ARRAY布局传geoms，不是把两三角形塞进单Geometry。

宿主142–150行：实例0平移x0，实例1平移x8。BLAS局部geometry中心x0/x3，所以四个世界中心是0/3/8/11。两实例ID7；normal基址0/4，swap模式4/0，其他条件不变。

HLSL9–20行：x=4*physicalInstance+2*geometry+raytype，射线方向+Z，源z=-2；同一实例/Geometry两种用途射向同一点。TraceRay(scene,NONE,0xff,raytype,2,0,ray,p)：AS、flags、mask、ray贡献、geometry乘数、Miss索引、RayDesc、payload。payload只含uint code，未传实例/geometry/raytype答案；初值FFFFFFFF，Miss置0。

宿主Local Root Signature仍是b0两个32bit constants，依次recordCode/cookie，不调用SetComputeRoot32BitConstants绑定局部参数。Local association绑定PrimaryGroup/ShadowGroup，Global只有t0/u0。两个HitGroup分别import PrimaryHit/ShadowHit；ShaderConfig payload4B、attributes8B；递归深度1，两个用途不嵌套TraceRay。

## SBT与编码

宿主232–247行：RG@0、Miss@64、Hit表@128。8条record，每条identifier32B+recordCode4B+cookie4B+padding24B，Stride64；总SBT640B，Hit表Size512B。record stride须32B对齐，表起点须64B对齐，本次数值64相同不代表约束相同。

|r|record实例块|Geometry|用途|字节offset|
|---:|---:|---:|---|---:|
|0|0|0|Primary|128|
|1|0|0|Shadow|192|
|2|0|1|Primary|256|
|3|0|1|Shadow|320|
|4|1|0|Primary|384|
|5|1|0|Shadow|448|
|6|1|1|Primary|512|
|7|1|1|Shadow|576|

HLSL27–33行：入口写高半字节A/B，中间来自所选record的local code，低字节来自真实InstanceID()。cookie5A错误则输出FFFFFFFF。

`code = (Primary ? A0000000 : B0000000) | block<<16 | geometry<<12 | raytype<<8 | InstanceID`

解码block=(code>>16)&15、g=(code>>12)&15、t=(code>>8)&15、ID=code&255。block是record所属实例数据块，不是无条件代表物理命中实例；交换实验恰好区分两者。A/B由不同shader入口写入，不仅是local数据标签。

## 输出与因果对照

normal：
```
BLAS geometries=2; TLAS instances=2; IDs=7/7; bases=0/4
ray0 a0000007  decoded=(0,0,0,ID=7)
ray1 b0000107  decoded=(0,0,1,ID=7)
ray2 a0001007  decoded=(0,1,0,ID=7)
ray3 b0001107  decoded=(0,1,1,ID=7)
ray4 a0010007  decoded=(1,0,0,ID=7)
ray5 b0010107  decoded=(1,0,1,ID=7)
ray6 a0011007  decoded=(1,1,0,ID=7)
ray7 b0011107  decoded=(1,1,1,ID=7)
Fence target=1 completed=1
InfoQueue: errors=0 warnings=0
R.11 geometry x raytype: PASS
normal NativeExit=0
```

--swap-bases只改InstanceContributionToHitGroupIndex，SBT字节、射线目标、几何和ID都不变。ray0–3输出原record4–7的编码，ray4–7输出原record0–3的编码，两轮都ID7且四种(g,t)不变。最终swap-bases NativeExit=0、Fence1/1、InfoQueue0/0。这是受控改变基址产生的实测，不是单凭相同ID猜测因果。

## 所有权、同步、失败路径

宿主259–292行：BuildBLAS→UAV barrier→BuildTLAS→UAV barrier→输出COMMON转UAV→DispatchRays8×1×1→输出转COPY_SOURCE→CopyResource到READBACK→Close/Execute→Signal1→等最多10秒→Map32B。Barrier建立GPU依赖，Fence建立CPU读回时机；VB/IB/实例/SBT/Scratch/AS全程持有COM引用至GPU结束，Unmap不等于GPU完成。

UAV为8项uint（32B），每调用只写自己的索引。CPU293–310行独立从物理射线序号与本轮基址计算预期，不把SBT字节再读一遍当参考。HRESULT、缺失export、cookie/编码不符、Fence等待失败及任何Debug warning/error均导致失败。InfoQueue采样覆盖提交与读回，不宣称覆盖最终设备隐式析构后的消息。真正进程退出由exec的NativeExit确认。

## 重现

仓库根目录PowerShell：
```powershell
& 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\dxc.exe' -T lib_6_3 -Fo learning/sandbox/d3d12/r11-04-geometry-raytype/dxr_geometry_raytype.dxil learning/sandbox/d3d12/r11-04-geometry-raytype/dxr_geometry_raytype.hlsl
& .\learning\sandbox\build.ps1 learning\sandbox\d3d12\r11-04-geometry-raytype\dxr_geometry_raytype_pipeline.cu -NoRun
& .\learning\sandbox\d3d12\r11-04-geometry-raytype\dxr_geometry_raytype_pipeline.exe .\learning\sandbox\d3d12\r11-04-geometry-raytype\dxr_geometry_raytype.dxil
$LASTEXITCODE
& .\learning\sandbox\d3d12\r11-04-geometry-raytype\dxr_geometry_raytype_pipeline.exe .\learning\sandbox\d3d12\r11-04-geometry-raytype\dxr_geometry_raytype.dxil --swap-bases
$LASTEXITCODE
```

本例无CUDA kernel；sm_120是build.ps1宿主构建配置，DXIL目标lib_6_3。开发中交换模式日志曾残留swap-local字样，已改为swap-bases并重编译重跑两轮；不改变测试逻辑。

## 边界与收束

已验证：双Geometry真实BLAS、双实例基址、双rayContribution、8条record选择、Local参数、不同ClosestHit入口、相同InstanceID和基址交换对照。未验证：透明AnyHit/程序化Intersection、实际Shadow可见性、混合local signature布局、多Miss表选择、动态更新SBT、GPU-based validation、窗口resize/遮挡恢复。商业引擎一般把geometry对应子网格/材质并自动生成SBT；本课手写固定表为显露同一API寻址机制，不是生产资源管理方案。

R.11仍[~]：第四部分完成，剩余统一收束前三/四部分概念、绑定和验收边界，不把窗口扩展、任意local布局或R.12算法冒称已完成。

自测：为何实例1基址是4不是256？Geometry乘数0会让哪些记录无法被选？交换基址后block与物理实例为何不同？

官方规范：https://microsoft.github.io/DirectX-Specs/d3d/Raytracing.html
