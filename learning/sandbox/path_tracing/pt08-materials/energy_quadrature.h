#pragma once
#include "ggx_quadrature.h"

// 只在CPU离线构表时使用；与路径采样器、GPU执行以及最终的线性查表相互独立。
namespace energy {
struct Basis {double scale=0,schlick=0;};
struct Reference {Basis basis;double change=0;unsigned order=0;};
inline double Dielectric(Basis b){return .04*(b.scale-b.schlick)+b.schlick;}
inline ggx::V Colored(Basis b,ggx::V f0){return f0*(b.scale-b.schlick)+ggx::V{1,1,1}*b.schlick;}
inline Basis Integrate(double roughness,double co,unsigned order){
    // 各向同性允许固定wo=(sqrt(1-co²),0,co)，并用关于XZ平面的对称性将phi积分减半。
    // dω=dphi*dci；这里两轴均用Gauss-Legendre，不调用Eval、Draw或查表函数。
    // scale积分F=1的单次GGX；schlick积分(1-wo·h)^5。任意F0的E可线性组合得到。
    if(roughness*roughness<=ggx::DeltaAlpha)return {1,std::pow(1-co,5)};
    auto zNodes=ggx::Gauss(order,0,1),phiNodes=ggx::Gauss(order,0,ggx::Pi);
    for(auto& p:phiNodes)p.x=std::cos(p.x);
    const double a=roughness*roughness,a2=a*a,so=std::sqrt(1-co*co);
    const double rootO=std::sqrt(co*co+a2*(1-co*co));Basis result;
    for(auto z:zNodes){const double ci=z.x,si=std::sqrt(1-ci*ci);
        // G/(4co)=1/[2(sqrt(co²+a²so²)+co*sqrt(ci²+a²si²)/ci)]。
        // 该等价形式在co=0仍有有限极限；不能先算G=0再除以co=0。
        const double projected=1/(2*(rootO+co*std::sqrt(ci*ci+a2*si*si)/ci));
        for(auto phi:phiNodes){double oi=so*si*phi.x+co*ci;
            double hLen2=2*(1+oi),hz=(co+ci)/std::sqrt(hLen2);
            double oh=std::sqrt((1+oi)/2),den=1+(a2-1)*hz*hz;
            double d=a2/(ggx::Pi*den*den),w=d*projected*z.w*phi.w*2;
            result.scale+=w;result.schlick+=w*std::pow(1-oh,5);
        }
    }return result;
}
inline Reference Converged(double roughness,double co){
    if(!std::isfinite(roughness)||roughness<0||roughness>1||!std::isfinite(co)||co<0||co>1)
        throw std::runtime_error("invalid energy integral input");
    if(roughness*roughness<=ggx::DeltaAlpha)return {Integrate(roughness,co,1),0,0};
    Basis previous=Integrate(roughness,co,128);
    for(unsigned n=256;n<=2048;n*=2){Basis next=Integrate(roughness,co,n);
        double change=std::max(std::abs(next.scale-previous.scale),std::abs(next.schlick-previous.schlick));
        if(change<2e-7)return {next,change,n};previous=next;
    }
    // 相邻分辨率一致性是实测收敛检查，不是严格积分误差上界。未收敛直接失败，不钳制能量掩盖。
    throw std::runtime_error("energy quadrature did not converge by order 2048");
}
}
