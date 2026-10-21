#pragma once
#include "ggx_math.h"
#include <vector>

// Heitz 2018可见法线参数化，只用于离线能量积分。路径追踪器仍用之前的NDF/余弦混合采样。
// 半球投影采样的几何步骤：拉伸观察方向→投影圆盘→可见半球→按法线变换回GGX椭球。
namespace vndf {
struct Disk {double x,y;};
inline std::vector<Disk> Points(unsigned count,unsigned scramble=0){
    std::vector<Disk> points(count);
    for(unsigned i=0;i<count;++i){unsigned bits=i^scramble;
        bits=(bits<<16)|(bits>>16);bits=((bits&0x55555555u)<<1)|((bits&0xaaaaaaaau)>>1);
        bits=((bits&0x33333333u)<<2)|((bits&0xccccccccu)>>2);bits=((bits&0x0f0f0f0fu)<<4)|((bits&0xf0f0f0f0u)>>4);
        bits=((bits&0x00ff00ffu)<<8)|((bits&0xff00ff00u)>>8);
        double radius=std::sqrt((i+.5)/count),phi=2*ggx::Pi*((double(bits)+.5)/4294967296.);
        points[i]={radius*std::cos(phi),radius*std::sin(phi)};
    }return points;
}
inline double Integral(double alpha,double co,const std::vector<Disk>& points){
    double so=std::sqrt(std::max(0.,1-co*co)),length=std::sqrt(alpha*alpha*so*so+co*co);
    double vhx=alpha*so/length,vhz=co/length,s=.5*(1+vhz),sum=0;
    // 固定wo在XZ面：T1=+Y，T2=(-Vh.z,0,Vh.x)。正视时同样可选这个正交基。
    for(auto p:points){double y=(1-s)*std::sqrt(std::max(0.,1-p.x*p.x))+s*p.y;
        double z=std::sqrt(std::max(0.,1-p.x*p.x-y*y));
        double hx=alpha*(-vhz*y+vhx*z),hy=alpha*p.x,hz=std::max(0.,vhx*y+vhz*z);
        double inv=1/std::sqrt(hx*hx+hy*hy+hz*hz);hx*=inv;hz*=inv;
        double oh=so*hx+co*hz,ci=2*oh*hz-co;if(ci<=0)continue;
        double rootI=std::sqrt(ci*ci+alpha*alpha*std::max(0.,1-ci*ci));
        // p_h=D*G1(wo)*(wo·h)/co；反射Jacobian使f*ci/p_i=F*G/G1。
        // 高度相关G/G1=(co+rootO)/(rootO+co*rootI/ci)，co=0也有有限极限1。
        double ratio=(co+length)/(length+co*rootI/ci),t=std::clamp(1-oh,0.,1.);
        sum+=(.04+.96*t*t*t*t*t)*ratio;
    }
    // 无效反射方向贡献0，分母仍为全部点数；没有重抽或按有效点重新归一化。
    return sum/points.size();
}
}
