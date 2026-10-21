#pragma once
#include "core/math.h"
#include "input/actions.h"
namespace character {
class FreeCamera {
    Vec3 eye_{6,5,9};float yaw_=0,pitch_=0;
    Vec3 resetEye_{6,5,9},resetTarget_{0,1,0};
public:
    FreeCamera(){Reset();}
    // LookAt只设置当前相机，不改变R键复位目标。eye/target均为世界位置，非方向；
    // 同点或非有限值会显式失败，避免后端收到NaN相机后污染累积历史。
    void LookAt(Vec3 eye,Vec3 target){
        Vec3 forward=target-eye;
        if(!std::isfinite(eye.x)||!std::isfinite(eye.y)||!std::isfinite(eye.z)||
           !std::isfinite(forward.x)||!std::isfinite(forward.y)||!std::isfinite(forward.z))throw std::runtime_error("invalid camera look-at");
        forward.Normalize();eye_=eye;yaw_=std::atan2(forward.x,forward.z);pitch_=std::asin(std::clamp(forward.y,-1.f,1.f));
    }
    void Reset(){LookAt(resetEye_,resetTarget_);}
    // 应用显式选择展示机位；默认构造仍保留H4/H5验收机位，旧调用和测试不受影响。
    // 预设单独保存，使此后自由移动、右键转向再按R时仍恢复展示构图。
    void ResetPresentation(){resetEye_={3.2f,2.15f,5.2f};resetTarget_={0,.95f,0};Reset();}
    Vec3 Eye()const{return eye_;}
    Vec3 Forward()const{return {std::cos(pitch_)*std::sin(yaw_),std::sin(pitch_),std::cos(pitch_)*std::cos(yaw_)};}
    void Update(const CameraIntent& intent,double elapsed){
        if(!std::isfinite(elapsed)||elapsed<0||elapsed>1)throw std::runtime_error("invalid camera elapsed");
        if(intent.reset){Reset();return;}
        // 鼠标值是本帧像素位移，已经积分过时间，不再乘dt；移动速度则以世界单位/秒定义。
        yaw_-=intent.lookX*.003f;pitch_=std::clamp(pitch_-intent.lookY*.003f,-1.5f,1.5f);
        Vec3 forward{std::sin(yaw_),0,std::cos(yaw_)},right{-forward.z,0,forward.x};
        Vec3 movement=forward*intent.forward+right*intent.right+Vec3{0,intent.up,0};
        if(movement.SquareLength()>1)movement.Normalize();eye_+=movement*float(elapsed*(intent.fast?8:3));
    }
};
}
