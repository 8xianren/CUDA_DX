#pragma once
#include "animation/animation.h"
#include <filesystem>
namespace character {
// CPU场景构造与渲染资源分开；角色网格/节点保持在数组前部，静态环境追加。
// presentation=false保留H5/H6的面积灯与反射板验收场景；true使用配合天空照明的展示布景。
// 布景选择属于应用配置，不把灯光、资产加载或相机状态塞进人物控制器。
CpuScene BuildDemoScene(const Rig&,const std::filesystem::path& runtimeAssets,bool presentation=false);
}
