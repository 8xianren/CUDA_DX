#pragma once
#include "cpu_mesh.h"
#include "cpu_material.h"
#include <array>

// 数学约定：列向量 p'=M*p；内存约定：m[row*4+column] 按行保存。
// 两种约定独立。这里既不是 glTF JSON 矩阵序列，也不是直接可 memcpy 的 DXR 描述符。
struct Matrix4 {
    std::array<float,16> m{1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
};
Matrix4 Multiply(const Matrix4& a,const Matrix4& b);
std::array<float,3> TransformPoint(const Matrix4& m,const float* p);
struct CpuNode {
    std::string name;
    int parent=-1; // 根为 -1；父节点在数组中必须先于子节点。
    Matrix4 local,world;
    std::vector<uint32_t> meshIndices; // 引用共享网格定义，不复制顶点数组。
};
struct MeshInstance { uint32_t nodeIndex,meshIndex; };
struct CpuScene {
    std::vector<std::string> diagnostics; // 成功也可能有明确的能力提示；调用者应显示，不能吞掉。
    MaterialAssets materialAssets;
    std::vector<CpuMesh> meshes;
    std::vector<CpuNode> nodes;
    std::vector<MeshInstance> instances; // 每个 node-mesh 引用一项；不是强制的 TLAS 粒度。
};
CpuScene LoadCpuScene(const std::string& path);
// 修改 local 后显式调用；当前CPU全量更新，不涉及GPU缓冲/Fence或自动脏标记。
void UpdateWorldMatrices(CpuScene& scene);
