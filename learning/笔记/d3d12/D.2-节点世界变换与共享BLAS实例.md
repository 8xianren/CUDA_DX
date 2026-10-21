# D.2 节点世界变换与共享BLAS实例

2026-10-20，一个完整课节。[代码入口](../../sandbox/d3d12/gltf-scene/README.md)。D.1完成资源上传；D.2把同一套节点世界矩阵用于光栅绘制与TLAS，实际DispatchRays验证命中身份。下一节D.3处理纹理/材质采样。

## D.1自测答案

1. Unmap结束CPU映射访问，不会等GPU读完。Upload资源至少活到最后读取它的提交Fence完成。
2. 2×2 RGBA8只有16B有效像素，但复制布局RowPitch256B，第二行始于256，末行8B后结束，TotalBytes264B。它是复制布局，不是GPU内部texture排布。
3. 局部索引保持0/1/2，光栅用BaseVertexLocation加firstVertex；BLAS顶点地址加firstVertex×48、索引地址加firstIndex×4。

## 几何共享与实例粒度

复用C.4的trs.gltf：源glTF有1个mesh、2个primitive，Left/Right两个节点引用同一mesh。Assimp把primitive拆成2个CpuMesh；本课每CpuMesh建1个BLAS，因此2个BLAS、4个node-primitive实例，而不是每节点复制几何/BLAS。一个多geometry BLAS也可表示源mesh，属于另一种粒度选择，当前没有实现。

VB/IB按D.1上传一次。BuildMeshBlases只遍历gpu.geometry，result持续保留；每帧BuildInstanceFrame遍历cpu.instances，写World/材质/节点/mesh编号，生成TLAS描述符。移动父节点时只改变实例，不重写局部顶点，不重建BLAS。代码维护父先子后的CpuNode数组，UpdateWorldMatrices做全量层级更新，尚无脏节点优化。

## 先由坐标关系得到矩阵顺序

约定列向量：p_parent=L_child p_local，p_world=W_parent p_parent，所以W_child=W_parent L_child。CPU Matrix4按行存储m[r*4+c]，这与列向量乘法并不冲突。

fixture父变换T(10,1,0)Rz(90°)S(2,3,1)：

```text
父World = [0 -3 0 10
           2  0 0  1
           0  0 1  0
           0  0 0  1]
```

Left局部Tx(-2)的原点先缩放为(-4,0)，旋转为(0,-4)，平移得到(10,-3,0)；Right局部Tx(2)得到(10,5,0)。父x增加3，两个原点分别变成(13,-3,0)/(13,5,0)。这组已知数值独立于GPU打包，程序先断言再对照图像。

保留完整World矩阵，不分解回TRS；C.4中非均匀缩放与旋转可能产生剪切的讨论继续有效。当前拒绝非仿射、非有限或行列式绝对值小于1e-10的矩阵；阈值是教学适配策略，不是普遍的数学可逆判据。零缩放拒绝分支已实测。

## 对象数据与光栅

InstanceRecord共80B：World64B，material/node/mesh/padding各4B。HLSL StructuredBuffer<ObjectRecord>使用row_major float4x4，再使用mul(world,float4(local,1))。每draw仅通过b1的1个32位root constant传入objectIndex，世界矩阵从共享对象表t1读取，避免复制同一套常量结构。

VS执行clip=VP*World*local。DrawIndexedInstanced仍使用D.1网格的firstIndex/firstVertex，同一个mesh可以重复draw而不创建新VB。PS输出uint4(instance+1,material+1,primitive+1,0)到R32G32B32A32_UINT，零保留给背景。当前对象表在UPLOAD资源中，便于观察CPU更新/帧寿命；不是为大规模动态场景优化的最终存放策略。

## DXR Transform与身份

```cpp
typedef struct D3D12_RAYTRACING_INSTANCE_DESC {
    FLOAT Transform[3][4];
    UINT InstanceID : 24;
    UINT InstanceMask : 8;
    UINT InstanceContributionToHitGroupIndex : 24;
    UINT Flags : 8;
    D3D12_GPU_VIRTUAL_ADDRESS AccelerationStructure;
} D3D12_RAYTRACING_INSTANCE_DESC;
```

Transform是row-major instance-to-world仿射3×4。我们CPU的World也是按行存储，因此逐元素复制前三行，不转置；不能因为glTF JSON按列存储就再次转置已经适配过的Matrix4。最后一行固定0/0/0/1而省略。

InstanceID是我们指定的24位编号，本课等于当前对象表索引，不等于节点编号，也不等于InstanceIndex()；节点含两个primitive会对应两个ID。重排/删除对象时必须保持当帧TLAS和对象表一致，不能把当前扁平编号当成持久实体ID。InstanceMask为8位可见性，0不参与本课0xff射线mask。Contribution是HitGroup表寻址贡献，不是材质编号；所有实例用同一个HitGroup，所以填0。Flags关闭三角形剔除；AccelerationStructure指向共享BLAS result的GPU地址（256B对齐，保持AS状态）。

本课描述符64B，数组元素满足16B对齐。InstanceFrame同时持有CPU records/descriptors、GPU可读objects/instanceUpload，以及TLAS result/scratch，防止生命周期丢失。

## TLAS构建的关键输入

BuildAcceleration是D.1/D.2共享函数，先查询prebuild sizes，再创建result/scratch并录制构建及UAV barrier：

```cpp
void GetRaytracingAccelerationStructurePrebuildInfo(
    const D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS* inputs,
    D3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO* info);
void BuildRaytracingAccelerationStructure(
    const D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC* desc,
    UINT numPostbuildInfoDescs,
    const D3D12_RAYTRACING_ACCELERATION_STRUCTURE_POSTBUILD_INFO_DESC* postbuildInfoDescs);
```

inputs在TLAS路径：Type=TOP_LEVEL、Flags=PREFER_FAST_TRACE、NumDescs=4、DescsLayout=ARRAY、InstanceDescs=描述符数组的GPU地址。BLAS路径的pGeometryDescs则是CPU描述数组指针：两者虽同属union，却不能互换地址空间。

prebuild输出ResultDataMaxSizeInBytes/ScratchDataSizeInBytes供资源分配，本课不输出postbuild信息，因此后两个构建参数0/null。build.Dest为result GPU地址，Scratch为scratch GPU地址，Source保持0（全量构建）。本节每帧新建TLAS，未使用ALLOW_UPDATE/PERFORM_UPDATE或原地refit。

BLAS result以RAYTRACING_ACCELERATION_STRUCTURE状态持久存在，scratch使用UNORDERED_ACCESS；构建后UAV barrier建立BLAS写→TLAS读以及TLAS写→TraceRay读的依赖，不把AS切成普通SRV资源状态。

## 相机约定与RayGen

采用明确的正交诊断相机，复用R.13数学约定：eye=(11,1,10)，朝-Z、up=+Y、右手观察坐标；近远距离1/20；观察盒x∈[-7,7]、y∈[-8,8]；D3D深度[0,1]；viewport224×256与14:16视域比例一致，像素中心x+.5/y+.5，不随机抖动。

View=T(-eye)。由x=-7/+7映射-1/+1得x_ndc=x_view/7；y同理/8；观察空间z=-1→0、z=-20→1，设az+b解得a=b=-1/19。由此组成P，再VP=P*V。InverseVP以解析式构造并验证VP*InverseVP≈I。camera-pan只改变eye.x+0.37。

Camera常量144B：VP64B、InverseVP64B、width/height/pad/pad16B；实际UPLOAD分配256B，根CBV地址满足256B对齐。光栅读取VP，RayGen读取InverseVP：

```text
ndc.x=2*(x+.5)/width-1
ndc.y=1-2*(y+.5)/height
nearH=InverseVP*(ndc.x,ndc.y,0,1)
farH =InverseVP*(ndc.x,ndc.y,1,1)
nearP=nearH.xyz/nearH.w，farP=farH.xyz/farH.w
origin=nearP，direction=normalize(farP-nearP)
TMin=0，TMax=length(farP-nearP)
```

这里原点位于近裁面z=9，远点z=-10，射线长度19。逆矩阵只处理相机，不在RayGen逐个乘物体逆World；实例求交变换由DXR承担。本节保持原glTF轴约定，没有暗中套UE的X前向坐标系。

## 真正发射射线并取回命中身份

DXR lib_6_3含RayGen/Miss/ClosestHit，payload为16B uint4、attributes8B float2，最大递归深度1。一个HitGroup；Shader Table三个表各以64B起点对齐，32B identifier，无local root参数。全局根签名b0相机、t1对象表、t0 TLAS、u0结构化输出、b1每draw编号；DXR使用SetComputeRoot*，光栅使用SetGraphicsRoot*，两套绑定状态不能混用。

TraceRay(scene,FORCE_OPAQUE,0xff,0,0,0,ray,payload)：mask0xff，hitgroup贡献0、geometry乘数0、miss索引0。这里强制不透明只作ID诊断，不宣称实现MASK/BLEND。ClosestHit用InstanceID()访问objects[id].material，PrimitiveIndex()给本BLAS geometry中的三角形编号。Miss写零。最终比较完整instance/material/primitive三元身份，不仅比较有无命中。

## 同步、失败路径与边界

先上传VB/IB并构建2个BLAS，提交Fence1完成，才释放Upload和BLAS scratch；BLAS result持续存活。四个阶段分别创建对象表/instance desc/TLAS并录制光栅+DXR+readback，等待Fence2..5完成后读结果及回收帧临时资源。所有GPU使用的对象和shader table保持到完成；ComPtr只管引用，不代替Fence。

输入规范校验先走C.6入口。矩阵非法在分配/提交TLAS前报错；HRESULT失败、DXC失败、GPU timeout、设备移除都中止验收；本节没有设备恢复。每个阶段同步等待是确定性测试，不是多帧异步渲染。运行时每阶段重建PSO/StateObject也为独立验证便利，生产应缓存不变管线。

本节平面诊断关闭深度，几个方块互不重叠；CPU参考解二维重心坐标。不能据此声称任意3D遮挡、负缩放剔除、法线逆转置、透视相机全覆盖。D.3接材质，R.13已有一般相机/法线讲义；动态骨骼/BLAS更新留H。保留完整矩阵并不表示已实现编辑器重挂API。

## 实测结果与运行

工作目录：仓库根；沿用C.6的Node Validator、VS2022/CMake，DXC可从PATH找到。本机实际DXC路径C:/VulkanSDK/1.4.357.0/Bin/dxc.exe。无CUDA kernel。

```powershell
& learning/sandbox/d3d12/gltf-scene/build_importer.ps1 -Lesson d02
& learning/sandbox/d3d12/gltf-scene/verify_instances.ps1
```

2026-10-20 RTX5070：每阶段57344像素，四阶段共229376；所有CPU/光栅/DXR身份一致，mismatch0、edge_excluded0。代码有明确的重心边界带排除策略用于避免top-left/共享边差异，本次并未排除任何像素。

|阶段|有效命中像素|变化像素|比较基准|
|---|---:|---:|---|
|base|3072|0|初始|
|parent-moved|3072|6144|base|
|masked|2304|768|parent-moved|
|camera-pan|3072|1104|parent-moved，同样可见性/物体位置，仅改变相机|

每个node origin独立数值检查通过，VB/IB地址及局部顶点保持，实例0/2共享BLAS0、1/3共享BLAS1。只构建2个BLAS、每阶段4个TLAS实例。零缩放拒绝通过。Fence5/5，D3D12 Debug与GPU Validation warning/error0；源Validator errors/warnings0。D.1三组GPU回归全部通过。

结果在results/d02：gpu.txt、validation.json、各阶段ray/raster BMP及ray PNG。PNG只是GPU整数命中ID的固定调色，不含曝光或色调映射，不是PT光照图；base/moved图已目视检查。

自测：①父节点移动为什么无需重写局部VB或重建BLAS，但仍需更新TLAS？②为什么本课World复制到DXR Transform不需要转置？③InstanceID和InstanceContributionToHitGroupIndex各解决什么问题？

## 官方参考

- [D3D12_RAYTRACING_INSTANCE_DESC](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ns-d3d12-d3d12_raytracing_instance_desc)
- [InstanceID](https://learn.microsoft.com/en-us/windows/win32/direct3d12/instanceid)
- [AS构建输入](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ns-d3d12-d3d12_build_raytracing_acceleration_structure_inputs)
