# C.2 glTF 与 GLB 容器和 Assimp 加载

2026-10-16。C.2 单节讲授；[课程代码与命令](../../sandbox/d3d12/gltf-scene/README.md)，[先前接入验收](C.2-Assimp接入测试记录.md)。不展开 C.3 的 accessor 解码布局。

要解决的问题：同一组节点、网格与材质，如何存盘并交给渲染程序？对象语义与文件包装是两层。可类比资源清单和资源包：清单说明对象及引用，二进制保存实际数据。

`.gltf` 是 JSON 文件，可引用外部 bin、图片，也可使用 Data URI 内嵌数据。URI 是资源标识；本课相对 URI 相对于资产文件所在目录解析，不是任意启动目录。Data URI 将数据写入 URI，本身不是压缩。当前资产 buffers[0] 的 uri 为 c01-shared-mesh.bin、byteLength 为 60；JSON 文件存在并不代表其依赖齐全。

GLB 是二进制容器，仍含 JSON。GLB 2.0 文件头为三个小端 uint32：magic、version、整个文件 length，共 12 字节。每块由 chunkLength、chunkType 两个 uint32 与内容组成；chunkLength 不包括这 8 字节块头。JSON 块在前，可选 BIN 块保存二进制。块按四字节对齐，JSON 用空格补齐、BIN 用零补齐。GLB 可引用外部资源，不保证完全自包含，也不等于压缩格式。依据：[Khronos glTF 2.0 规范](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#glb-file-format-specification)。

本机读取已生成样本头部，结果保存 results/c02/container-header.txt：实际/声明长度 1920，magic glTF，version 2，JSON 内容 1796 字节，BIN 块头偏移 1816，BIN 内容 96 字节。等式 12+(8+1796)+(8+96)=1920。这里只检查已知样本的包装，不写通用解析器；96 字节不要求等于原 bin 的 60 字节，导出器会重新组织数据。数据语义与字节完全相同是不同要求。

## 对应 API 与所有权

实际头文件 Importer.hpp：

```cpp
const aiScene* ReadFile(const char* pFile, unsigned int pFlags);
const char* GetErrorString() const;
```

pFile 指向输入路径字符串；pFlags 是按位或的后处理选项。当前探针 src/import_probe.cpp 第 33–40 行构造 Importer 并 ReadFile，使用 Triangulate（多边形三角化）与 ValidateDataStructure（检查导入后结构），没有启用预变换顶点、坐标翻转或生成法线。这两个选项不等于完整 glTF 规范验证；点线也不会因此变成三角形，探针后续会拒绝非三角形面。

返回 nullptr 表示失败；成功返回只读借用指针。scene、mesh、顶点数组等全部由 Importer 持有，Importer 析构或再次 ReadFile 时，旧数据失效。不能在局部 Importer 析构后返回 scene 指针；不能只复制指针就声称自有结构独立。后续应复制所需数据到自有 CPU 容器，或明确让 Importer 与借用对象共同存活。错误字符串也要在继续调用或释放对象前保存。

ReadFile 在本线程返回后 CPU 结果才可用；当前没有异步 GPU 上传，也没有 GPU Fence。Importer 实例不能被多个线程同时操作。磁盘加载成功还不等于图片已解码、纹理已上传或 BLAS 已创建；本次样本无纹理，相关验证在后续 C.5/D 阶段进行。

## 验证及边界

原始 glTF 相机为 1，Assimp 导出的 GLB 再读后相机为 0，但 View 节点仍在。不能据此推断 GLB 不支持相机；这次回环不是纯包装，库导出也会影响语义。测试仅确认几何、局部变换、引用和基础颜色一致。

错误 magic、截断、错误 chunk 长度均 exit=1，诊断 No suitable reader found；缺失 bin 为 GLTF: could not open referenced file。前者定位较笼统，不声称精确到字段或字节。项目要附上路径和加载阶段，不能拿 nullptr 接着创建 GPU 资源。

当前 demo 启动时直接导入，方便观测。成熟资产管线通常把导入/转换与运行时加载分开，缓存适合自身资源布局的数据；本课先学习共同的文件→CPU数据→GPU资源链路，不提前实现完整资产构建系统。

动手：在仓库根目录执行 `& learning/sandbox/d3d12/gltf-scene/verify_importer.ps1`，查看 results/c02/gltf.txt、glb.txt、missing-buffer.txt；比对节点引用与相机计数。不要改原始资产制造失败，脚本已隔离生成损坏变体。

自测：①只复制 gltf 不复制其引用 bin，为什么仍会失败？②局部 Importer 的 ReadFile 返回值能否直接返回给调用者长期使用？③为什么 GLB 回环相机丢失不能说明 GLB 格式没有相机能力？下一节 C.3：源 accessor 描述与库解码后的网格数据。
