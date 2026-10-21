#pragma once
#include "render/frame.h"
#include "animation/animation.h"
#include "simulation/free_camera.h"
#include "simulation/character_controller.h"
namespace character {
// 应用边界提取：动画与仿真独立产出，再组合成后端所需的几何快照。
inline RenderFrame ExtractFrame(const Rig& rig,const std::vector<Pose>& pose,const CharacterState& state,const FreeCamera& camera){
    RenderFrame frame;frame.eye=camera.Eye();frame.forward=camera.Forward();frame.sceneRevision=state.tick;
    frame.characterWorld=Compose({1,1,1},{0,std::sin(state.yaw*.5f),0,std::cos(state.yaw*.5f)},state.position);
    frame.rigWorlds=Worlds(rig,pose);
    for(const auto& skin:rig.skins)frame.palettes.push_back(Palette(skin,frame.rigWorlds));return frame;
}
}
