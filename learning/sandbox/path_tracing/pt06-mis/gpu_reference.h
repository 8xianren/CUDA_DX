#pragma once
#include "gpu_mis.h"
#include "mis_math.h"
// CPU对照与shader使用同一随机整数序列，但独立用解析平面/矩形代替DXR求交。
// double评估方向与PDF，允许GPU float三角函数/累加存在舍入差异。
namespace gpu_reference {
inline uint32_t Next(uint32_t& state){state+=0x9e3779b9u;uint32_t x=state;x=(x^(x>>16))*0x21f0aaadu;x=(x^(x>>15))*0x735a2d97u;return x^(x>>15);}
inline double Uniform(uint32_t& state){return ((Next(state)>>9)+.5)/8388608.;}
inline std::array<double,2> Camera(const MisConfig& c,uint32_t p){
    return {c.panX+(2.*(p%c.width+.5)/c.width-1)*c.halfView,c.panY+(1-2.*(p/c.width+.5)/c.height)*c.halfView};
}
inline bool Receiver(const std::array<double,2>& p){return mis::Inside(p[0],p[1],-1,1,-1,1);}
inline MisPixel Evaluate(const MisConfig& c,uint32_t pixel){
    MisPixel result{};auto p=Camera(c,pixel);if(!Receiver(p))return result;
    result.diagnostics[0]=c.receiver+1;double sums[4]{};
    uint32_t rng=(pixel+1)*747796405u+c.seed*2891336453u;
    for(uint32_t s=0;s<c.rounds;++s)for(int technique=0;technique<4;++technique){
        double u=Uniform(rng),v=Uniform(rng),dx,dy,dz;
        if(technique<2){dx=(2*u-1)*c.halfLight-p[0];dy=(2*v-1)*c.halfLight-p[1];dz=2;
            double len=std::sqrt(dx*dx+dy*dy+4);dx/=len;dy/=len;dz/=len;
        }else {double r=std::sqrt(u),phi=2*mis::pi*v;dx=r*std::cos(phi);dy=r*std::sin(phi);dz=std::sqrt(1-u);}
        double qx=p[0]+2*dx/dz,qy=p[1]+2*dy/dz;
        bool inLight=mis::Inside(qx,qy,-c.halfLight,c.halfLight,-c.halfLight,c.halfLight);
        // 灯面采样必然在灯上；浮点重建端点不改变数学支持域。BSDF采样需真正检查范围。
        if(technique<2)inLight=true;
        bool visible=inLight&&!mis::Blocked(p[0],p[1],qx,qy);
        result.diagnostics[technique<2?1:2]+=visible?1:0;
        double pB=dz/mis::pi,pL=inLight?1/(c.halfLight*c.halfLight*dz*dz*dz):0;
        double F=visible?c.rho/mis::pi*c.le*dz:0,own=technique<2?pL:pB,other=technique<2?pB:pL;
        double value=own>0?F/own:0;sums[technique<2?1:0]+=value;
        if(technique==0||technique==2){sums[2]+=mis::Weight(own,other,1)*value;sums[3]+=mis::Weight(own,other,2)*value;}
    }
    for(int k=0;k<4;++k)result.estimates[k]=float(sums[k]/(c.rounds*(k<2?2:1)));
    return result;
}
}
