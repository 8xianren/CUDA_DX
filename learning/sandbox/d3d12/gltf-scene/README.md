# glTF 场景输入共享主线（C.1–C.6、D.1 完成）

按C.1–C.6、D.1–D.4原有小节推进，不合并或另拆子课。本目录为后续解析/渲染接入保留共享资产；C.1仅对象关系探针，尚无通用解析器、GPU上传或渲染接入。

2026-10-16 已接入 Assimp 6.0.2，并完成 glTF/GLB、OBJ、FBX CPU 导入探针测试。C.2 容器与加载流程已于 2026-10-16 授课完成；C.3 再将库解码结果转换为自有 CPU 网格，不手写格式解析器。具体格式与功能支持以固定库版本及本机样本验证为准。

## Assimp 构建与验证

从仓库根目录执行（脚本使用自身目录定位，也可从其他工作目录调用）：

```powershell
& learning/sandbox/d3d12/gltf-scene/build_importer.ps1
& learning/sandbox/d3d12/gltf-scene/verify_importer.ps1
```

需要 CMake 3.24+、VS2022 C++ x64 工具和首次下载所需网络。纯 CPU 库通过 CMake 构建，不调用 nvcc；后续 CUDA 程序仍使用公共 build.ps1/sm_120。依赖固定为提交 `fb375dd8c0a032106a2122815fb18dffe0283721`，下载包 SHA256 写在 CMakeLists.txt。源码及静态库全部放在被忽略的 build/ 内，无需全局安装。启用 glTF、FBX、OBJ、COLLADA、PLY、STL 导入器；后三种本次未验收。上游 LICENSE 保存在 build/_deps/assimp-src/LICENSE。

- CMakeLists.txt：固定依赖、启用格式、链接 CPU 探针。
- src/import_probe.cpp：ReadFile、节点/网格/基础颜色摘要、三角形与索引检查；Importer 持有场景所有权。
- build_importer.ps1：配置与编译，日志写 results/c02/。
- verify_importer.ps1：固定几何答案、GLB 回环、OBJ 三角化、上游 FBX 样本及失败路径验证。
- results/c02/：输入变体、逐项日志、构建日志与 summary.txt。

实测：两个 glTF primitive 导入为两个 aiMesh，Left/Right 均引用 mesh 0/1；共两个网格定义、四次网格引用、两个定义三角形。位置/索引/红蓝基础颜色符合已知答案。GLB 回环保持这些数据和节点局部变换，但 **6.0.2 GLB 导出器丢失相机对象（1→0）**，View 节点仍在；不声称完整场景无损。OBJ 四边形得到两个三角形。FBX 使用同一固定源码包的 test/models/FBX/box.fbx，得到一个网格、一个实例、十二个三角形，不复制第三方资产。错误 magic、截断、错误 chunk 长度、缺失外部 buffer 均返回 exit=1 与 IMPORT_ERROR。

这只是 CPU 导入接入，尚未创建自有渲染场景、上传 GPU 或验证完整 PBR/纹理/动画功能。[接入记录](../../../笔记/d3d12/C.2-Assimp接入测试记录.md)。

|文件|职责|
|---|---|
|assets/c01-shared-mesh.gltf|自编最小资产：分组节点下两个mesh实例，共享两个primitive；另一个camera节点|
|assets/c01-shared-mesh.bin|60字节小端几何：4个float3位置，uint16索引0,1,2,0,2,3|
|inspect_scene.ps1|使用现成JSON读取器，遍历引用关系、检查本课fixture计数与binary长度|
|results/c01/object_graph.txt|本机实际对象引用与计数日志|

仓库根目录运行：

```powershell
& learning/sandbox/d3d12/gltf-scene/inspect_scene.ps1
```

输入与输出从脚本目录定位，不依赖当前工作目录。无需编译器/GPU；没有Python或手写JSON词法解析。脚本只支持本课固定fixture（显式默认scene、三角形、显式材质/索引/普通accessor引用）；不是任意glTF的规范校验器。坏引用/缺失配套文件/计数不符抛错，成功输出PASS并保存日志。C.2之后再推进正式加载层，C.3解码accessor，D阶段创建GPU资源。

2026-10-16实测PASS：定义mesh1/primitive2/material2/accessor3/bufferView2/buffer1；当前场景node4、mesh实例2、primitive实例4、camera节点1；binary60B。没有解码顶点或计算World Matrix，不声称资产通过完整Khronos validator。

配套binary布局：offset0开始的float3依次(-.5,-.5,0)、(.5,-.5,0)、(.5,.5,0)、(-.5,.5,0)，占48B；offset48开始6个uint16索引占12B。两个索引accessor共享第二个bufferView，局部offset分别0和6。

[C.1讲义](../../../笔记/d3d12/C.1-glTF对象模型与渲染数据对应.md)

[C.2 容器与加载讲义](../../../笔记/d3d12/C.2-glTF与GLB容器和Assimp加载.md)

## C.3 布局与自有 CPU 网格

新增 src/cpu_mesh.h/.cpp：48B Vertex 与 uint32 索引的深拷贝适配；src/mesh_layout_test.cpp：Importer 析构后校验已知答案；verify_layout.ps1：生成固定交错资产并验证，不解析任意资产。

仓库根目录执行：

```powershell
& learning/sandbox/d3d12/gltf-scene/build_importer.ps1 -Lesson c03
& learning/sandbox/d3d12/gltf-scene/verify_layout.ps1
```

2026-10-16：uint8/16/32、无索引、缺属性5项PASS；源stride40、偏移16+属性偏移、UNORM8、Assimp UV翻转均覆盖。产物及日志在results/c03；没有GPU上传，未处理节点/材质资源。缺法线/UV以零占位并设false标志，缺颜色以白色占位。UV保留Assimp约定，不再次翻转。

[C.3讲义](../../../笔记/d3d12/C.3-accessor布局与自有CPU网格.md)
## C.4 节点层级与共享网格

src/cpu_scene.h/.cpp：自有节点、共享网格引用、world更新；src/assimp_mesh_copy.h复用C.3网格复制，避免重复导入。src/scene_hierarchy_test.cpp对独立标量参考验证；verify_hierarchy.ps1生成TRS/matrix/strip/fan四组资产。日志与样例直接在results/c04。

仓库根执行：
```powershell
& learning/sandbox/d3d12/gltf-scene/build_importer.ps1 -Lesson c04
& learning/sandbox/d3d12/gltf-scene/verify_hierarchy.ps1
```

2026-10-19：四组PASS；TRS最大位置误差4.76837e-7，matrix误差0；改父平移后两子同步移动，网格2/实例引用4且局部顶点不变。Strip/Fan转换后各2三角形、正绕序、面积1。C.3五组回归PASS。CPU列向量数学/按行内存，不自动转换UE轴约定；尚无GPU资源、材质资源或相机投影接入。

[C.4讲义](../../../笔记/d3d12/C.4-共享网格与节点世界变换.md)

2026-10-19 课堂补充已写入 C.4 讲义：重新挂接保持 world 的逆矩阵推导、非均匀缩放与旋转产生剪切、单个 TRS 的表达限制。当前 Matrix4 保留完整矩阵；尚未实现重挂 API 或剪切专项测试，不将文档推导列为已实测功能。

## C.5 材质、纹理与颜色空间

src/cpu_material.h/.cpp负责复制因子、纹理槽、采样器、图像编码流；CpuScene现在持有MaterialAssets。src/material_test.cpp验证Importer析构后的结果；verify_material.ps1复用C.3几何生成固定材质资产。全部新结果在results/c05。

仓库根执行：
```powershell
& learning/sandbox/d3d12/gltf-scene/build_importer.ps1 -Lesson c05
& learning/sandbox/d3d12/gltf-scene/verify_material.ps1
```

2026-10-19：默认材质、OPAQUE/MASK/BLEND、内嵌PNG、缺失图片六项按预期通过；五槽共享一份131B图像编码流，采样器/颜色空间/normalScale/occlusionStrength正确。C.4四组回归通过。当前只支持UV0与核心glTF材质，拒绝纹理变换；尚未解码像素、创建GPU纹理或验证材质成像。无纹理与引用文件缺失严格区分。

## C.6 支持范围与导入健壮性

`validation/validate_import.cjs` 使用固定的 Khronos `gltf-validator` 2.0.0-dev.3.10 校验原始 glTF/GLB，然后检查课程支持范围，再启动 `src/import_scope_test.cpp` 调用 C++ 适配器。`validation/package-lock.json` 固定安装依赖，node_modules 不入库。Node只运行成熟校验库；数据适配仍是C++。

工作目录为仓库根，每步成功后执行下一步：

```powershell
& learning/sandbox/d3d12/gltf-scene/build_importer.ps1 -Lesson c06
& learning/sandbox/d3d12/gltf-scene/verify_scope.ps1
& learning/sandbox/d3d12/gltf-scene/verify_validation.ps1
```

首次验证缺少Node依赖时脚本执行npm ci。新工作副本若没有C.2等价GLB，先执行本目录 `verify_importer.ps1`。独立资产入口：

```powershell
node learning/sandbox/d3d12/gltf-scene/validation/validate_import.cjs <输入.gltf或.glb> <报告.json>
```

2026-10-20：底层11项边界探测、带校验入口8项按预期完成，C.3–C.5共15项回归通过。日志/JSON报告均在 `results/c06/`。底层Assimp接受未对齐与未知必需扩展，因此不把ReadFile成功视为规范校验。C.2导出GLB含额外扩展，被当前保守策略拒绝，不代表GLB损坏；上游核心带纹理GLB通过组合入口。

当前拒绝扩展、动画、蒙皮、Morph；适配阶段限制节点深度128和单图像编码流64MiB，整次失败不返回部分场景。骨骼拒绝分支尚未独立实测。直接 `LoadCpuScene` 不自动运行Validator；这也不是不可信文件安全沙箱。CPU结果拥有自有内存，但不代表像素解码、GPU上传或材质着色已完成。

讲义：[C.6 支持范围与导入健壮性](../../../笔记/d3d12/C.6-支持范围与导入健壮性.md)。下一节D.1。

[C.5讲义](../../../笔记/d3d12/C.5-材质纹理与颜色空间.md)

## D.1 CPU数据到GPU资源

`src/gpu_upload.h/.cpp`：Default/Upload/Readback资源、WIC解码、逐行纹理上传、材质descriptor映射、读回对照与BLAS构建检查。`src/upload_preview.cpp`与`shaders/upload_preview.hlsl`：局部xy基础色预览；`verify_upload.ps1`：三种固定样例、C.6校验、GPU读回和双材质颜色锚点。

从仓库根运行：

```powershell
& learning/sandbox/d3d12/gltf-scene/build_importer.ps1 -Lesson d01
& learning/sandbox/d3d12/gltf-scene/verify_upload.ps1
```

首次需按C.6安装validation目录的npm依赖，VS2022/Windows SDK包含WIC与D3D12；本节没有CUDA kernel。结果全部在 `results/d01/`。2026-10-20 RTX5070三项通过：buffer/texture逐字节读回、1/1/2个BLAS构建、光栅预览；multi颜色锚点≤1码，每项Fence2/2，Debug/GPU Validation warning/error0。textured输入Validator有2项已有warning，见报告。

当前只有mip0和point/clamp基础色诊断；无节点world/TLAS/射线发射/完整PBR。图像没有曝光和色调映射，不能冒充PT显示。两次CPU Fence等待服务验收，尚无异步退役池。BLAS为临时构建检查，D.2接入持久实例资源。[D.1讲义](../../../笔记/d3d12/D.1-CPU数据到GPU资源与上传生命周期.md)。
