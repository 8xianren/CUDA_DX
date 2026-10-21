#pragma once
#include "reservoir.h"
#include "../pt06-mis/mis_math.h"
#include <array>
#include <vector>
namespace restir_di {
constexpr double Pi=mis::pi;
struct V3 {double x=0,y=0,z=0;};
inline V3 operator+(V3 a,V3 b){return {a.x+b.x,a.y+b.y,a.z+b.z};}
inline V3 operator-(V3 a,V3 b){return {a.x-b.x,a.y-b.y,a.z-b.z};}
inline V3 operator*(V3 a,double b){return {a.x*b,a.y*b,a.z*b};}
inline double Luma(V3 a){return .2126*a.x+.7152*a.y+.0722*a.z;}
struct RectLight {double xmin,xmax,ymin,ymax;V3 emission;double Area()const{return (xmax-xmin)*(ymax-ymin);}};
struct Scene {
    // receiver位于z=0，法线+Z；所有灯位于z=2，法线-Z，互不重叠。
    std::array<RectLight,3> lights{{{-1.6,-.8,-.4,.4,{1,.4,.2}},
                                  {-.5,.5,-.5,.5,{4,8,2}},
                                  {.8,1.6,-.4,.4,{25,8,4}}}};
    bool blocker=true;double bx0=.1,bx1=.65,by0=-.35,by1=.35;
    double rho=.7; // 无纹理、非delta Lambert灰色反射率，输出仍为RGB。
};
struct LightSample {uint32_t light=0;double u=0,v=0;};
struct Evaluation {V3 unshadowed;double proposal=0,target=0,bsdfAreaPdf=0;};
inline V3 Position(const Scene& s,LightSample y){auto& l=s.lights.at(y.light);return {l.xmin+(l.xmax-l.xmin)*y.u,l.ymin+(l.ymax-l.ymin)*y.v,2};}
inline LightSample Draw(const Scene& s,mis::Rng& rng){double choose=rng.Uniform();auto id=uint32_t(choose*s.lights.size());return {id,rng.Uniform(),rng.Uniform()};}
inline Evaluation Evaluate(const Scene& s,V3 x,LightSample y){
    // 面积测度：F_A=Le*(rho/pi)*cosX*cosL/r²。两平面间距2，cosX=cosL=2/r。
    // 因此几何项为4/r^4。选灯均匀，再均匀采面积，q_A=1/(灯数*面积)。
    auto p=Position(s,y);double dx=p.x-x.x,dy=p.y-x.y,r2=dx*dx+dy*dy+4;
    double geometry=4/(r2*r2);V3 f=s.lights[y.light].emission*(s.rho/Pi*geometry);
    // 余弦BSDF的q_omega=cosX/pi，转换到面积q_A=q_omega*cosL/r²=geometry/pi。
    return {f,1/(s.lights.size()*s.lights[y.light].Area()),Luma(f),geometry/Pi};
}
inline bool Visible(const Scene& s,V3 x,LightSample y){
    if(!s.blocker)return true;auto p=Position(s,y);
    // 线段从z=0到2，在遮挡板z=1处参数恰为1/2。这里只处理这套解析平面几何，
    // 无需任意epsilon，不宣称是通用mesh/BVH可见性接口；板确实在两个端点之间。
    double hx=(x.x+p.x)*.5,hy=(x.y+p.y)*.5;
    return !mis::Inside(hx,hy,s.bx0,s.bx1,s.by0,s.by1);
}
inline V3 BsdfSample(const Scene& s,V3 x,mis::Rng& rng,bool useMis){
    double u=rng.Uniform(),phi=2*Pi*rng.Uniform(),z=std::sqrt(1-u);
    double hx=x.x+2*std::sqrt(u)*std::cos(phi)/z,hy=x.y+2*std::sqrt(u)*std::sin(phi)/z;
    for(uint32_t i=0;i<s.lights.size();++i){auto& l=s.lights[i];if(mis::Inside(hx,hy,l.xmin,l.xmax,l.ymin,l.ymax)){
        LightSample y{i,(hx-l.xmin)/(l.xmax-l.xmin),(hy-l.ymin)/(l.ymax-l.ymin)};
        if(!Visible(s,x,y))return {};auto e=Evaluate(s,x,y);
        // Lambert*cos与余弦PDF抵消；MIS比较两种同面积测度PDF，单策略各1样本。
        double w=useMis?mis::Weight(e.bsdfAreaPdf,e.proposal,2):1;return l.emission*(s.rho*w);
    }}return {}; // 未命中任何灯时是零贡献，不能丢掉这次样本的计数。
}
inline V3 Reference(const Scene& s,V3 x,unsigned resolution){
    V3 result{};
    // 独立确定性面积求积：将遮挡投影边界切入灯矩形，子矩形内可见性恒定。
    // 不调用Evaluate/Visible，也不复用MC样本；升分辨率比较仍只是数值误差诊断，非严格误差上界。
    for(const auto& l:s.lights){std::vector<double> xs{l.xmin,l.xmax},ys{l.ymin,l.ymax};
        if(s.blocker){for(double b:{2*s.bx0-x.x,2*s.bx1-x.x})if(b>l.xmin&&b<l.xmax)xs.push_back(b);
            for(double b:{2*s.by0-x.y,2*s.by1-x.y})if(b>l.ymin&&b<l.ymax)ys.push_back(b);}
        std::sort(xs.begin(),xs.end());std::sort(ys.begin(),ys.end());
        for(size_t a=1;a<xs.size();++a)for(size_t b=1;b<ys.size();++b){double cx=(xs[a]+xs[a-1])*.5,cy=(ys[b]+ys[b-1])*.5;
            bool hidden=s.blocker&&cx>=2*s.bx0-x.x&&cx<=2*s.bx1-x.x&&cy>=2*s.by0-x.y&&cy<=2*s.by1-x.y;if(hidden)continue;
            double dx=(xs[a]-xs[a-1])/resolution,dy=(ys[b]-ys[b-1])/resolution;
            for(unsigned j=0;j<resolution;++j)for(unsigned i=0;i<resolution;++i){double px=xs[a-1]+(i+.5)*dx-x.x,py=ys[b-1]+(j+.5)*dy-x.y;
                double d=px*px+py*py+4;result=result+l.emission*(s.rho/Pi*4/(d*d)*dx*dy);}
        }
    }return result;
}
constexpr unsigned Methods=6;
inline std::array<V3,Methods> Trial(const Scene& s,V3 x,mis::Rng& rng){
    // 共用候选以控制差异；NEE8为完整评估8候选的参考，RIS只需最终一个可见性。
    // 此验证程序同时计算全部方法，并不据运行总耗时报告单方法速度。
    std::array<V3,Methods> values{};restir::Reservoir<LightSample> r;V3 sum{},lightMis{};
    for(unsigned k=0;k<8;++k){auto y=Draw(s,rng);auto e=Evaluate(s,x,y);V3 f=Visible(s,x,y)?e.unshadowed:V3{};sum=sum+f*(1/e.proposal);
        if(k==0){values[0]=f*(1/e.proposal);lightMis=values[0]*mis::Weight(e.proposal,e.bsdfAreaPdf,2);}
        r.Update(y,e.target,e.proposal,rng.Uniform());}
    // 单独BSDF与MIS使用不同随机抽样；MIS两项求和，不再乘1/2。
    values[1]=BsdfSample(s,x,rng,false);values[2]=lightMis+BsdfSample(s,x,rng,true);values[3]=sum*(1./8);
    if(r.valid){auto e=Evaluate(s,x,r.sample);values[5]=e.unshadowed*r.Normalization();values[4]=Visible(s,x,r.sample)?values[5]:V3{};}
    return values;
}
}
