#pragma once
#include <cmath>
#include <algorithm>
// PT.8独立CPU方向参考：本节不更新beta，也不模拟Fresnel概率或吸收。
namespace refraction {
struct V {float x=0,y=0,z=0;};
inline V operator+(V a,V b){return {a.x+b.x,a.y+b.y,a.z+b.z};}
inline V operator-(V a,V b){return {a.x-b.x,a.y-b.y,a.z-b.z};}
inline V operator*(V a,float s){return {a.x*s,a.y*s,a.z*s};}
inline float Dot(V a,V b){return a.x*b.x+a.y*b.y+a.z*b.z;}
inline bool Finite(V a){return std::isfinite(a.x)&&std::isfinite(a.y)&&std::isfinite(a.z);}
enum class Status {Invalid,Transmitted,NoTransmission};
struct Result {
    V direction{},normal{}; // direction仅Transmitted时有效；normal朝向当前射线所在介质。
    float etaIncident=0,etaTransmitted=0,ratio=0,k=0;
    bool entering=false;
    Status status=Status::Invalid;
};
// d朝向交点，outward由物体内部指向外部；二者必须近似单位向量。
// etaOutside/etaInside是正实数折射率，只支持两个均匀、各向同性、非吸收介质的平滑界面。
// 返回值完全按值拥有；没有指针、资源分配或同步。Invalid与物理上的无透射必须区分。
inline Result RefractBoundary(V d,V outward,float etaOutside,float etaInside){
    Result r;
    if(!Finite(d)||!Finite(outward)||!std::isfinite(etaOutside)||!std::isfinite(etaInside)||etaOutside<=0||etaInside<=0)return r;
    float ld=Dot(d,d),ln=Dot(outward,outward);
    if(std::abs(ld-1)>1e-4f||std::abs(ln-1)>1e-4f)return r;
    // 消除输入单位化的末位残差；大幅错误的法线长度已拒绝，不能靠normalize掩盖坏数据。
    d=d*(1/std::sqrt(ld));outward=outward*(1/std::sqrt(ln));
    float side=Dot(d,outward);
    if(side==0)return r; // 恰好沿界面行进时，单靠d/n无法判断当前介质，交由上层处理。
    r.entering=side<0;r.normal=r.entering?outward:outward*(-1);
    r.etaIncident=r.entering?etaOutside:etaInside;r.etaTransmitted=r.entering?etaInside:etaOutside;
    r.ratio=r.etaIncident/r.etaTransmitted;
    if(!std::isfinite(r.ratio))return r;
    float cosine=std::clamp(-Dot(d,r.normal),0.f,1.f);
    float sin2Incident=std::max(0.f,1-cosine*cosine);
    float sin2Transmitted=r.ratio*r.ratio*sin2Incident;
    if(!std::isfinite(sin2Transmitted))return r;
    r.k=1-sin2Transmitted;
    // k<0是严格全反射；k==0是临界切向极限。本接口均不返回穿越界面的透射射线。
    // 必须先分支再sqrt。不能把负k clamp到0后伪造一条切向透射射线。
    if(r.k<=0){r.status=Status::NoTransmission;return r;}
    r.direction=d*r.ratio+r.normal*(r.ratio*cosine-std::sqrt(r.k));
    r.status=Status::Transmitted;return r;
}
}
