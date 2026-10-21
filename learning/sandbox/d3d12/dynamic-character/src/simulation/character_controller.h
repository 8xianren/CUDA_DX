#pragma once
#include "core/math.h"
#include <cstdint>
#include <functional>

namespace character {
// 领域意图无按键码：自动行为、输入映射、测试回放都可生成同样的数据。
struct CharacterIntent {float x=0,z=0;bool run=false,jumpPressed=false;};
enum class Motion {Idle,Walk,Run,Jump,Fall,Land};
const char* MotionName(Motion);
struct CharacterState {
    Vec3 position{},velocity{};float yaw=0;Motion motion=Motion::Idle;
    double stateTime=0;bool grounded=true;uint64_t tick=0;
};
struct ControllerConfig {double step=1.0/120;float walkSpeed=1.5f,runSpeed=3.5f,jumpSpeed=4.5f,gravity=9.81f,ground=0;};
class CharacterController {
    ControllerConfig config_;CharacterState state_;
public:
    explicit CharacterController(ControllerConfig config={});
    // 此接口恰好推进一个固定步；调用者不能把可变渲染dt传进来改变积分规则。
    void Step(const CharacterIntent&);
    const CharacterState& State()const{return state_;}
    const ControllerConfig& Config()const{return config_;}
};
class FixedClock {
    double step_,accumulator_=0;uint64_t ticks_=0;
public:
    explicit FixedClock(double step=1.0/120):step_(step){if(!(step>0)||!std::isfinite(step))throw std::runtime_error("invalid fixed step");}
    // callback逐步采样意图；一次性输入由上层队列消费，不能每个补跑步都复用jumpPressed。
    unsigned Advance(double elapsed,const std::function<void(uint64_t)>& callback);
    uint64_t Ticks()const{return ticks_;}
    double Alpha()const{return accumulator_/step_;}
};
// 可重复演示行为，与Win32输入完全独立；沿X在有限空地往返，周期性触发一次跳跃。
CharacterIntent DemoIntent(const CharacterState&,double fixedStep);
}
