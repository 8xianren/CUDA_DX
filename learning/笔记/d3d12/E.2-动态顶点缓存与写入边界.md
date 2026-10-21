# E.2 动态顶点缓存与写入边界

2026-10-21。代码/运行入口：[cuda-interop](../../sandbox/d3d12/cuda-interop/README.md)，[正常结果](../../sandbox/d3d12/cuda-interop/results/e2/e2/summary.json)，[过期缓存负对照](../../sandbox/d3d12/cuda-interop/results/e2/e2-stale/summary.json)。E.1的实例表和双向Fence继续使用，不复制设备、导入器、渲染器。

## 从形变问题确定要改的量

E.1是p_world=M_instance p_local，只改变实例摆放。E.2要求形状自身变化，应该先生成q_local=F(p_rest,t)，再以M_instance q_local绘制。rest表示固定静止形状，不是上一帧结果。否则把绝对位移每帧叠加，会把形状变化误做成积分运动。

本课仅选择mesh0建立动态副本，mesh1继续读原始VB；共享同一mesh0的多个实例读同一份局部形状，然后分别做世界变换。若角色姿势不同，需要每姿势缓存或实例级索引，不能用本课一份缓存代表所有角色。

选择一个可独立验证的平面形变：希望x随原y偏移，y的偏移随原x平方增长，z不变。于是定义Δx=a*y、Δy=a*x²、Δz=0，得到F(x,y,z)=(x+a*y,y+a*x²,z)。a_f=(f mod 9-4)/16，取值[-.25,.25]。这是教学约定，不是物理求解或骨骼蒙皮。三个顶点变换后，硬件仍画直边三角形，并非对三角形内部每点执行非线性F；曲面效果需要足够细分。

当前资产z=0，输出仍位于该平面，本课也不进行光照；因此保留normal/uv/color字节。一般三维形变须用形变Jacobian的逆转置更新法线或从变形后几何重建；骨骼蒙皮另有权重、骨骼矩阵、切线与历史姿势需求，留H.2。拓扑变化才需要重新考虑IB；位置变化并不自动改变索引。

## 地址方程与写入集合

已有Vertex布局：position[3]偏移0/12B；normal[3]偏移12/12B；uv[2]偏移24/8B；color[4]偏移32/16B，总stride48B。

mesh0实测3顶点，有效顶点区144B。分配逻辑范围272B：64B左哨兵+144B顶点+64B右哨兵。哨兵初始化0xa5，不放入VB视图。CUDA基准数组只有静止顶点，不带哨兵。

第i个输出顶点地址B+64+48*i，位置写入集合为该地址起的12字节。不能按B+64+12*i计算，否则第二个线程会覆盖第一个顶点的normal。CUDA代码先用unsigned char*做字节寻址，再将顶点起点解释为float*。基地址/偏移/stride满足float对齐；一个线程写一个顶点，i>=count退出。kernel只赋q[0..2]，其余36B和哨兵不写。

源码：src/vertex_update.cu；CPU参考在interop_test.cpp中使用double算式构造预期顶点，并按字节比较整个272B快照，24帧共6528B。二进制可精确表示的输入使本实验逐字节相等；不能把这种严格阈值直接移植到任意三角函数/复杂蒙皮浮点实现。

## D3D12如何使用局部动态副本

```cpp
struct D3D12_VERTEX_BUFFER_VIEW {
    D3D12_GPU_VIRTUAL_ADDRESS BufferLocation;
    UINT SizeInBytes;
    UINT StrideInBytes;
};
void ID3D12GraphicsCommandList::IASetVertexBuffers(
    UINT StartSlot, UINT NumViews,
    const D3D12_VERTEX_BUFFER_VIEW* pViews);
void ID3D12GraphicsCommandList::DrawIndexedInstanced(
    UINT IndexCountPerInstance, UINT InstanceCount,
    UINT StartIndexLocation, INT BaseVertexLocation,
    UINT StartInstanceLocation);
```

动态VB视图BufferLocation=共享资源GPU地址+64，SizeInBytes=144，StrideInBytes=48。Size不是整个272B逻辑分配，更不是底层64KiB allocation。IASetVertexBuffers的StartSlot=0与input layout槽0对应；NumViews=1表示绑定一个视图；pViews指向上述视图描述，它不转移资源所有权。

DrawIndexedInstanced参数：IndexCountPerInstance是本mesh索引数；InstanceCount=1；StartIndexLocation是原始合并IB内的首索引；BaseVertexLocation加到每个索引上；StartInstanceLocation=0。本课按draw根常量选择实例，未改为硬件批量实例化。

原始索引值保持mesh局部编号。原始合并VB通过BaseVertex=mesh.firstVertex定位；动态副本从本mesh局部顶点0开始，故BaseVertex必须改成0，StartIndex仍不变。源代码raster.cpp每次draw都根据meshIndex选VB与BaseVertex，防止画完动态mesh后忘记恢复静态VB。

## 同步、状态和寿命

实例更新kernel→顶点更新kernel→CUDA signal ready，三者排在同一stream。D3D等待ready后才能同时读取实例表与动态VB。D3D画完并保存快照，恢复COMMON，再signal consumed。下帧CUDA先等consumed，才能覆盖这两块共享资源。一个Fence可以覆盖一组先前工作，不必为每个buffer单独建Fence，但必须让所有访问都落在约定边界内。

实例表走NON_PIXEL_SHADER_RESOURCE；动态VB走VERTEX_AND_CONSTANT_BUFFER。两者用途不同，不能因为CUDA写入就一律设置D3D UAV状态。本课没有D3D compute shader写入动态VB；CUDA使用外部设备指针。

动态VB的状态链为COMMON→VERTEX_AND_CONSTANT_BUFFER→COPY_SOURCE→COMMON。COPY_SOURCE仅服务诊断。原始VB/IB/纹理不导入CUDA；静态快照暂时转COPY_SOURCE后恢复原状态，不改变内容。

初始化写入动态缓存后显式完成一次CUDA初始化；帧循环中零CPU同步等待；结束排空后才能Map读回或释放。仍沿用E.1在飞行期异常直接终止教学进程的边界，生产设备重建未实现。E.2不是无限帧资源调度器。

## 如何证明没有“顺手改坏别的资源”

static_audit.cpp在运行前后真实读取原始GPU VB、IB、全部材质图像；纹理逐行取有效像素，不比较RowPitch空隙。另逐字段序列化CPU材质srv索引和factor，避免struct padding。两份快照总计424B，完全相等，并检查VB/IB/descriptor heap/每个图像资源对象身份没有换掉。

此资产图像资源为1×1白色fallback，材质资源验证覆盖本输入，而不是完整复杂PBR资产压力测试。snapshot内容包括实际GPU字节，不能仅靠“指针一样”证明内容一样。descriptor heap本课不重写；不声称做了不可用的descriptor原始字节读回。

正常测试：24帧、1920实例字段误差0，6528动态缓存字节无差异，1375616像素检查/68453覆盖/640边界像素排除，0错误。边界排除处理光栅量化/top-left与CPU实数重心的差别；排除数显式记录。

负对照e2-stale：第7帧顶点kernel安全地使用第6帧形变参数，实例和Fence仍按第7帧正常运行。第7帧捕获6个顶点字节差异及96个图像像素差异；其他帧和所有静态资源通过。它验证过期缓存检测有效，没有故意移除Fence制造未定义竞争，也不声称Debug Layer能覆盖所有跨API同步错误。Debug仍0，正说明“API使用合法”与“拿到正确帧内容”是两件事。

最终ready/consumed均24；Debug0；CUDA memcheck0错误/0泄漏；共享代码修改后E.1完整回归通过。新增CPU等待只在初始化/最后静态快照阶段，CPU中间等待仍0。

## 动手与直接答案

工作目录仓库根，运行`& learning/sandbox/d3d12/cuda-interop/verify_e2.ps1`，自动执行正常、过期帧和memcheck。结果进入results/e2。

1. 只改位置为何stride不是12？stride表示相邻完整顶点起点间距，现有AoS包含normal/uv/color，共48B；只有独立position流才可能12B。
2. 动态副本为何BaseVertex=0？视图已从这个mesh的局部顶点0开始，旧全局偏移会重复偏移。
3. Fence完成为何仍要内容代号/参考检查？Fence证明提交顺序，不证明producer用了正确帧参数或consumer选对缓存。e2-stale就是反例。

下一节E.3把写入/消费关系扩展到1/2/3槽位，固定工作量比较时间和重叠；不把CUDA硬件计数器权限问题当作跳过全部性能实验的理由。

资料：[D3D12_VERTEX_BUFFER_VIEW](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ns-d3d12-d3d12_vertex_buffer_view)、[DrawIndexedInstanced](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12graphicscommandlist-drawindexedinstanced)。
