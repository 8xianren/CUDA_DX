#pragma once
#include "dxr_gpu_sequence.h"
// R.13.7：积分类目标与显示参数分离。Key只保存影响未曝光线性图像的状态。
// 不比较整个View的原始字节：它包含逐帧serial，通用结构也可能有padding。
namespace history_policy {
struct TargetKey {
    std::array<float,16> inverseVP{};std::array<float,4> eyeNear{},forwardMax{};
    std::array<uint32_t,4> rectangle{};std::array<uint32_t,2> extent{};
    uint32_t light=0,material=0,sceneMask=0,filter=0,integratorRevision=1;
};
enum Reason:unsigned {Initial=1,Camera=2,Mapping=4,Light=8,Material=16,Scene=32,Filter=64,Integrator=128,Manual=256};
inline std::string reason_text(unsigned r){
    if(!r)return "continue";std::string out;
    for(auto e: {std::pair<unsigned,const char*>{Initial,"initial"},{Camera,"camera"},{Mapping,"mapping"},{Light,"light"},{Material,"material"},{Scene,"scene"},{Filter,"filter"},{Integrator,"integrator"},{Manual,"manual"}})
        if(r&e.first){if(!out.empty())out+='+';out+=e.second;}
    return out;
}
inline TargetKey key(const RaySubmission& frame,unsigned revision=1){
    TargetKey k;const auto& v=frame.view;
    for(unsigned i=0;i<16;++i)k.inverseVP[i]=v.invViewProjection.m[i/4][i%4];
    for(unsigned i=0;i<4;++i){k.eyeNear[i]=v.eyeNear[i];k.forwardMax[i]=v.forwardMax[i];k.rectangle[i]=v.viewRect[i];}
    k.extent={v.targetInfo[0],v.targetInfo[1]};
    k.light=(v.targetInfo[3]>>16)&1;k.material=(v.targetInfo[3]>>17)&1;k.sceneMask=(v.targetInfo[3]>>8)&255;
    k.filter=frame.controls[2]&2; // 固定像素中心与箱式像素面积平均是不同目标；普通jitter值不进入Key。
    k.integratorRevision=revision;return k;
}
struct Decision {unsigned previousCount=0,count=0,epoch=0,reasons=0;};
class Tracker {
    bool valid_=false;TargetKey previous_{};unsigned count_=0,epoch_=0;
public:
    Decision schedule(const TargetKey& now,bool force=false){
        unsigned r=valid_?0:Initial;
        if(valid_){
            if(now.inverseVP!=previous_.inverseVP||now.eyeNear!=previous_.eyeNear||now.forwardMax!=previous_.forwardMax)r|=Camera;
            if(now.rectangle!=previous_.rectangle||now.extent!=previous_.extent)r|=Mapping;
            if(now.light!=previous_.light)r|=Light;if(now.material!=previous_.material)r|=Material;
            if(now.sceneMask!=previous_.sceneMask)r|=Scene;if(now.filter!=previous_.filter)r|=Filter;
            if(now.integratorRevision!=previous_.integratorRevision)r|=Integrator;
        }
        if(force)r|=Manual;
        if(r){count_=0;++epoch_;}
        // 本程序在提交前调用；随后资源/提交失败即终止，不继续使用这份已安排的状态。
        Decision d{count_,count_+1,epoch_,r};++count_;previous_=now;valid_=true;return d;
    }
};
struct Settings {
    view_reference::Case camera=progressive_reference::camera();
    unsigned mask=7,seed=0,flags=0;bool doubleLight=false,blackMaterial=false;
    float exposureMultiplier=1;unsigned toneMap=0; // 0=Reinhard，1=截断对照，仅用于离线显示。
};
inline RaySubmission submission(const Settings& s,unsigned randomIndex,unsigned serial){
    RaySubmission f;f.view=view_reference::make_view(s.camera,serial);
    f.view.targetInfo[0]=progressive_reference::Width;f.view.targetInfo[1]=progressive_reference::Height;
    f.view.targetInfo[3]=(s.mask<<8)|(unsigned(s.doubleLight)<<16)|(unsigned(s.blackMaterial)<<17);
    f.controls={randomIndex,s.seed,s.flags,0};return f;
}
} // namespace history_policy
