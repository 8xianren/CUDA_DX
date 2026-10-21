#include "simulation/character_controller.h"
#include <algorithm>
#include <cmath>
#include <stdexcept>
namespace character {
const char* MotionName(Motion s){switch(s){case Motion::Idle:return "Idle";case Motion::Walk:return "Walk";case Motion::Run:return "Run";case Motion::Jump:return "Jump";case Motion::Fall:return "Fall";case Motion::Land:return "Land";}throw std::runtime_error("invalid motion");}
CharacterController::CharacterController(ControllerConfig config):config_(config){
    if(!(config.step>0&&config.step<=.1&&config.gravity>0&&config.jumpSpeed>0&&config.walkSpeed>=0&&config.runSpeed>=0))throw std::runtime_error("invalid controller config");
    state_.position.y=config.ground;
}
void CharacterController::Step(const CharacterIntent& input){
    if(!std::isfinite(input.x)||!std::isfinite(input.z))throw std::runtime_error("nonfinite intent");
    const float dt=float(config_.step);state_.stateTime+=config_.step;
    auto transition=[&](Motion next){if(state_.motion!=next){state_.motion=next;state_.stateTime=0;}};
    float x=input.x,z=input.z,length=std::sqrt(x*x+z*z);
    if(length>1){x/=length;z/=length;}bool moving=length>1e-4f;
    const float speed=input.run?config_.runSpeed:config_.walkSpeed;
    state_.velocity.x=x*speed;state_.velocity.z=z*speed;
    if(moving)state_.yaw=std::atan2(x,z);
    if(input.jumpPressed&&state_.grounded&&state_.motion!=Motion::Land){
        state_.grounded=false;state_.velocity.y=config_.jumpSpeed;transition(Motion::Jump);
    }
    // 水平运动与动画根骨骼分离；首版无导航/障碍滑动，只解决平面接触。
    state_.position.x+=state_.velocity.x*dt;state_.position.z+=state_.velocity.z*dt;
    if(!state_.grounded){
        // 每个固定步的匀加速度解析更新，位置使用更新前速度；避免先减重力再多算半步下落。
        state_.position.y+=state_.velocity.y*dt-.5f*config_.gravity*dt*dt;
        state_.velocity.y-=config_.gravity*dt;
        if(state_.velocity.y<=0)transition(Motion::Fall);
        if(state_.position.y<=config_.ground&&state_.velocity.y<0){
            state_.position.y=config_.ground;state_.velocity.y=0;state_.grounded=true;transition(Motion::Land);
        }
    }else if(state_.motion!=Motion::Land||state_.stateTime>=.15){transition(moving?(input.run?Motion::Run:Motion::Walk):Motion::Idle);}
    ++state_.tick;
}
unsigned FixedClock::Advance(double elapsed,const std::function<void(uint64_t)>& callback){
    if(!std::isfinite(elapsed)||elapsed<0||elapsed>1)throw std::runtime_error("elapsed outside fixed-clock contract");
    accumulator_+=elapsed;unsigned steps=0;
    while(accumulator_+1e-12>=step_){callback(ticks_);++ticks_;++steps;accumulator_-=step_;}
    if(accumulator_<0&&accumulator_>-1e-10)accumulator_=0;
    return steps;
}
CharacterIntent DemoIntent(const CharacterState& state,double step){
    const auto cycleTicks=uint64_t(std::llround(8/step));const auto phase=state.tick%cycleTicks;
    double t=phase*step;CharacterIntent intent;
    if(t<1||t>=7)return intent;
    // 以8秒周期轮换方向；转向由意图决定，不把装饰石头误称为已实现碰撞体。
    intent.x=((state.tick/cycleTicks)%2)==0?1.f:-1.f;
    intent.run=t>=3&&t<6;intent.jumpPressed=phase==uint64_t(std::llround(4/step));return intent;
}
}
