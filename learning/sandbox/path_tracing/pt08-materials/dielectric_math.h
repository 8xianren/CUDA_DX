#pragma once
#include "refraction_math.h"
// 无吸收、非磁、各向同性平滑介质，固定波长、非偏振标量近似。
// 所有结构按CPU值传递，无动态资源、同步或GPU ABI承诺；方向复用上一节的float实现。
namespace dielectric {
using refraction::V;using refraction::Dot;
// rs/rp只在非全反射时有效；全反射的复数相位未存储，两个偏振的功率反射率均为1。
struct Fresnel {double F=0,rs=0,rp=0,cosT=0;bool valid=false,tir=false;};
inline Fresnel Evaluate(double cosI,double etaI,double etaT){
    Fresnel f;
    if(!std::isfinite(cosI)||cosI<0||cosI>1||!std::isfinite(etaI)||!std::isfinite(etaT)||etaI<=0||etaT<=0)return f;
    f.valid=true;
    if(etaI==etaT){f.cosT=cosI;return f;} // 同IOR不存在光学界面；避免恰好掠射时0/0。
    double q=etaI/etaT,k=1-q*q*(1-cosI*cosI);
    if(!std::isfinite(k)){f.valid=false;return f;}
    if(k<=0){f.F=1;f.tir=true;return f;} // 包含临界切向极限；不计算复数相位，仅返回功率反射率。
    f.cosT=std::sqrt(k);
    // rs/rp用同一界面切向E基底；rp符号可能与采用不同反射偏振基底的教材相反，平方相同。
    // 非偏振假设意味着两种正交偏振各占一半入射功率，不是对振幅先平均再平方。
    f.rs=(etaI*cosI-etaT*f.cosT)/(etaI*cosI+etaT*f.cosT);
    f.rp=(etaI*f.cosT-etaT*cosI)/(etaI*f.cosT+etaT*cosI);
    f.F=.5*(f.rs*f.rs+f.rp*f.rp);return f;
}
struct Interface {V reflected{},transmitted{};double F=0,q2=1;bool valid=false;};
inline Interface Prepare(V d,V ng,float outside,float inside){
    Interface s;auto g=refraction::RefractBoundary(d,ng,outside,inside);
    if(g.status==refraction::Status::Invalid)return s;
    d=d*(1/std::sqrt(Dot(d,d)));s.reflected=d-g.normal*(2*Dot(d,g.normal));
    double ni=g.etaIncident,nt=g.etaTransmitted,q=ni/nt;s.q2=q*q;
    // 临界附近沿用几何函数的分类，不能选中一条几何函数已拒绝的透射分支。
    if(g.status==refraction::Status::NoTransmission)s.F=1;
    else {auto f=Evaluate(std::clamp(double(-Dot(d,g.normal)),0.,1.),ni,nt);if(!f.valid)return s;s.F=f.F;s.transmitted=g.direction;}
    s.valid=std::isfinite(s.q2)&&s.q2>0;return s;
}
enum class Event {Invalid,Reflection,Transmission};
enum class Choice {Fresnel,Half};
struct Sample {V direction{};double eventMass=0,weight=0,rrEtaScale=1;Event event=Event::Invalid;};
// 这是相机路径的Radiance模式采样；u必须有限且位于[0,1)，由调用者拥有的RNG产生。
// 每次仅选择一个离散分支，连续pdfOmega恒为0。weight已完成除以eventMass，不可再次除概率。
inline Sample Draw(const Interface& s,double u,Choice choice=Choice::Fresnel){
    Sample r;if(!s.valid||!std::isfinite(u)||u<0||u>=1)return r;
    // 先处理零贡献分支，确保F=0/F=1时不选不可能事件，也不会计算0/0。
    double pr=s.F<=0?0:(s.F>=1?1:(choice==Choice::Half?.5:s.F));
    if(u<pr){r.event=Event::Reflection;r.direction=s.reflected;r.eventMass=pr;r.weight=s.F/pr;}
    else {r.event=Event::Transmission;r.direction=s.transmitted;r.eventMass=1-pr;r.weight=(1-s.F)*s.q2/(1-pr);
        // RR用beta*etaScale评估存活概率以移除折射坐标缩放；实际L仍使用原beta，不能把此补偿乘进L。
        r.rrEtaScale=1/s.q2;}
    return r;
}
}
