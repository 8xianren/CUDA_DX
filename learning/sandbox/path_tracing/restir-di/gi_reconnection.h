#pragma once
#include "direct_scene.h"
namespace restir_gi {
using restir_di::V3;
using restir_di::operator+;using restir_di::operator-;using restir_di::operator*;
constexpr double Pi=mis::pi;
inline double Dot(V3 a,V3 b){return a.x*b.x+a.y*b.y+a.z*b.z;}
inline double Length(V3 v){return std::sqrt(Dot(v,v));}
inline V3 Direction(V3 x,V3 y){auto d=y-x;return d*(1/Length(d));}
// 路径为接收点x -> 非发光Lambert次级面y -> 点灯(0,0,.5)。只估计此两次散射路径项。
// 次级面为z=2、[-1,1]^2、朝-Z，反射率.6；点灯标量辐射强度为8。
// 后缀辐亮度是真实点灯照明的解析值，不把次级面伪装成常量自发光灯。
// Lambert使后缀与出射方向无关；任意光泽/镜面表面不满足此假设。
struct Sample {V3 position;double suffixRadiance=0;};
using Reservoir=restir::Reservoir<Sample>;
inline double Suffix(V3 y){double r2=y.x*y.x+y.y*y.y+1.5*1.5;return .6/Pi*8*1.5/(r2*std::sqrt(r2));}
inline Sample Draw(mis::Rng& rng){V3 y{-1+2*rng.Uniform(),-1+2*rng.Uniform(),2};return {y,Suffix(y)};}
// a_x = dω_x/dA = cos(theta_y)/r²。约定x.z<2，次级面法线朝-Z。
inline double AreaToSolidAngle(V3 x,V3 y){auto d=y-x;double r2=Dot(d,d);return (2-x.z)/(r2*std::sqrt(r2));}
// 方向域被积函数包含接收面cos和BRDF，不包含次级面的投影/距离项；后者在dω中。
inline double IntegrandOmega(V3 x,const Sample& y){auto d=y.position-x;return .7/Pi*y.suffixRadiance*d.z/Length(d);}
inline double Jacobian(V3 source,V3 destination,V3 y){return AreaToSolidAngle(destination,y)/AreaToSolidAngle(source,y);}
inline Reservoir Generate(V3 source,unsigned candidates,mis::Rng& rng){
    Reservoir r;
    for(unsigned i=0;i<candidates;++i){auto y=Draw(rng);double a=AreaToSolidAngle(source,y.position);
        // 均匀面积抽样qA=1/4，转换成方向密度qω=qA/a；不是均匀方向抽样。
        double target=IntegrandOmega(source,y);r.Update(y,target,.25/a,rng.Uniform());}
    return r;
}
// 仅供本课双射重连接：样本保留同一个y与Lambert后缀，变的是接收点下的方向测度。
// scale是dμ_destination/dμ_source，必须正且有限。按值复制，不更改来源或共享Merge接口。
// 将W_source乘scale；随后Merge仍按t_destination*W_mapped*M合并。
// 这里没有多对一映射、支持域缺失、delta路径、失败路径筛选或Jacobian截断修正。
inline void MergeMapped(Reservoir& destination,const Reservoir& source,double target,double scale,double u){
    if(!std::isfinite(scale)||scale<=0)throw std::invalid_argument("invalid mapping Jacobian");
    auto mapped=source;mapped.weightSum*=scale;
    if(!std::isfinite(mapped.weightSum))throw std::overflow_error("mapped weight overflow");
    destination.Merge(mapped,target,u);
}
// 独立确定性中点面积求积：直接展开两个Lambert散射与点灯辐射强度，不调用上面的积分函数。
inline double Reference(V3 x,unsigned n){double sum=0,step=2./n,h=2-x.z;
    for(unsigned j=0;j<n;++j)for(unsigned i=0;i<n;++i){double u=-1+(i+.5)*step,v=-1+(j+.5)*step;
        double rl2=u*u+v*v+2.25,rx2=(u-x.x)*(u-x.x)+(v-x.y)*(v-x.y)+h*h;
        sum+=(.7*.6*8*1.5/(Pi*Pi))*(h*h)/(rl2*std::sqrt(rl2)*rx2*rx2)*step*step;}
    return sum;
}
// 负对照自身的确定性期望：错误权重仍收敛，但收敛到错误测度下的积分。
// 漏J得到∫Fω_dst*a_source dA；倒J得到∫Fω_dst*a_source²/a_dst dA。
// 两组按候选数4/16、12/16加权。独立展开，不调用采样/合并/评分函数。
inline double WrongReference(V3 x,const std::array<V3,2>& sources,bool inverse,unsigned n){
    double sum=0,step=2./n,h=2-x.z;
    for(unsigned v=0;v<n;++v)for(unsigned u=0;u<n;++u){double px=-1+(u+.5)*step,py=-1+(v+.5)*step;
        double rLight2=px*px+py*py+2.25,rDest2=(px-x.x)*(px-x.x)+(py-x.y)*(py-x.y)+h*h;
        double f=(.7*.6*8*1.5/(Pi*Pi))*h/(rLight2*std::sqrt(rLight2)*std::sqrt(rDest2));
        double aDest=h/(rDest2*std::sqrt(rDest2));
        for(unsigned k=0;k<2;++k){auto s=sources[k];double hs=2-s.z,rs2=(px-s.x)*(px-s.x)+(py-s.y)*(py-s.y)+hs*hs;
            double aSource=hs/(rs2*std::sqrt(rs2));sum+=f*aSource*(inverse?aSource/aDest:1)*(k?.75:.25)*step*step;}
    }return sum;
}
}
