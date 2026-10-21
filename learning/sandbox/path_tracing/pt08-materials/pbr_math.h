#pragma once
#include "ggx_math.h"
namespace pbr {
using ggx::V;
struct Material {V base;double metallic,roughness;};
inline V Product(V a,V b){return {a.x*b.x,a.y*b.y,a.z*b.z};}
inline V F0(Material p){return V{.04,.04,.04}*(1-p.metallic)+p.base*p.metallic;}
inline double SpecProbability(Material p,unsigned mode){
    // 这是采样策略，不是metallic物理混合系数。没有漫反射时只用GGX，其他情况比较两种概率。
    return p.metallic==1||p.base.x+p.base.y+p.base.z==0?1:(mode==0?.5:.8);
}
struct Evaluation {V f{},diffuse{},specular{};double pdf=0,specPdf=0,diffPdf=0;};
inline Evaluation Eval(Material p,V wo,V wi,unsigned mode){
    Evaluation e;if(wo.z<=0||wi.z<=0)return e;
    V h=ggx::Normalize(wo+wi);double cosine=ggx::Dot(wo,h);
    auto spec=ggx::Eval({p.roughness,F0(p)},wo,wi);
    // 按glTF“先构造非金属/金属，再按metallic线性混合”的图计算。
    // 非金属漫反射的Fresnel使用固定F0=.04，不把金属颜色混入这个门控项。
    // 此方向相关漫反射耦合是教学基线，不保证完整白炉守恒；验收会量化其误差。
    double dielectricF=ggx::Schlick({.04,.04,.04},cosine).x;
    e.diffuse=p.base*((1-p.metallic)*(1-dielectricF)/ggx::Pi);e.specular=spec.f;e.f=e.diffuse+e.specular;
    double ps=SpecProbability(p,mode);e.diffPdf=wi.z/ggx::Pi;e.specPdf=spec.pdf;
    e.pdf=ps*e.specPdf+(1-ps)*e.diffPdf;return e;
}
}
