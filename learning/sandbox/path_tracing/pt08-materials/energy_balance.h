#pragma once
#include "pbr_math.h"
#include <vector>
#include <stdexcept>

namespace energy {
// 本节一条曲线对应一个确切roughness；没有粗糙度维插值，也不把这五条验证曲线冒充通用GPU LUT。
// values[j]是E_s(cos=(j/(N-1))²)，含两个端点；掠射端加密以解析更快的变化。
// 查找区间用sqrt(cos)，但区间内部按实际cos线性插值。Row按值拥有CPU存储。
struct Row {
    double roughness=0,average=0;
    std::vector<double> values;
    double At(double cosine) const {
        if(!std::isfinite(cosine)||cosine<0||cosine>1)throw std::runtime_error("invalid cosine");
        if(roughness*roughness<=ggx::DeltaAlpha)return .04+.96*std::pow(1-cosine,5);
        if(values.size()<2)throw std::runtime_error("missing energy row");
        double x=std::sqrt(cosine)*(values.size()-1);size_t j=std::min(size_t(x),values.size()-2);
        double u0=double(j)/(values.size()-1),u1=double(j+1)/(values.size()-1);
        double t=(cosine-u0*u0)/(u1*u1-u0*u0);return values[j]*(1-t)+values[j+1]*t;
    }
    void Normalize(){
        // Eavg=2∫E(c)c dc。对实际使用的分段线性函数逐段精确积分，而非另存一份不匹配的拟合值。
        // 如果用真实E计算average，却用粗查表E计算两侧因子，白炉归一化会额外产生不一致。
        if(roughness*roughness<=ggx::DeltaAlpha){average=.04+.96/21.;return;}
        if(values.size()<2)throw std::runtime_error("missing energy row");
        average=0;
        for(size_t j=0;j+1<values.size();++j){double u0=double(j)/(values.size()-1),u1=double(j+1)/(values.size()-1);
            double c=u0*u0,h=u1*u1-c,e=values[j],delta=values[j+1]-e;
            if(!std::isfinite(e)||e<0||e>1||!std::isfinite(values[j+1])||values[j+1]<0||values[j+1]>1)
                throw std::runtime_error("energy row outside [0,1]");
            average+=2*h*(e*c+(e*h+delta*c)/2+delta*h/3);
        }
        if(!(average>=0&&average<1))throw std::runtime_error("invalid average energy");
    }
};
inline pbr::Evaluation Eval(pbr::Material material,ggx::V wo,ggx::V wi,unsigned mode,const Row& row){
    // 沿用原镜面、混合PDF、delta约定，只替换漫反射闭合项。
    // B的含义是“剩余能量返回的比例”；不是完整折射层内多次散射的精确解。
    // 必须匹配roughness，否则一个表面会用另一个表面的E去补偿，破坏能量预算。
    if(material.roughness!=row.roughness||!(row.average>=0&&row.average<1))throw std::runtime_error("energy/material mismatch");
    auto e=pbr::Eval(material,wo,wi,mode);if(wo.z<=0||wi.z<=0)return e;
    double factor=(1-row.At(wo.z))*(1-row.At(wi.z))/(ggx::Pi*(1-row.average));
    e.diffuse=material.base*((1-material.metallic)*factor);e.f=e.specular+e.diffuse;return e;
}
}
