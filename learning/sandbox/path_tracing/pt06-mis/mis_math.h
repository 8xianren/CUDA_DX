#pragma once
#include <cmath>
#include <cstdint>
#include <algorithm>
namespace mis {
constexpr double pi=3.14159265358979323846;
// 一条样本在多策略估计器中的权重。输入必须是同一测度、同一方向下的PDF。
// 这里每策略样本数相同，所以n约掉；推广时传入n_i*p_i，而不是仅p_i。
inline double Weight(double own,double other,int exponent){
    if(own<=0)return 0;
    // 先缩放避免直接平方大PDF溢出；zero/zero贡献由调用者视为0。
    double scale=std::max(own,other),a=own/scale,b=other/scale;
    if(exponent==2){a*=a;b*=b;}return a/(a+b);
}
// 确定性PCG：每像素/每种子各自流，禁止把连续帧错误地当作完全独立重复实验。
struct Rng {
    uint64_t state=0,inc;
    explicit Rng(uint64_t seed,uint64_t stream):inc((stream<<1)|1){Next();state+=seed;Next();}
    uint32_t Next(){uint64_t old=state;state=old*6364136223846793005ULL+inc;
        uint32_t x=uint32_t(((old>>18)^old)>>27),r=uint32_t(old>>59);return (x>>r)|(x<<((-r)&31));}
    double Uniform(){return (Next()+.5)/4294967296.;}
};
// 固定测试几何：receiver z=0,+Z法线；面积灯z=2，范围[-h,h]^2，朝-Z。
// blocker z=1，x∈[0,.5]、y∈[-.4,.4]。所有数字与生成glTF保持一致。
inline bool Inside(double x,double y,double xmin,double xmax,double ymin,double ymax){return x>=xmin&&x<=xmax&&y>=ymin&&y<=ymax;}
inline bool Blocked(double x,double y,double qx,double qy){return Inside((x+qx)*.5,(y+qy)*.5,0,.5,-.4,.4);}
// 独立面积中点求积，不复用蒙特卡洛随机序列。f=rho/pi，cos_x=cos_l=2/r。
inline double Reference(double x,double y,double h,double rho,double le,int resolution){
    double sum=0,area=4*h*h;
    for(int j=0;j<resolution;++j)for(int i=0;i<resolution;++i){
        double qx=-h+2*h*(i+.5)/resolution,qy=-h+2*h*(j+.5)/resolution;
        double r2=(qx-x)*(qx-x)+(qy-y)*(qy-y)+4;
        if(!Blocked(x,y,qx,qy))sum+=rho/pi*le*4/(r2*r2);
    }
    return sum*area/(resolution*resolution);
}
}
