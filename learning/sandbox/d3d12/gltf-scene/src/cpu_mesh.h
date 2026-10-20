#pragma once
#include <cstdint>
#include <cstddef>
#include <vector>
#include <string>

// 自有 CPU 表示：每顶点连续 12 个 float（AoS），不照搬文件中的压缩编码或步长。
// 尚未上传 GPU；未来若直接作为 GPU 顶点格式，需要同步声明 stride/offset。
struct Vertex {
    float position[3]{};
    float normal[3]{};
    float uv[2]{};
    float color[4]{1,1,1,1};
};
static_assert(sizeof(Vertex)==48);
static_assert(offsetof(Vertex,normal)==12 && offsetof(Vertex,uv)==24 && offsetof(Vertex,color)==32);
struct CpuMesh {
    std::vector<Vertex> vertices;
    std::vector<uint32_t> indices;
    uint32_t materialIndex=0;
    // 零法线/零UV只是缺失属性的占位，标志防止以后误当成真实数据。
    bool hasNormals=false, hasUV=false, hasColors=false;
};
// 同步加载并深拷贝。返回对象独立持有数组，调用者不需要维持 Assimp::Importer 存活。
// 本节只返回网格定义；节点与材质资源留到 C.4/C.5，不称完整场景导入器。
std::vector<CpuMesh> LoadCpuMeshes(const std::string& path);
