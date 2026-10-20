# C.2 Assimp 接入测试记录

2026-10-16，按用户要求先完成接入与测试；不是已经完成 C.2 正式授课。[代码、命令与结果入口](../../sandbox/d3d12/gltf-scene/README.md)。

使用 Assimp 6.0.2，固定提交 fb375dd8c0a032106a2122815fb18dffe0283721 与下载 SHA256。CMake + VS2022 x64 Release 编译静态库，未全局安装。只启用课程相关导入器。纯 CPU 探针不涉及 CUDA、D3D12 资源与 Fence。

调用 ReadFile(path, aiProcess_Triangulate | aiProcess_ValidateDataStructure)，由库读取容器和解码字节。失败时检查空指针并保存 GetErrorString；成功场景及子对象均归 Importer 所有，不能在 Importer 析构后继续使用。尚未编写自有 Mesh/Material 的复制适配层，不将 aiScene 当成已经完成的渲染器资产。

## 本机验收

- 原 C.1 glTF：两个 primitive 转为两个 aiMesh，两个节点各引用这两个网格；网格定义 2、引用 4、定义三角形 2、相机 1。六个解码角点、索引、两种基础颜色与独立已知答案一致；节点平移为 -2/+2。
- 用 Assimp 导出 glb2 再导入：打印的几何、局部矩阵、引用与基础颜色一致。**相机对象由 1 变成 0**；对应 View 节点保留。这是此版本导出回环的限制，不代表 GLB 格式不支持相机，也不是 glTF 输入读取失败。不把此回环称为完整场景等价；相机投影参数、纹理及其他材质属性未覆盖。
- 自编 OBJ 四边形：三角化后为一个网格、两个三角形。
- 上游固定提交 test/models/FBX/box.fbx：一个网格、一个引用、十二个三角形；不是所有 FBX 的兼容性保证。
- 错误 GLB magic、截断文件、非法 JSON chunk 长度、缺失外部 bin：均正常返回 1，并给出 IMPORT_ERROR 与输入路径。测试通过要求正常报错，不能用进程崩溃代替拒绝输入。

日志在 [results/c02](../../sandbox/d3d12/gltf-scene/results/c02/summary.txt)。测试由 verify_importer.ps1 一键复现，导出与损坏样本只写 results，不修改 C.1 原始资产。COLLADA、PLY、STL 仅编译启用，尚未样本验收。多格式基础导入与完整材质/动画支持是不同层次。

后续仍按 C.2、C.3 等原编号授课，不合并、不另拆子课。C.2 解释容器和库生命周期；C.3 理解原始 accessor 布局与解码后的 CPU 表示，再设计自有结构。
