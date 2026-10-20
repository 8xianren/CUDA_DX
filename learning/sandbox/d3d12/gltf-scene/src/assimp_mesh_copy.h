#pragma once
#include "cpu_mesh.h"
struct aiScene;
// 仅适配层内部使用：借用有效的库场景，复制所有网格定义，保持数组索引对应。
// 调用者必须让 aiScene 的所有者在调用期间存活；返回值不借用库内存。
std::vector<CpuMesh> CopyCpuMeshes(const aiScene& scene);
