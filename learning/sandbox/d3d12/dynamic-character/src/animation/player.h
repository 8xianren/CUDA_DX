#pragma once
#include "animation/animation.h"
namespace character {
// 动作选择由上层给出；播放器不认识Idle/Jump等业务状态，也不接触输入与GPU。
class AnimationPlayer {
    const Rig& rig_;uint32_t clip_;double time_=0,blendTime_=1;bool loop_=true;
    std::vector<Pose> previous_,pose_;
public:
    explicit AnimationPlayer(const Rig& rig,uint32_t initial):rig_(rig),clip_(initial),pose_(Sample(rig,initial,0)){}
    void Advance(uint32_t requested,bool loop,double seconds,float playbackRate=1){
        if(!std::isfinite(seconds)||seconds<0||!std::isfinite(playbackRate)||playbackRate<0)throw std::runtime_error("invalid animation clock");
        if(requested!=clip_){previous_=pose_;clip_=requested;time_=0;blendTime_=0;}
        loop_=loop;time_+=seconds*playbackRate;blendTime_+=seconds;
        auto target=Sample(rig_,clip_,time_,loop_);
        pose_=blendTime_<.12?Blend(previous_,target,float(blendTime_/.12)):std::move(target);
    }
    const std::vector<Pose>& Current()const{return pose_;}
};
}
