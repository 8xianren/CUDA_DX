# C.5 材质、纹理与颜色空间

2026-10-19。本节一个完整授课单位；重点为资源到渲染数据，不实现完整PBR着色器。[代码目录](../../sandbox/d3d12/gltf-scene/README.md)。

## 从表面参数到资源引用

网格只给出几何属性，材质描述表面如何响应光。常量因子表达整块表面的统一参数，纹理用UV查询随位置变化的值。逻辑链为primitive.material→material纹理槽→texture→image+sampler；图像提供数据，采样器决定越界寻址和过滤。UV位于网格而非图像中。相同image可以由不同texture/sampler或不同材质用途引用，因此颜色空间记录在绑定用途，不能只给文件名一个全局sRGB标记。

核心glTF metallic-roughness参数：baseColorFactor默认(1,1,1,1)，metallicFactor=1，roughnessFactor=1，emissiveFactor=(0,0,0)，alphaMode=OPAQUE，alphaCutoff=.5，doubleSided=false，normalScale=1，occlusionStrength=1。默认金属度是1不是0；本课旧红蓝材质显式设0。无纹理保留因子默认；有引用但文件丢失属于加载错误。

计算约定：baseColorRGB=线性factor×sRGB解码后的纹理RGB×线性顶点颜色；alpha由对应alpha相乘，不作sRGB解码。metallic=factor×MR纹理B，roughness=factor×MR纹理G，两者线性读取。emissive=factor×sRGB解码后的emissiveRGB。Occlusion取R并以strength在1和采样值之间插值，用于约定的间接光遮蔽，不盲目乘所有直接光。法线图线性采样、RGB映射到[-1,1]，scale作用于切线空间XY，归一化后经TBN转空间；需要法线、切线和正确UV方向，当前未生成切线或执行法线贴图着色。依据：[glTF规范](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#materials)。

纹理颜色空间表：baseColor/emissive的RGB为sRGB，alpha线性；MR/normal/occlusion线性。材质常量因子和顶点颜色按线性处理，不因“颜色”二字再次解码。sRGB c=.5解码约.214041，若再乘线性factor .8得到.171233；直接乘得到.4是不相同的输入语义。输入纹理解码不等于显示变换：光照结果在线性HDR中累积，输出再执行曝光、色调映射、sRGB编码。

OPAQUE忽略覆盖alpha；MASK当最终alpha<cutoff丢弃，等于阈值保留；BLEND表示透明混合需求，读取枚举不代表已经实现排序/透射。doubleSided表示双面渲染与相应背面法线处理，不表示发光，也不等于只改一个剔除开关即可完成所有着色。

## 自有结构、API与所有权

cpu_material.h的CpuMaterial保存因子与5个TextureBinding，后者保存image索引、UV通道、RGB颜色空间、wrapU/V、min/magFilter。CpuImage保存图像来源和encodedBytes（PNG/JPEG编码流，不是解码RGBA）。相同库图像引用去重；无纹理image=-1。materialIndex继续对应库材质数组顺序，不能假定库材质数量等于源JSON数量，库可能追加默认材质。

CopyMaterialAssets(const aiScene&, const std::string& modelPath)在Importer有效期间复制。aiMaterial::Get通过属性键读取常量，失败保持已初始化默认值。GetTexture原型：

```cpp
aiReturn GetTexture(aiTextureType type, unsigned int index,
    aiString* path, aiTextureMapping* mapping = nullptr,
    unsigned int* uvindex = nullptr, ai_real* blend = nullptr,
    aiTextureOp* op = nullptr, aiTextureMapMode* mapmode = nullptr) const;
```

type选择BASE_COLOR/METALNESS/NORMALS/LIGHTMAP/EMISSIVE；index=0取该用途第一层；path输出外部路径或内嵌引用，mapping输出映射方式，uvindex输出UV通道，blend/op为库的通用纹理层参数（本课传空），mapmode使用预留三个轴的数组接收寻址模式。本课只支持UV0；额外UV或纹理变换扩展明确报错，不静默忽略。MR在本版本以METALNESS绑定取得，通道解释仍为G粗糙度/B金属度。

scene.GetEmbeddedTexture检查是否内嵌；mHeight==0时mWidth是编码字节数量，不是像素宽度，必须深拷贝pcData。外部路径以模型目录解析并读取编码字节，无法打开就报错。无压缩的内嵌像素暂不支持。函数返回后全部因子、字符串和字节属于自有vector，Importer析构不影响它们。读取同步执行，无GPU上传/状态/Fence。

Assimp6.0.2源码将occlusion strength写为$tex.file.strength，而头文件宏为$tex.strength；适配先读宏，失败后读固定版本实际键，并用.4样本验证。对外保持occlusionStrength字段，不让这个库差异传播到渲染器。

sampler wrap对应REPEAT10497/CLAMP_TO_EDGE33071/MIRRORED_REPEAT33648。min/mag缺省以0保留“未指定”，不编造固定源默认；D阶段选定渲染器策略。测试使用min=9987（线性mip间及层内过滤）、mag=9729（线性）。本节记录参数，不声称完成过滤。沿用C.3的Assimp UV约定，不再次翻转；图像方向在D.3验证。

## 验证与范围

仓库根执行：

```powershell
& learning/sandbox/d3d12/gltf-scene/build_importer.ps1 -Lesson c05
& learning/sandbox/d3d12/gltf-scene/verify_material.ps1
```

测试复用C.3有UV三角形，系统PNG编码器生成2x2固定图案。六项：默认材质、OPAQUE、MASK、BLEND、Data URI内嵌PNG、外部PNG缺失。前三种带纹理模式及内嵌模式检查五槽共享一份131B图像编码流、各因子/颜色空间/采样器/UV引用正确；缺失图片exit1并明确路径。全部按预期通过；检查均在Importer析构后进行。C.4四组回归通过。结果：[summary](../../sandbox/d3d12/gltf-scene/results/c05/summary.txt)。同一测试图用于所有槽仅为验证引用共享，不代表合理的美术材质。

本节尚未解码图像像素、上传纹理、绘制材质或实现完整PBR；编码流签名检查不是图像解码验收。D.1/D.3完成解码/上传/采样，后续PT材质课程完成相应BRDF/透明行为。glTF核心语义的适配不等于所有FBX材质或复杂扩展兼容。引擎常在资产阶段转换/压缩纹理并建立缓存，本课暂存编码字节便于检查引用与所有权。

自测：①为什么baseColor纹理RGB需要sRGB解码，而roughness不需要，baseColorFactor需不需要再解码？②同一张图能否被两个槽以不同颜色空间读取，图像数据是否必须复制两份？③没有baseColorTexture与引用的PNG文件丢失应如何分别处理？下一节C.6范围与健壮性。
