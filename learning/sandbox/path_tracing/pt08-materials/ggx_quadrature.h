#pragma once
#include "ggx_math.h"
#include <vector>
#include <stdexcept>

namespace ggx {
struct Point {double x,w;};
inline std::vector<Point> Gauss(unsigned n,double lo,double hi){
    // Gauss-Legendre节点/权重：Newton求P_n根。只用于CPU独立数值积分，不参与路径采样。
    std::vector<Point> q(n);
    for(unsigned i=0;i<(n+1)/2;++i){double z=std::cos(Pi*(i+.75)/(n+.5)),dp=0;
        for(unsigned iteration=0;iteration<64;++iteration){double p0=1,p1=z;
            for(unsigned k=2;k<=n;++k){double p=((2*k-1)*z*p1-(k-1)*p0)/k;p0=p1;p1=p;}
            dp=n*(z*p1-p0)/(z*z-1);double next=z-p1/dp;
            if(std::abs(next-z)<2e-15){z=next;break;}z=next;
            if(iteration==63)throw std::runtime_error("Gauss root convergence");
        }
        double weight=(hi-lo)/((1-z*z)*dp*dp),mid=(hi+lo)/2,half=(hi-lo)/2;
        q[i]={mid-half*z,weight};q[n-1-i]={mid+half*z,weight};
    }
    return q;
}
struct Integral {V rgb{};double pdf=0,noMask=0;};
inline Integral Hemisphere(Material material,V wo,unsigned order,unsigned phiCount){
    // 与随机采样器独立：直接在wi.z∈[0,1]、phi∈[0,2pi)上积分，dω=dphi*d(wi.z)。
    // 对粗糙度>=.25的白炉参考使用两个分辨率比较；窄高光另用稳定性和分布归一化测试。
    Integral result;auto nodes=Gauss(order,0,1);
    for(auto point:nodes){double z=point.x,radius=std::sqrt(1-z*z);
        for(unsigned j=0;j<phiCount;++j){double phi=2*Pi*(j+.5)/phiCount;
            V wi{radius*std::cos(phi),radius*std::sin(phi),z},h=Normalize(wo+wi);
            double a=Alpha(material),den=1+(a*a-1)*h.z*h.z;
            // 参考故意使用代数等价的NDF形式和直接sqrt Lambda，不调用Eval/Draw。
            double ndf=a*a/(Pi*den*den);
            auto lambda=[&](V w){return (std::sqrt(1+a*a*(1-w.z*w.z)/(w.z*w.z))-1)/2;};
            double geometry=1/(1+lambda(wo)+lambda(wi)),c=Dot(wo,h);
            double t=std::pow(1-c,5);V fresnel=material.F0+(V{1,1,1}-material.F0)*t;
            double dw=point.w*2*Pi/phiCount;
            result.rgb=result.rgb+fresnel*(ndf*geometry/(4*wo.z)*dw);
            result.pdf+=ndf*h.z/(4*c)*dw;
            result.noMask+=fresnel.x*ndf/(4*wo.z)*dw;
        }
    }
    return result;
}
}
