# C.1 glTF对象模型与渲染数据对应

2026-10-16。一节完整讲完C.1，不合并C.2–4，不再拆子课。目标：读懂对象之间的引用，知道数据定义与场景实例不同，并能沿POSITION链找到字节所属位置。[代码与资产](../../sandbox/d3d12/gltf-scene/README.md)。

## 核心对象

|对象|职责|后续渲染对应|
|---|---|---|
|asset|版本、生成器等文件元信息|导入入口检查，不是场景节点|
|scene|一组根节点|选定场景的遍历入口|
|node|层级、局部变换，可引用mesh或camera等|场景实例/变换；也可以只是分组|
|mesh|可被多个node共享的几何定义，包含primitives|CPU几何资产；潜在可共享GPU几何|
|primitive|一组属性、可选索引、拓扑与可选材质|类似submesh/section；一般作为绘制或BLAS geometry组织单位|
|accessor|数据元素的类型、数量与访问描述|解码得到顶点属性或索引等|
|bufferView|buffer中的一段字节区域|文件数据切片，不是D3D12 SRV|
|buffer|原始二进制数据来源和长度|CPU字节来源，不等于GPU buffer|
|material|表面参数和纹理引用|材质表/着色参数|
|texture|图片来源与采样设置的关联|纹理资源与采样配置的组合|
|image|PNG/JPEG等图像来源|解码后的像素，后续上传|
|sampler|过滤/寻址设置|GPU采样器设置|
|camera|透视/正交投影参数|场景相机；姿态来自引用它的node|

顶层对象大多放在数组中，数值引用是相应数组的零基索引。node.mesh=0表示meshes[0]，不是指针、GPU地址或节点编号。name供阅读，不应作为必然存在且唯一的标识。primitive是某个mesh内部的数组元素，primitive[0]必须结合mesh理解。顶层scene是默认场景索引，scenes是场景数组；scene可省略，不能普遍假设0就是文件声明的默认值。本课明确写了scene=0。

## 为什么node与mesh分开

同一个模型在两个位置出现，几何不必重复。mesh描述“是什么形状”，node描述“在层级哪里、如何放置”。本课nodes[1]和nodes[2]都引用mesh0，只有translation不同。Group节点只有children，不绘制几何；View节点引用camera0，不代表另一个mesh。

```text
scene[0]
├─ node[0] Group
│  ├─ node[1] Left  ─┐
│  └─ node[2] Right ─┴─ mesh[0]
│                        ├─ primitive[0] → material[0] Red
│                        └─ primitive[1] → material[1] Blue
└─ node[3] View → camera[0]
```

一个primitive可以包含许多三角形，不等于“一个三角形”。本fixture每个primitive恰好只有一个三角形，是为了用两种材质表达一个方形的两个部分。material引用位于primitive；本课两个节点引用同一个mesh，因此使用相同材质定义。不能随意在node上杜撰material覆盖字段。

往D阶段映射时，可选择一个mesh建一个包含两个geometry的BLAS，再用两个TLAS instance引用它；这是渲染器组织策略，不是glTF规范强制要求。光栅路径朴素展开有2节点*2primitive=4个绘制项，实际draw次数仍可能因实例化/合批改变。

## 沿属性引用找到字节

```text
meshes[0].primitives[0].attributes.POSITION = 0
→ accessors[0]：VEC3、componentType=5126、count=4
→ bufferViews[0]：buffer=0、byteOffset=0、byteLength=48
→ buffers[0]：uri=c01-shared-mesh.bin、byteLength=60
→ 文件字节
```

POSITION赋予数据“顶点位置”语义；accessor描述4个由float32组成的三分量元素；bufferView定位字节区域；buffer定位字节来源。只有bufferView不知道数据是位置、颜色还是别的内容。accessor的count是元素数量，不是字节数：本例4*3*4=48B。

两个primitive都引用同一个POSITION accessor0，共享4个位置。它们的indices分别引用accessor1和2，都是3个uint16标量，指向相同index bufferView的不同范围。C.1只读引用与元数据，不解码这些字节；offset/stride/normalized等规则在C.3集中讲，不在此继续拆子课。普通accessor链足以解释本fixture，稀疏等特殊情况不是本节支持范围。

## 材质与纹理只先建立关系

可选纹理链是material某个纹理槽→textures[index]→image来源及sampler设置。image不是texture，sampler不含图片像素；同一image可关联不同采样设置。纹理槽还决定数据解释，不能只看PNG后缀就决定sRGB；C.5讲材质语义、D.3验证GPU色彩空间。

本fixture只有颜色因子，没有图片，避免在C.1引入无关图像加载。camera只提供投影参数，node负责场景中的姿态；本课不自动替换R.13的相机，也不计算节点World Matrix。矩阵/坐标对接留C.4/D.2。

## 本机实验

`inspect_scene.ps1`使用Get-Content -Raw与ConvertFrom-Json构建内存对象，Ref函数检查本fixture引用的非负整数/数组范围，Visit从所选scene根节点遍历children，打印mesh/primitive/材质及accessor链。对象内存由PowerShell管理，无GPU资源所有权或Fence。0是合法索引，脚本使用null判断字段是否存在，不能用if(index)误判0。

本课用PowerShell是为了直接检查JSON对象关系，不是以脚本替代渲染器；没有Python，没有手写JSON解析器，没有CUDA kernel。后续正式加载器与GPU接入按C/D推进。

仓库根目录运行：

```powershell
& learning/sandbox/d3d12/gltf-scene/inspect_scene.ps1
```

2026-10-16实际输出：

```text
definitions: mesh=1 primitive=2 material=2 accessor=3 bufferView=2 buffer=1
selected scene: nodes=4 meshInstances=2 primitiveInstances=4 cameras=1
binary bytes=60; GPU allocations=0; vertex decoding=not performed
C.1 object graph PASS
```

脚本读取真实.gltf并检查配套.bin长60B。该PASS只证明当前fixture引用遍历与预期统计通过，不代表完整glTF规范校验、顶点解码或GPU渲染通过。[结果日志](../../sandbox/d3d12/gltf-scene/results/c01/object_graph.txt)。

## 自测与后续

1. 再添加一个node引用mesh0，mesh定义数、mesh实例数和primitive实例数分别是多少？
2. 为什么bufferView已经指出字节位置，还需要accessor？
3. node.mesh=0、primitive.material=0、attributes.POSITION=0这三个0指向同一个对象吗？

下一节C.2只讲.gltf/.glb容器与外部数据来源，保持原有编号。当前C.1已完成，C.2–C.6和D阶段尚未授课。

资料：[Khronos对象与场景](https://github.khronos.org/glTF-Tutorials/gltfTutorial/gltfTutorial_004_ScenesNodes.html)、[二进制引用链](https://github.khronos.org/glTF-Tutorials/gltfTutorial/gltfTutorial_005_BuffersBufferViewsAccessors.html)、[mesh/primitive](https://github.khronos.org/glTF-Tutorials/gltfTutorial/gltfTutorial_009_Meshes.html)、[glTF规范](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html)。
