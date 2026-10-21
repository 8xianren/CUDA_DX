#pragma once
#include "animation/player.h"
#include "simulation/character_controller.h"
namespace character {
// 应用组合层把领域运动状态映射为本资产的动作配置；不反向让动画库依赖人物控制器。
inline void AdvanceLocomotion(AnimationPlayer& player,const Rig& rig,const CharacterState& state,double elapsed){
    const char* clip="Idle_Loop";bool loop=true;
    switch(state.motion){case Motion::Idle:break;case Motion::Walk:clip="Walk_Loop";break;case Motion::Run:clip="Sprint_Loop";break;
    case Motion::Jump:clip="Jump_Start";loop=false;break;case Motion::Fall:clip="Jump_Loop";break;case Motion::Land:clip="Jump_Land";loop=false;break;}
    player.Advance(rig.ClipIndex(clip),loop,elapsed);
}
}
