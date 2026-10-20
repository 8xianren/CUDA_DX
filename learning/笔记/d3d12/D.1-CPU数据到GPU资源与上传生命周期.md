# D.1 CPU数据到GPU资源与上传生命周期

2026-10-20，一个完整课节。[共享代码和运行入口](../../sandbox/d3d12/gltf-scene/README.md)。不重复实现glTF解析；输入是C.3–C.6的自有CpuScene。下一节D.2接入节点世界变换/TLAS实例。

## 问题、假设与数据契约

CPU vector的地址不能直接作为独立GPU的顶点地址使用。我们要创建GPU资源、安排字节传输、说明格式，并确保资源在异步使用期间存活。使用硬件D3D12/DXR、单DIRECT队列，离屏256×256诊断；每次提交等待Fence只为确定性验收，不宣称生产流式加载方案。

源码按职责拆分：src/gpu_upload.h/.cpp负责设备/资源/上传/WIC解码/读回/BLAS构建检查，src/upload_preview.cpp负责光栅诊断，shaders/upload_preview.hlsl负责基础色显示，verify_upload.ps1负责资产和独立颜色锚点。

Vertex固定48B：position offset0 12B、normal offset12 12B、uv offset24 8B、color offset32 16B。indices全部uint32。按primitive对应的CpuMesh拼入共享VB/IB，MeshRange保存firstVertex/vertexCount/firstIndex/indexCount/material。索引保持各mesh局部编号，第二个mesh不能忘记BaseVertexLocation。

本节双primitive资产：原glTF mesh1/primitive2；Assimp对应CpuMesh2，顶点6，索引6，VB288B/IB24B，图片1，另建白色fallback图1，BLAS geometry2。Assimp追加默认材质后CPU材质表3项，不把它误称原文件有3个材质。

## 资源创建、CPU写入与GPU复制

关键API：

```cpp
HRESULT CreateCommittedResource(
    const D3D12_HEAP_PROPERTIES* pHeapProperties,
    D3D12_HEAP_FLAGS HeapFlags,
    const D3D12_RESOURCE_DESC* pDesc,
    D3D12_RESOURCE_STATES InitialResourceState,
    const D3D12_CLEAR_VALUE* pOptimizedClearValue,
    REFIID riidResource, void** ppvResource);
HRESULT Map(UINT Subresource, const D3D12_RANGE* pReadRange, void** ppData);
void Unmap(UINT Subresource, const D3D12_RANGE* pWrittenRange);
void CopyBufferRegion(ID3D12Resource* pDstBuffer, UINT64 DstOffset,
    ID3D12Resource* pSrcBuffer, UINT64 SrcOffset, UINT64 NumBytes);
```

HeapProperties选择DEFAULT/UPLOAD/READBACK；HeapFlags本课NONE；Desc说明BUFFER或TEXTURE2D、大小、格式、层级和用途；InitialResourceState是初始用途声明，不进行数据拷贝；OptimizedClearValue对普通buffer为null，本课RTV资源提供匹配的黑色/alpha1值；IID指定接口，ppv输出资源指针由ComPtr管理。当前运行时普通DEFAULT buffer以COMMON创建后显式barrier；AS保留专用状态。UPLOAD固定GENERIC_READ，READBACK固定COPY_DEST。

Map的Subresource为0，pReadRange={0,0}表示CPU不读，只写；ppData取得CPU虚拟地址。memcpy写入UPLOAD。Unmap的WrittenRange描述写入区间，不是发起GPU上传，更不等待GPU完成。CopyBufferRegion的两个offset和NumBytes单位均为字节；调用只录制，ExecuteCommandLists才提交。

UploadBuffer录制COMMON→COPY_DEST、复制、COPY_DEST→最终用途。VB最终VERTEX_AND_CONSTANT_BUFFER|NON_PIXEL_SHADER_RESOURCE，IB最终INDEX_BUFFER|NON_PIXEL_SHADER_RESOURCE，后者让AS构建读取几何。状态是合法访问和同步约定，不等于物理内存迁移。显式barrier之外，D3D12还存在COMMON提升/衰减；本课普通buffer在执行批次完成后可衰减，下一批预览只读时允许相应提升。

所有返回HRESULT的API通过Check转异常；创建/解码失败不继续提交。Copy/Barrier/Draw等void API通过Debug Layer和GPU Validation检查，不能只看HRESULT。GPU超时/设备移除是验收失败，本课终止程序，不包含设备恢复和安全重建流程。

## 纹理：编码字节、像素、上传布局

CpuImage仍保存PNG/JPEG编码流。Windows Imaging Component (WIC) 解码：内存stream→decoder→frame0→格式转换器→非预乘RGBA8。初始化COM在调用方完成，WIC接口由ComPtr持有。输出Pixels拥有像素vector；单图解码上限256MiB且边长不超过16384，超限或解码API失败报错。不实现mipmap链，仅mip0；不进行ICC颜色管理。

```cpp
void GetCopyableFootprints(const D3D12_RESOURCE_DESC* pResourceDesc,
    UINT FirstSubresource, UINT NumSubresources, UINT64 BaseOffset,
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT* pLayouts, UINT* pNumRows,
    UINT64* pRowSizeInBytes, UINT64* pTotalBytes);
```

输入是目标纹理desc，首子资源0、数量1、上传基偏移0。输出footprint包含Offset及行跨度RowPitch，NumRows是行数，RowSizeInBytes是有效行字节数，TotalBytes是所需上传空间。它描述可复制布局，不暴露GPU内部texture tiling。

2×2 RGBA8实测：每行8B、RowPitch256B、TotalBytes264B。第一行在0..7，第二行在256..263；最后一行后不必再分配完整padding，因此不是强行要求512B。分别逐行memcpy到对应RowPitch处。

CopyTextureRegion的目标location指TEXTURE2D的subresource0；源location指UPLOAD buffer及placed footprint；目标xyz均0、source box=null表示复制整个子资源。完成后转PIXEL_SHADER_RESOURCE|NON_PIXEL_SHADER_RESOURCE。

## 视图与材质

资源是像素存储，SRV是解释和寻址。每张图建立一个RGBA8_TYPELESS资源和两个SRV：UNORM（线性数值）、UNORM_SRGB（RGB采样解码，alpha仍线性）。descriptor heap为shader-visible CBV_SRV_UAV，descriptor步长由GetDescriptorHandleIncrementSize获取，不写死。

CPU GpuMaterial保存5个槽的descriptor索引及baseColorFactor；有图时index=image*2+srgb，基础色缺失时指白图，其他缺失槽保留UINT_MAX。不会用白色法线贴图冒充语义默认。这里是CPU端材质到descriptor的映射表；尚未创建DXR hit shader可读的GPU材质StructuredBuffer，D.2/D.3接入。

Root Signature含8个32位常量（xy映射4float+baseColor4float）、1个SRV表、固定point/clamp sampler。每draw选择该mesh对应材质SRV。D.1主动固定mip0/point/clamp，只验证上传与绑定，不声称实现资产全部sampler行为。alpha强制输出1，无MASK/BLEND/normal/PBR实现，D.3和PT材质课继续。

## 光栅与BLAS使用同一份几何

光栅VBV地址为总VB，stride48，IBV格式R32_UINT；Input Layout位置0/UV24/颜色32。DrawIndexedInstanced(indexCount,1,firstIndex,firstVertex,0)：第二个参数实例数1，第三个是索引元素起点，第四个加到局部索引上，第五个实例起点0。

预览约束明确：局部xy投到正方形目标，包围盒中心映射到0，最长边映射到[-0.8,0.8]；scale=1.6/max(dx,dy)，offset=-center*scale，z=0.5,w=1。没有D.2节点变换或透视相机，关闭深度/背面剔除，仅适合本节平面诊断。不是R.13相机的替代实现。

BLAS三角形输入：vertexAddress=VB地址+firstVertex*48，VertexCount为本mesh个数，VertexFormat=R32G32B32_FLOAT（只读position），stride48；indexAddress=IB地址+firstIndex*4，IndexCount为本mesh索引数，IndexFormat=R32_UINT。材质索引保存在MeshRange；geometry描述本身不包含我们的材质表。

每个CpuMesh构建一个临时BLAS作验收。GetRaytracingAccelerationStructurePrebuildInfo返回result/scratch需求；DEFAULT资源开启ALLOW_UNORDERED_ACCESS，result状态RAYTRACING_ACCELERATION_STRUCTURE，scratch为UNORDERED_ACCESS。Build后放UAV barrier。两类资源到Fence完成后释放。本节没有TLAS，也没有DispatchRays；构建成功不是射线命中验收，D.2承接持久BLAS/实例。

## 所有权与同步时间线

```text
CPU解析/解码 → memcpy到UPLOAD → 录制Copy/Barrier/读回/BLAS
                                      ↓ Close/Execute
                              Queue Signal Fence=1
                                      ↓ CPU等待完成
             比较READBACK，释放UPLOAD和临时AS/scratch
                                      ↓
          预览Draw/Copy读回 → Execute/Signal Fence=2 → 等待并保存图
```

GPU不会因为应用层ComPtr存在就自动保证顺序；ComPtr只负责CPU引用计数。GPU使用期间资源、descriptor heap和相关分配器必须存活。Fence完成前不Reset allocator、不重写上传数据、不Map后直接读取未完成的READBACK。Map本身不会等待GPU。生产方案通常以Fence值标记退役批次，在后续帧回收；本课只有两次阻塞等待用于验证。

CpuScene原始数组在memcpy完成且没有后续CPU用途后可释放；UPLOAD直到GPU复制读完才能释放；DEFAULT资源到最后一次GPU使用完成才可释放。本实验额外保留CPU参考数组和像素，以便逐字节比对，不代表渲染必须保留它们。

## Cooking、DMA与DirectStorage

本课运行时glTF→CPU解码→UPLOAD→DEFAULT用于理解契约。现代资产管线可在离线导入/Cooking时完成几何布局转换、纹理平台格式处理和资源打包。运行时CPU先读尺寸/格式/布局/包围盒/引用等元数据，分配资源并调度大块数据加载，不必遍历所有顶点/纹素。

DMA是数据搬运机制，不理解glTF对象或材质。GPU解压把指定压缩编码展开，同样不自动解析glTF或建立资源引用。DirectStorage是可选的批量I/O/加载与解压路径，不等于保证所有数据完全绕过系统内存；不自动创建我们的材质/描述符/BLAS。Cooking也不等于UE在任意版本/平台已启用DirectStorage。本节不实现DirectStorage。

若CPU真正要访问完整数据，可保留CPU副本（额外内存）、保留碰撞等专用简化表示（满足对应用途）、迁移算法到GPU（尽量留结果在GPU）、或需要时READBACK（传输及同步成本）。不是所有资源都必须CPU/GPU各保留一份。

## 实测与复现

工作目录：仓库根，首次依赖安装沿用C.6。C++/D3D12用VS2022 CMake，不含CUDA kernel，不需要nvcc架构参数。

```powershell
& learning/sandbox/d3d12/gltf-scene/build_importer.ps1 -Lesson d01
& learning/sandbox/d3d12/gltf-scene/verify_upload.ps1
```

RTX5070三项通过：defaults（3顶点/3索引/0源图/1 BLAS）、textured（3/3/1/1）、multi（6/6/1/2）。全部buffer和texture逐字节回读一致，每项Fence2/2，Debug Layer与GPU Validation warning/error0。multi两个固定像素按独立CPU sRGB解码→因子→编码计算，误差≤1码；非黑像素4624，实际预览已查看。结果在results/d01，各例有validation.json/gpu.txt/preview.bmp/preview.ppm，multi另有PNG。

textured沿用C.5资产，Validator有两项warning：OPAQUE下alphaCutoff无效，以及法线贴图缺显式切线；errors0。本节基础色预览不使用这两项，保留报告，不称全部规范诊断为零。GPU debug0是另一层统计。

该预览输出基础色诊断：SRGB SRV解码→线性因子→SRGB RTV编码；无光照计算、曝光或色调映射。正式路径追踪显示仍遵循R.13“线性HDR→曝光→色调映射→输出编码”，不把本图称为完整显示变换。

自测：①为什么Unmap后不能马上释放UPLOAD？②2×2 RGBA8为什么只有16B像素却需要264B复制布局？③第二个mesh索引仍是0/1/2，光栅和BLAS如何各自找到它的顶点？

## 官方参考

- [CreateCommittedResource](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12device-createcommittedresource)
- [Map](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12resource-map)
- [CopyBufferRegion](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12graphicscommandlist-copybufferregion)
- [GetCopyableFootprints](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12device-getcopyablefootprints)
- [BLAS triangles descriptor](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ns-d3d12-d3d12_raytracing_geometry_triangles_desc)
- [DirectStorage官方Windows样例](https://github.com/microsoft/DirectStorage)
