#pragma once
#include "cpu_mesh.h"
struct aiScene;
// 仅适配层内部使用：借用有效的库场景，复制所有网格定义，保持数组索引对应。
// 调用者必须让 aiScene 的所有者在调用期间存活；返回值不借用库内存。
// H2专用显式能力开关：只允许保存绑定网格；调用者必须另行保存全部骨骼权重并实现蒙皮。
// 静态入口保留默认拒绝，避免把骨骼信息静默丢弃。
std::vector<CpuMesh> CopyCpuMeshes(const aiScene& scene,bool preserveBindMeshForSkinning=false);
