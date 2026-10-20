# C.3 accessor 布局与自有 CPU 网格

2026-10-16。本节保持一个完整课节，不拆子课。目标：区分文件编码、Assimp 解码表示、自有 CPU 布局；实现深拷贝而非文件解析器。[共享代码入口](../../sandbox/d3d12/gltf-scene/README.md)。

## 从读取第 i 个属性推导布局

假设普通、非稀疏、未压缩的向量 accessor。bufferView 给出缓冲中的字节区间，accessor 给出区间内的起点、元素数量、形状和分量编码。count 是向量/标量元素数，不是字节数。type=VEC3 表示每元素三个分量，componentType=FLOAT 表示每分量四字节，两者确定元素大小 12B。byteStride 则是相邻元素起点之间的距离，不一定等于元素大小。

从 buffer 起点出发，先到 view，再到属性在 view 内的起点，再跨过 i 个步长：

`地址(i) = buffer起点 + bufferView.byteOffset + accessor.byteOffset + i * stride`

无 byteStride 的普通紧密向量数组使用元素大小作为步长；矩阵填充、稀疏 accessor 和压缩扩展不套用这个简化例子，交给库处理。

自编测试 buffer 前缀 16B，顶点区 view 长度 120B、stride40、count3。每条记录位置12B、法线12B、UV8B、颜色4B、padding4B。各 accessor 偏移 0/12/24/32。第2个顶点（i=1）的颜色地址为16+32+40=88；第3个顶点 UV 地址为16+24+80=120。普通向量访问的 view 内上界是 accessorOffset+(count-1)*stride+elementSize，不能超过 view.byteLength；view 自身也不能超过 buffer。索引区 viewOffset136，accessorOffset4，索引数据从140开始。

## 编码不是排列，归一化不是向量单位化

颜色 accessor 使用 UNSIGNED_BYTE、VEC4、normalized=true：每条颜色4B，读取后分量映射为 x/255。因此128→0.5019608，255→1。它不计算颜色向量长度，也不是 gamma/sRGB 转换。对非归一化整数数据则保留整数数值意义。索引采用 SCALAR uint8/uint16/uint32，不能按归一化颜色处理。即使编码不变，也能选择交错或分离存储，压缩/编码与布局是独立决策。

依据：[Khronos accessor 规范](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#accessors)。这里只解释读取约束，不自行解码生产资产。

## Assimp 到自有网格

src/cpu_mesh.h 定义 Vertex：position[3]、normal[3]、uv[2]、color[4] 全为float，sizeof48，字段offset0/12/24/32，有static_assert。CpuMesh 以 vector 拥有顶点和 uint32 索引，并记录 materialIndex 与三个可选属性存在标志。每个 aiMesh 对应一个 CpuMesh，保留原网格数组顺序；尚未导入节点或材质资源。

`std::vector<CpuMesh> LoadCpuMeshes(const std::string& path)` 同步调用 ReadFile，然后将 mVertices、mNormals、mTextureCoords[0]、mColors[0] 逐字段复制。HasNormals、HasTextureCoords(0)、HasVertexColors(0) 检查可选通道；纹理坐标在库中以 aiVector3D 保存，本课只接受 mNumUVComponents[0]==2，读取 x/y。mFaces 每面一个 aiFace，检查3个索引且全部小于顶点数，再铺平成 vector<uint32_t>。返回值拥有数据；失败抛异常，局部对象 RAII 自动释放，调用者拿不到半成品。

缺失法线时写零并标记hasNormals=false，不能将其当作有效法线；缺UV写零且标记false；缺颜色写白且标记false。白色用于将来乘法着色的单位元。没有自动生成法线、合并顶点或做世界变换。

Assimp6.0.2的glTF2Importer.cpp第639–644行解码UV后执行y=1-y，即使没开额外FlipUVs也是如此。本适配层保留Assimp约定，源UV(0,0.25)成为(0,0.75)；后续D.3必须结合图像方向处理，不能盲目再次翻转。normalized和UV翻转是两种不同变换。

## 本机验证与动手

仓库根运行：

```powershell
& learning/sandbox/d3d12/gltf-scene/build_importer.ps1 -Lesson c03
& learning/sandbox/d3d12/gltf-scene/verify_layout.ps1
```

脚本只生成固定资产，使用 BinaryWriter 写已知数据、ConvertTo-Json 写元信息；它不是读取任意 glTF 的解析器。生成文件和日志直接放 results/c03。没有新增 Python 依赖。

四个相同三角形样例分别采用uint8/16/32索引或无索引，全部验证position/normal/UV/normalized color及输出索引0,1,2；另以C.1样例验证缺失属性占位与标记。全部五项PASS。输出颜色128/255=0.501960814，64/255=0.250980407，32/255=0.125490203。四种输入统一输出48B顶点和uint32索引。检查在LoadCpuMeshes返回后执行，此时Importer已经析构。结果见[summary](../../sandbox/d3d12/gltf-scene/results/c03/summary.txt)。

本课只有CPU网格，未上传GPU、未验证完整扩展或纹理。引擎可以按用途拆分顶点流、量化法线/UV、选择16位索引等；本课float字段与32位索引便于观察，不能称生产最省内存布局。未来GPU步长必须匹配所上传的实际表示，不能沿用源文件40B步长读取当前48B结构。

自测：①viewOffset16、accessorOffset24、stride40时，第3个UV（i=2）从哪里读？②为什么UNORM8的128不是128，也不精确等于0.5？③Importer析构后自有vector为何仍有效，文件stride40能否直接用于这个48B Vertex？下一节C.4：节点层级和世界变换，保留共享网格与实例。
