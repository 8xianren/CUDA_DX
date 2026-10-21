#pragma once
#include "cpu_scene.h"
#include "core/math.h"
#include <array>
#include <map>

namespace character {
// 自有数据与Importer生命周期解耦；每个节点保留默认TRS，缺失轨道回退到默认值。
struct Pose {Vec3 translation;Quat rotation;Vec3 scale{1,1,1};};
template<class T> struct AnimationKey {double seconds;T value;};
struct Track {uint32_t node;std::vector<AnimationKey<Vec3>> translation,scale;std::vector<AnimationKey<Quat>> rotation;};
struct Clip {std::string name;double duration;std::vector<Track> tracks;};
struct Joint {uint32_t node;Mat4 inverseBind;};
// 顶点影响采用固定4项，当前真实GLB最多4项；超出必须拒绝，不能裁剪后声称无损。
struct Influence {uint32_t joint[4]{};float weight[4]{};};
static_assert(sizeof(Influence)==32);
struct Skin {uint32_t mesh,node;std::vector<Joint> joints;std::vector<Influence> influence;};
struct Rig {
    CpuScene scene;std::vector<Pose> defaults;std::vector<Clip> clips;std::vector<Skin> skins;
    uint32_t ClipIndex(const std::string&)const;
};
// 文件导入入口位于assets/character_import.h，运行时动画模块不负责文件I/O。
std::vector<Pose> Sample(const Rig&,uint32_t clip,double seconds,bool loop=true);
std::vector<Pose> Blend(const std::vector<Pose>&,const std::vector<Pose>&,float alpha);
std::vector<Mat4> Worlds(const Rig&,const std::vector<Pose>&);
std::vector<Mat4> Palette(const Skin&,const std::vector<Mat4>&);
std::vector<Vertex> SkinCpu(const CpuMesh&,const Skin&,const std::vector<Mat4>&);
}
