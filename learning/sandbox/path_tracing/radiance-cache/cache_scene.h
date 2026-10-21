#pragma once
#include "../restir-di/direct_scene.h"
namespace cache_lesson {
using restir_di::V3;using restir_di::operator-;
constexpr double Pi=mis::pi;
inline double Length(V3 d){return std::sqrt(d.x*d.x+d.y*d.y+d.z*d.z);}
// 完整模型：接收微表面x位于z=0朝+Z；次级面y位于z=1、[-1,1]^2朝-Z；
// 面积灯位于z=0、x∈[.5,1]、y∈[-.3,.3]，朝+Z，Le=10。接收点不在灯上。
// 两段指定连接无遮挡；只估计x->y->灯的两次散射项。缓存与无缓存使用同一有限模型。
// 次级面采用正值、互易、能量守恒的教学方向性BRDF：
// f_y(wi,wo)=.6/pi*(1+.8*wi.x*wo.x)。wi、wo都从y向外；交换wi/wo不变，
// 半球积分中的wi.x*cos(theta)为奇函数而为零，因此定向半球反射率恒为.6。
// 该BRDF不是GGX或UE生产材质，仅使方向缓存具有真实可推导含义。
struct Coeff {double a=0,b=0;};
inline Coeff operator+(Coeff x,Coeff y){return {x.a+y.a,x.b+y.b};}
inline Coeff operator*(Coeff x,double k){return {x.a*k,x.b*k};}
inline V3 DrawSecondary(mis::Rng& rng){return {-1+2*rng.Uniform(),-1+2*rng.Uniform(),1};}
inline V3 DrawLight(mis::Rng& rng){return {.5+.5*rng.Uniform(),-.3+.6*rng.Uniform(),0};}
// 单个面积灯样本给出的后缀系数估计。dω=cos_l/r²*dA，cos_y=cos_l=1/r，
// 面积PDF=1/.3；故几何项1/r^4再乘面积.3。返回L(y,wo)=a+b*wo.x的两个系数。
inline Coeff TailSample(V3 y,V3 light){auto d=light-y;double r=Length(d),base=(.6/Pi)*10*.3/(r*r*r*r);return {base,base*.8*d.x/r};}
inline double Tail(Coeff c,V3 y,V3 receiver){auto wo=receiver-y;return c.a+c.b*wo.x/Length(wo);}
// x端Lambert .7/pi，均匀抽次级面qA=1/4；beta=(.7/pi)*cos_x*cos_y/r²/qA。
inline double PrefixWeight(V3 x,V3 y){auto d=y-x;double r2=d.x*d.x+d.y*d.y+d.z*d.z;return (.7/Pi)*4/(r2*r2);}
// 独立确定性后缀求积，直接展开面积积分；不调用TailSample，避免把同一采样错误当参考。
inline Coeff ExactCoefficients(V3 y,unsigned n){Coeff sum;double dx=.5/n,dy=.6/n;
    for(unsigned j=0;j<n;++j)for(unsigned i=0;i<n;++i){double lx=.5+(i+.5)*dx-y.x,ly=-.3+(j+.5)*dy-y.y,r2=lx*lx+ly*ly+1;
        double f=(.6/Pi)*10/(r2*r2)*dx*dy;sum.a+=f;sum.b+=f*.8*lx/std::sqrt(r2);}
    return sum;
}
}
