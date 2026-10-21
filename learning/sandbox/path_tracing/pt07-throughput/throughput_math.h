#pragma once
#include "../pt06-mis/mis_math.h" // 复用已验收的PCG与pi，不复制随机数实现。
#include <array>
#include <stdexcept>
namespace throughput {
using RGB=std::array<double,3>; // 三个线性通道；吞吐量逐分量相乘，不取RGB平均。
struct Vec {double x,y,z;};
inline Vec operator+(Vec a,Vec b){return {a.x+b.x,a.y+b.y,a.z+b.z};}
inline Vec operator*(Vec a,double s){return {a.x*s,a.y*s,a.z*s};}
inline double Dot(Vec a,Vec b){return a.x*b.x+a.y*b.y+a.z*b.z;}
inline Vec Cross(Vec a,Vec b){return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
inline Vec Unit(Vec a){double length=std::sqrt(Dot(a,a));if(!(length>0))throw std::runtime_error("zero vector");return a*(1/length);}
struct DirectionSample {Vec wi;double cosine,pdf;};
inline DirectionSample Sample(Vec normal,mis::Rng& rng,bool cosineSampling){
    double u=rng.Uniform(),v=rng.Uniform();
    // 均匀半球：z=u，p=1/(2pi)；余弦半球：z=sqrt(1-u)，p=z/pi。
    double z=cosineSampling?std::sqrt(1-u):u,r=std::sqrt(std::max(0.,1-z*z)),phi=2*mis::pi*v;
    // 为每个新命中点重新构造正交基。选择不与normal近乎平行的辅助轴，避免叉积退化。
    Vec helper=std::abs(normal.z)<.9?Vec{0,0,1}:Vec{0,1,0};
    Vec tangent=Unit(Cross(helper,normal)),bitangent=Cross(normal,tangent);
    Vec direction=Unit(tangent*(r*std::cos(phi))+bitangent*(r*std::sin(phi))+normal*z);
    double cosine=Dot(normal,direction);
    if(!(cosine>0))throw std::runtime_error("sample outside inward hemisphere");
    return {direction,cosine,cosineSampling?cosine/mis::pi:1/(2*mis::pi)};
}
inline Vec NextSphereHit(Vec position,Vec direction,double& distance,double& residual){
    // 单位球面|x|=1，单位方向|d|=1：|x+td|²=1 → t(t+2x·d)=0。
    // 起点自身对应t=0；沿球腔内向半球前进，另一个交点t=-2x·d>0。
    // 这是仅适用于“起点已在球上”的解析求交，不是通用球/三角形偏移实现。
    distance=-2*Dot(position,direction);
    if(!(distance>0))throw std::runtime_error("invalid next sphere intersection");
    Vec hit=position+direction*distance;residual=std::abs(Dot(hit,hit)-1);
    // 投影回单位球消除多次double运算积累的小误差；先记录残差，避免掩盖求交错误。
    if(residual>1e-10)throw std::runtime_error("sphere intersection residual");
    return Unit(hit);
}
inline RGB Analytic(RGB rho,RGB emission,int maxScatters){
    RGB result{};
    for(int c=0;c<3;++c)result[c]=emission[c]*(1-std::pow(rho[c],maxScatters+1))/(1-rho[c]);
    return result;
}
}
