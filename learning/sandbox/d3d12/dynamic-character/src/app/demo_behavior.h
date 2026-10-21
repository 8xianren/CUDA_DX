#pragma once
#include "simulation/character_controller.h"
namespace character {
// 展示路线属于应用行为策略，控制器仍只读方向/奔跑/起跳意图。
// 保留8秒内的速度与起跳时序，但沿半径2.5m的圆周移动，避免单程15m跑出布景。
// s(t)由各阶段速度积分得到，theta=s/R，切向速度方向(cos theta,-sin theta)。
inline CharacterIntent PresentationIntent(const CharacterState& state,double step){
    auto intent=DemoIntent(state,step);double time=state.tick*step,cycle=std::floor(time/8),t=time-cycle*8;
    double distance=cycle*15+1.5*std::clamp(t-1.,0.,2.)+3.5*std::clamp(t-3.,0.,3.)+1.5*std::clamp(t-6.,0.,1.);
    if(intent.x!=0){intent.x=float(std::cos(distance/2.5));intent.z=float(-std::sin(distance/2.5));}
    return intent;
}
}
