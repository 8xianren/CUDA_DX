# D.4 解析器与渲染器边界整理

2026-10-21。D阶段收束；下一节PT.6：BSDF Sampling、NEE与MIS。

[代码目录/命令](../../sandbox/d3d12/gltf-scene/README.md) · [新边界测试](../../sandbox/d3d12/gltf-scene/src/scene_boundary_test.cpp) · [本节验收日志](../../sandbox/d3d12/gltf-scene/results/d04/summary.txt)

## D.3三题答案

1. firstIndex定位mesh在共享IB中的索引起点；读出的是mesh局部索引，还需加firstVertex定位共享VB。元素偏移与字节偏移分别处理。
2. sRGB解码D是非线性：sum(w*D(c))一般不等于D(sum(w*c))。黑白均值前者线性0.5，后者约0.214。
3. 若CPU导入层开始保留glTF原始UV，应去掉ClosestHit中用于恢复Assimp翻转的`uv.y=1-uv.y`，同时修改CPU参考与约定验证。

## 从实际变化推导边界

要支持三种独立变化：换文件格式/导入库；换GPU后端；每帧更新相机/节点而不重新读取资产。若glTF解析时直接创建D3D12 descriptor，解析器就依赖设备；若shader提交函数每次读aiMaterial，Importer寿命和渲染寿命就被绑在一起；若节点变换和ReadFile位于同一个编译单元，程序化场景也可能被迫携带导入符号。

因此选择自有CpuScene作为交接契约。契约不仅是几个struct名字，还包括数据含义、布局、所有权、有效引用、支持范围和失败行为。当前列向量矩阵按行保存；顶点48B、uint32局部索引；primitive映射CpuMesh；节点引用共享网格；图像保存编码流；UV沿用固定Assimp约定。PNG/JPEG解码由后端WIC实现，CPU场景本身不需要D3D12对象。

游戏开发类比：导入器像资产加工入口，自有CPU结构像统一资产描述，GPU资源工厂像把资产安排进当前设备，渲染命令像本帧执行清单。清单可以换相机/实例，不能每帧重新解析glTF来替代资源管理。

## 实际结构与依赖

```text
scene_import（Assimp适配） → scene_model（自有CPU节点运算）
scene_gpu（D3D12资源/AS） → scene_model
scene_render（材质准备/绑定/提交） → scene_gpu

文件驱动测试同时链接scene_import与scene_render。
程序化scene_boundary_test只链接scene_render，不链接scene_import/Assimp。
```

箭头表示编译/链接依赖，不是GPU执行顺序。逻辑上的资源工厂职责同时存在于gpu_upload.cpp与material_bindings.cpp；没有宣称四个CMake target与四个逻辑阶段严格一一对应。

本次修改：

- scene_model.cpp：从cpu_scene.cpp提取Multiply、TransformPoint、UpdateWorldMatrices；不依赖Assimp或D3D12。
- cpu_scene.cpp：保留ReadFile、节点复制、支持范围检查和自有场景组装。
- material_bindings.cpp：从D.3提交函数提取GPU mesh/material表与sampler heap准备。
- material_sampling.cpp：接收MaterialBindings，不再接收CpuScene；仍是同步诊断封装，内部负责资源绑定、Dispatch、Copy、提交、等待和读回。
- CMakeLists.txt：共享实现各编译一次为静态库；原测试名与调用命令保留。

静态库只是编译/链接组织，不是动态插件、跨编译器稳定ABI或安全隔离。CMake PRIVATE表示依赖实现细节不作为普通使用需求公开；静态库所需的链接依赖仍可传递到最终可执行文件，不能用PRIVATE“消除”Assimp。本课检查实际生成项目的AdditionalDependencies，确认新测试无Assimp/scene_import。

## 交接函数与所有权

`CpuScene LoadCpuScene(const std::string& path)`：同步读取文件并通过Assimp适配；path只在调用时借用，返回值持有vector/string/图像编码字节。Importer析构后无悬空aiScene指针。读文件失败标记[read]，适配失败标记[adapt]，局部CPU内存自动回收。注意它不自动调用C.6的原始Validator；标准资产测试入口仍先执行validate_import.cjs。

`void UpdateWorldMatrices(CpuScene& scene)`：原地更新world，要求父节点排在子节点之前；父引用非法或出现非有限矩阵抛错。不读取文件、不提交GPU。它不是事务更新：处理中途失败时不能承诺所有world仍是调用前状态。

`GpuScene UploadScene(UploadContext& context,const CpuScene& source)`：借用CPU源、创建GPU资源并录制复制/状态转换；返回GpuScene拥有Default资源、SRV heap和staging。返回并不表示复制已经执行完。源数据已写入staging后，GPU不再读取原始vector；staging仍必须活到复制Fence完成。当前为验收保留referenceVertices/Indices/Pixels，销毁源CpuScene不等于清空了所有CPU几何副本。

新增接口：

```cpp
struct MaterialBindings {
    ComPtr<ID3D12Resource> meshes, materials;
    ComPtr<ID3D12DescriptorHeap> samplers;
};
MaterialBindings PrepareMaterialBindings(
    UploadContext&, const CpuScene&, const GpuScene&);
```

context提供device；cpu提供材质语义；gpu提供mesh范围和该场景descriptor索引。返回对象拥有两张Upload表和sampler heap，不借用CPU数组。mesh记录16B，材质记录32B，保持D.3 HLSL布局。工厂只创建/Map表和写描述符，不录制GPU命令、不执行队列、不等待Fence。临时vector在返回前已复制进Upload资源，故可销毁；Upload资源本身必须覆盖GPU读取期。

bindings只适用于配套GpuScene。其textureIndex是场景局部编号，不能把A场景bindings与B场景纹理heap混用；当前未加入全局generation handle或自动配对检查。改变CPU因子也不会自动同步到旧表，必须重新准备/更新表，并处理旧版本的GPU寿命。

提交接口：

```cpp
std::vector<LinearRGBA> SampleHitMaterials(
    UploadContext&, const MaterialBindings&, const GpuScene&,
    const InstanceFrame&, const std::vector<MaterialRay>&,
    const std::filesystem::path& dxil);
```

context是录制/提交上下文；bindings是准备好的网格/材质表和sampler；gpu持有几何/纹理；frame持有对象表/TLAS；rays提供每条32B的origin/tmin/direction/tmax；dxil是shader文件，不是场景资产。返回每条16B float4的自有CPU结果。它不再读取CpuScene或Assimp，但仍加载shader/创建管线，尚未实现生产级管线缓存。

## 两种生命周期：C++作用域与GPU完成时间

ComPtr负责COM引用计数，vector负责CPU存储；二者都不知道GPU是否仍在执行。资源生命周期由“谁持有对象”与“GPU最后一次访问何时完成”共同决定。三种时刻不能混为一谈：资源对象已创建；使用该资源的命令已录制/提交；GPU已完成。

ResourceBarrier建立GPU端访问/状态依赖，并不使CPU阻塞；Fence用于知道队列到达某一点。当前单DIRECT队列，SubmitWait路径是Close→ExecuteCommandLists→queue.Signal→SetEventOnCompletion→WaitForSingleObject→allocator/list Reset。队列Signal发生在排在其前面的工作之后；CPU直接写Fence值不能替代它。

相关API：

```cpp
void ID3D12CommandQueue::ExecuteCommandLists(
    UINT NumCommandLists, ID3D12CommandList* const* ppCommandLists);
HRESULT ID3D12CommandQueue::Signal(ID3D12Fence* pFence, UINT64 Value);
HRESULT ID3D12Fence::SetEventOnCompletion(UINT64 Value, HANDLE hEvent);
```

列表必须Close后提交，数组描述本次列表集合；Execute不等待。Signal的pFence是目标Fence，Value是本应用递增里程碑，返回失败需处理。SetEventOnCompletion在达到Value时触发hEvent，本身不负责阻塞CPU；后续Win32等待才阻塞。当前等待30秒超时判失败，不继续读回或Reset；不能把现有异常退出视为完整设备恢复/可重试事务。

删除SubmitWait中的等待并不能自动得到正确异步版本。异步版本还必须保留SBT/临时表/descriptor heap/输出、记录最后使用Fence值、延迟回收，且不得过早Reset allocator。还需决定谁调用提交、哪个队列负责信号、如何回传完成状态。本课保留同步闭环，后续多帧/互操作性能阶段再扩展。

## 失败边界与修改传播

- 原始文件不符合规范：Validator报告；不能依赖Assimp接受与否判断规范合法性。
- 格式正确但动画/Morph等超出范围：能力层拒绝；GPU层不应悄悄绘制静态替代。
- CPU材质数不匹配/非法sampler/非UV0：PrepareMaterialBindings抛错；它未录制GPU命令，局部COM对象可正常清理。非法sampler分支本机已测。
- GPU上传/构建已录制后失败：必须另考虑命令列表中的资源引用；局部变量自动析构不构成安全重试保证。本课没有引入通用回滚/恢复系统。

变更传播：相机变化不重新导入；节点local变化需更新world、对象表/TLAS，静态VB/IB通常复用；基础色factor变化需更新材质表，不需要重建BLAS；顶点位置变化涉及VB与BLAS，之后TLAS如何更新取决于AS策略；更换解析库主要调整到CpuScene的适配层，但UV/坐标等语义契约必须保持或显式版本迁移。

## 本机验收

scene_boundary_test程序生成无纹理三角形，因子(.2,.4,.6,1)，使用白色fallback。步骤：UploadScene/BLAS→Fence1完成→准备bindings→录制TLAS→显式`cpu=CpuScene{}`→一条射线Dispatch→Fence2完成→读回。

RTX5070实际结果：RGBA=(0.2,0.4,0.6,1)，最大误差0，Fence2/2，Debug/GPU Validation warning/error0；非法wrap拒绝成功。链接依赖中无Assimp和scene_import。仅证明源CpuScene可在准备后销毁，不声称所有CPU参考副本已移除，也不证明任意跨场景错配都能自动发现。

受影响回归：C.3五组、C.4四组、C.5六项按预期通过；C.6底层11项及组合入口8项按预期通过。D.1三组PASS（原textured输入仍有两条已有Validator warning）；D.2四阶段229376像素mismatch0；D.3十二组41664数值样本PASS，最大绝对差0.00562435，官方正面16384像素RGB码值≤1。GPU Debug warning/error均0。结果未改变，不把重构宣称为性能提升。

## 动手

从仓库根依次执行：

```powershell
& learning/sandbox/d3d12/gltf-scene/build_importer.ps1 -Lesson d04
& learning/sandbox/d3d12/gltf-scene/verify_boundaries.ps1
```

沿用已有VS2022/CMake/DXC/Node Validator/Python Pillow依赖。本目标没有CUDA kernel，CUDA后续仍sm_120。新边界日志、构建日志、实际链接依赖、回归控制台日志在results/d04；被调用课程脚本的原始图像/CSV仍写各课results，不移动旧资料。

练习：在scene_boundary_test中修改baseColor并重跑，预测float4；再思考修改CPU因子发生在Prepare之前与之后有何区别。自测：UploadScene返回能否立即释放staging？ComPtr能否替代Fence？替换glTF导入库时哪些语义必须保持？

商业引擎常把导入/cooking与运行时资产分开，采用缓存、任务系统和异步资源退役。本课仍运行时读glTF、使用少量同步函数和公开struct；底层交接原则一致，但尚无完整资产系统、抽象GPU接口、热重载或设备恢复。D阶段完成的是资产到DXR的可验证基础；下一节PT.6接BSDF Sampling/NEE/MIS，不把基础色诊断称为路径追踪成品。

参考：[CMake target_link_libraries](https://cmake.org/cmake/help/latest/command/target_link_libraries.html)、[D3D12资源屏障](https://learn.microsoft.com/en-us/windows/win32/direct3d12/using-resource-barriers-to-synchronize-resource-states-in-direct3d-12)、[Fence资源管理](https://learn.microsoft.com/en-us/windows/win32/direct3d12/fence-based-resource-management)。
