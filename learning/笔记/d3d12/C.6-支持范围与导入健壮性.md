# C.6 支持范围与导入健壮性

2026-10-20。C阶段收束，一个完整课节。[共享代码入口](../../sandbox/d3d12/gltf-scene/README.md)。目标：分清格式合法性、库解码能力、适配能力和GPU着色能力；不把ReadFile成功当成完整资产支持。

## 三道关与失败语义

第一关：Khronos glTF Validator校验原始gltf/glb和关联资源。使用成熟库，不手写JSON/GLB解析。第二关：课程能力策略，当前只接收无扩展的静态核心glTF；即使Validator认识扩展也不代表我们的渲染器支持。第三关：Assimp读取、C++适配，检查引用、索引、属性、材质因子和自有资源约束。

文件正确仍可能超出课程范围；一个材质参数成功导入也不表示已经实现着色。Skin需要骨骼和权重，Animation需要按时间求值，Morph需要顶点差量，不能丢掉后宣称模型完整加载。Draco/Meshopt是压缩扩展，KTX2是图像容器，常通过扩展接入；当前入口拒绝所有扩展，是保守的课程范围策略，不是说这些格式不合法。

正常返回代表CPU导入完成，不代表像素解码、完整PBR、MASK/BLEND、法线贴图或GPU同步已完成。CpuScene.diagnostics保留能力提示。资产相机投影和灯光暂不接入，节点变换保留，提示使用显式配置的渲染器相机/光源。

本节选择遇到动画/骨骼/Morph即整次拒绝，而不是自动跳过部分网格。原计划“继续处理可绘制部分”需要定义被删节点、材质引用和缺失语义的处理，当前不伪装已经实现。未来可增加显式预览/降级模式，但必须向用户展示丢弃项。

## 新入口

validation/package.json固定gltf-validator 2.0.0-dev.3.10，package-lock.json固定依赖与完整性值；node_modules忽略，不全局安装。Node只运行官方校验包，几何/材质/资源适配仍在C++；没有新Python依赖。[官方Validator](https://github.com/KhronosGroup/glTF-Validator)。

validate_import.cjs调用`validateBytes(Uint8Array, options)`，异步返回JSON报告。uri是资源显示名称，externalResourceFunction以模型目录读取相对URI，maxIssues限制报告数，UNSUPPORTED_EXTENSION升级为错误。不忽略校验错误；报告截断也拒绝。通过后检查report.info的extensionsUsed、hasSkins、hasMorphTargets、animationCount，再启动C++探针。校验只读取本机资源，不上传资产。

```powershell
# 工作目录：仓库根。首次安装固定依赖；验证脚本也会在缺少包时执行npm ci。
npm ci --prefix learning/sandbox/d3d12/gltf-scene/validation --ignore-scripts --no-audit --no-fund
& learning/sandbox/d3d12/gltf-scene/build_importer.ps1 -Lesson c06
& learning/sandbox/d3d12/gltf-scene/verify_scope.ps1
& learning/sandbox/d3d12/gltf-scene/verify_validation.ps1
```

verify_scope先生成异常样本，verify_validation使用这些样本和C.2历史GLB。新工作副本若缺C.2等价GLB，先运行verify_importer.ps1。上游BoxTextured.glb来自固定Assimp源码包，引用而不复制。一般资产入口为：

```powershell
node learning/sandbox/d3d12/gltf-scene/validation/validate_import.cjs <输入.gltf或.glb> <报告.json>
```

LoadCpuScene本身仍可直接调用，**不会自动运行Node校验器**。这种底层调用只能保证自身检查；对外资产验收要使用带校验入口。当前也不是不可信文件的安全沙箱。

## C++能力检查与资源生命周期

CopyCpuMeshes拒绝HasBones或mNumAnimMeshes，带网格编号；LoadCpuScene拒绝动画和无实例场景。遍历深度限制128层，仅保护适配递归，不能保护此前的Assimp内部解析。图像编码流单份上限64MiB，仅限适配阶段，不等于像素解码后的内存上限。有限数检查不等于范围正确，baseColor/metallic/roughness/occlusionStrength另验[0,1]，不静默clamp错误输入。

read与adapt错误附上阶段和模型路径。读取失败不解引用空场景；适配异常时局部vector及Importer经RAII释放，外部拿不到部分场景。验收检查正常exit=1和错误文本，崩溃/超时不能算“正确拒绝”。以后GPU资源在CPU结果成功后创建；当前无GPU对象/Fence。

## 实测及原有假设的修正

底层探针11项：正常样例/带相机样例接受；错误JSON、越界accessor、未知componentType拒绝于read阶段；Morph、Animation、越界材质因子、过深层级拒绝；另两项边界探测发现未对齐accessor和未知必需扩展在当前Assimp路径被接受。这两项不是资产合法性PASS，说明解码后数据不能恢复所有源格式约束。

带校验入口8项按预期通过：

- 核心glTF与上游带纹理GLB：接受。
- 未对齐accessor：3个错误，含ACCESSOR_OFFSET_ALIGNMENT、ACCESSOR_TOTAL_OFFSET_ALIGNMENT、MESH_PRIMITIVE_ACCESSOR_UNALIGNED。
- 未知必需扩展：按UNSUPPORTED_EXTENSION升级规则拒绝。
- Validator认识的KHR_materials_unlit：规范校验通过，但课程scope拒绝。
- 合法动画与Morph样例：scope拒绝。
- C.2导出的GLB：带KHR_materials_volume、FB_ngon_encoding，后者不被该Validator支持，保守策略拒绝。**不等于GLB损坏，也不推翻此前几何回环通过**；此前测试验证的是另一层。

结果在results/c06/summary.txt（底层观察）、pipeline-summary.txt（带校验入口）及各report.json。骨骼拒绝分支已实现但本次没有独立骨骼样本验收；不把它混入已实测列表。C.3五项、C.4四项、C.5六项全部回归通过。

自测：①Validator通过为什么仍可能拒绝导入？②ReadFile接受未对齐数据是否意味着该文件合法？③为什么当前对动画整次拒绝，而不是悄悄取静态姿势？C阶段已完成教学与所列验收，下一节D.1 CPU数据到GPU资源；直接加载任意复杂资产、完整安全边界和GPU材质能力仍不是已完成事项。

## 课后补充：Cooking、DMA与直接加载GPU数据

2026-10-20，学习者提出：“现代引擎能否通过DMA直接得到GPU数据？这样CPU如何先拿到自己需要的数据？”此处保存关键解释，D.1课堂必须结合上传流程再次说明，不仅放在笔记中。

DMA是硬件数据搬运机制，CPU设置请求，不必逐字节执行复制；它不自动理解glTF语义，也不替代格式转换、GPU资源创建和同步。普通D3D12上传同样可以由CPU录制命令、GPU执行复制。DirectStorage进一步提供高吞吐资产加载和适用格式的GPU解压路径；不能因此断言所有平台都绕过系统内存，其实现可能包含中转缓冲区。[微软开发指南](https://github.com/microsoft/DirectStorage/blob/main/Docs/DeveloperGuidance.md)。

当前课程在运行时解析原始glTF并构造CPU数据。另一种方案是在离线导入/构建时提前完成解析、校验与目标格式转换，运行时加载加工后的资源。UE将内容转换成目标平台格式的过程称为Cooking；Cooking本身不代表启用了DirectStorage，UE是否使用后者需按具体版本、平台与资源路径核实。[UE Cooking文档](https://dev.epicgames.com/documentation/unreal-engine/cooking-content-in-unreal-engine?lang=en-US)。

可将加工后的资产组织为两类数据：

| 数据 | 运行时用途与安排 |
|---|---|
| 顶点数量、步长、索引格式、纹理尺寸/格式、文件块位置 | CPU先读取的元数据，用于资源分配和加载调度 |
| 包围盒、材质引用、节点关系、碰撞数据 | 为CPU剔除、对象管理、物理等保留所需表示 |
| 顶点/索引主体、纹理数据块 | 按GPU所需布局预加工后，走传输及必要的解压路径 |

例如十万个32B顶点需要3200000B缓冲区，CPU只需先知道数量与步长，就能分配空间，不必先逐个读取顶点。包围盒也可离线计算后单独保存。微软BulkLoadDemo明确建议集中纹理元数据，使资源/描述符分配不依赖先读完整模型。[官方示例](https://github.com/microsoft/DirectStorage/blob/main/Samples/BulkLoadDemo/README.md)。

如果CPU确实需要逐顶点计算或修改，不能靠元数据代替完整数据：可保留CPU副本（增加内存）、构建专用碰撞或简化几何（不一定与渲染表示相同）、将合适计算迁移到GPU，或按需读回并等待完成。GPU解压后立即全量读回、CPU处理再上传，会增加往返传输与同步，可能抵消收益。因此直接GPU加载适合已经加工好、无需CPU再次逐项检查或改写的数据块，不能消除真实存在的CPU依赖。

D.1仍实现基础上传流程，以掌握资源分配、布局、状态与生命周期；需在课堂中对照上述替代路径，不增加独立子课。本补充仅记录机制和后续讲解要求，没有实现或测试DirectStorage。
