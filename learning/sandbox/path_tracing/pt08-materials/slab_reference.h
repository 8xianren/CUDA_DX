#pragma once
#include "dielectric_math.h"
#include <cstdint>
#include <cstddef>
#include <stdexcept>
#include <algorithm>
#include <string>

namespace slab {
// 这些是CPU/GPU交换结构，不含指针。Record=32+16*80=1312B；布局由编译期断言锁定。
struct Config {
    uint32_t width=64,height=64,topID=0,bottomID=0;
    uint32_t upperID=0,lowerID=0,seed=0,mode=0;
    uint32_t maxScatter=8,startInside=0,disableOffset=0,pad1=0;
    float parameters[4]{0,1,1,1.5f},upperLe[4]{},lowerLe[4]{};
};
struct Step {float position[4],direction[4],state[4],probability[4];uint32_t ids[4];};
struct Record {float radiance[4];uint32_t status[4];Step steps[16];};
static_assert(sizeof(Config)==96&&offsetof(Config,parameters)==48);
static_assert(sizeof(Step)==80&&sizeof(Record)==1312&&offsetof(Record,steps)==32);
inline void Require(bool v,const char* what){if(!v)throw std::runtime_error(what);}
struct Moment {
    uint64_t n=0;double mean=0,m2=0;
    void Add(double x){double d=x-mean;mean+=d/++n;m2+=d*(x-mean);}
    double SE()const{return n>1?std::sqrt(m2/(n-1)/n):0;}
};
inline double Random(uint32_t index,uint32_t seed,uint32_t depth){
    uint32_t x=(index+1)*747796405u+seed*2891336453u+depth*277803737u+0x9e3779b9u;
    x=(x^(x>>16))*0x21f0aaadu;x=(x^(x>>15))*0x735a2d97u;x^=x>>15;
    return ((x>>9)+.5)/8388608.;
}
struct V {double x,y,z;};
struct Hit {uint32_t id=0;double t=1000,z=0;};
inline Hit Intersect(const Config& c,V o,V d){
    // CPU独立对四个矩形做解析求交，不读取GPU输出决定下一个几何命中。
    Hit best;double zs[]{0,-1,2,-3};uint32_t ids[]{c.topID,c.bottomID,c.upperID,c.lowerID};
    for(int j=0;j<4;++j){double t=(zs[j]-o.z)/d.z;
        if(t>=1e-5&&t<best.t&&std::abs(o.x+t*d.x)<256&&std::abs(o.y+t*d.y)<256)best={ids[j],t,zs[j]};}
    return best;
}
inline double Audit(const Config& c,uint32_t index,const Record& r){
    double maximum=0;
    auto checkNear=[&](double got,double expected,double tolerance=3e-5){double e=std::abs(got-expected);
        if(!std::isfinite(got)||e>=tolerance)throw std::runtime_error("CPU/GPU slab numeric mismatch index="+std::to_string(index)+
            " got="+std::to_string(got)+" expected="+std::to_string(expected)+" difference="+std::to_string(e));
        maximum=std::max(maximum,e);};
    double len=std::sqrt(1+double(c.parameters[0])*c.parameters[0]);
    V o{(index%c.width+.5)/c.width-.5,(index/c.width+.5)/c.height-.5,c.parameters[1]};
    V d{c.parameters[0]/len,0,-1/len};uint32_t inside=c.startInside,scatters=0,rays=0,end=0;
    double beta=1,etaScale=1,L[3]{};
    for(uint32_t depth=0;depth<=c.maxScatter;++depth){
        Hit hit=Intersect(c,o,d);++rays;Require(hit.id!=0,"reference missed finite fixture");
        if(hit.id==c.upperID||hit.id==c.lowerID){end=hit.id==c.upperID?1:2;
            Require(inside==0,"reference lamp inside glass");auto le=end==1?c.upperLe:c.lowerLe;
            for(int k=0;k<3;++k)L[k]=beta*le[k];break;}
        if(depth==c.maxScatter){end=3;break;}
        const Step& s=r.steps[depth];bool top=hit.id==c.topID;double ngz=top?1:-1;
        bool entering=d.z*ngz<0;Require(entering!=(inside!=0),"reference medium inconsistent");
        double ni=inside?c.parameters[3]:c.parameters[2],nt=inside?c.parameters[2]:c.parameters[3];
        double q=ni/nt,q2=q*q;auto f=dielectric::Evaluate(std::abs(d.z),ni,nt);Require(f.valid,"reference Fresnel invalid");
        double pr=f.F<=0?0:(f.F>=1?1:(c.mode==1?.5:f.F)),u=Random(index,c.seed,depth);
        checkNear(s.probability[0],u);checkNear(s.probability[1],pr);checkNear(s.probability[2],f.F);
        // 先独立检查概率，再用GPU实际float阈值复核所选事件，消除概率阈值舍入假阳性。
        bool reflected=u<s.probability[1];uint32_t event=reflected?1:2,before=inside;
        double mass=reflected?s.probability[1]:1-s.probability[1];Require(mass>0,"zero event mass");
        double weight=reflected?s.probability[2]/mass:(1-s.probability[2])*q2/mass;
        o={o.x+hit.t*d.x,o.y+hit.t*d.y,hit.z};
        // DXR的RayTCurrent为float近似，重建x会跨16次命中累积误差；固定尺度几何阈值5e-4。
        // 此容差仅用于位置/距离，不放宽方向、概率、吞吐量的3e-5阈值，也不是通用硬件误差界。
        checkNear(s.position[0],o.x,5e-4);checkNear(s.position[1],o.y,5e-4);checkNear(s.position[2],o.z,5e-4);checkNear(s.position[3],hit.t,5e-4);
        if(reflected)d.z=-d.z;
        else {d={q*d.x,q*d.y,(d.z>0?1:-1)*f.cosT};inside=1-inside;etaScale/=q2;}
        beta*=weight;++scatters;
        checkNear(s.direction[0],d.x);checkNear(s.direction[1],d.y);checkNear(s.direction[2],d.z);checkNear(s.direction[3],ni);
        checkNear(s.state[0],beta);checkNear(s.state[1],etaScale);checkNear(s.state[2],weight);checkNear(s.state[3],q2);checkNear(s.probability[3],mass);
        Require(s.ids[0]==hit.id&&s.ids[1]==event&&s.ids[2]==before&&s.ids[3]==inside,"hit/event/medium mismatch");
        // etaScale是RR用的辅助量，本课只审计其累计值，绝不将它乘进最终辐亮度。
        if(!c.disableOffset)o.z+=(d.z>0?1:-1)/1024.;
    }
    if(r.status[0]!=end||r.status[1]!=scatters||r.status[2]!=rays||r.status[3]!=inside)
        throw std::runtime_error("termination/count mismatch index="+std::to_string(index)+" seed="+std::to_string(c.seed)+
            " GPU="+std::to_string(r.status[0])+","+std::to_string(r.status[1])+","+std::to_string(r.status[2])+","+std::to_string(r.status[3])+
            " CPU="+std::to_string(end)+","+std::to_string(scatters)+","+std::to_string(rays)+","+std::to_string(inside));
    for(int k=0;k<3;++k)checkNear(r.radiance[k],L[k]);checkNear(r.radiance[3],beta);
    return maximum;
}
struct Target {double rgb[3]{},upper=0,lower=0,tail=0,F=0;};
inline Target Analytic(const Config& c){
    // 此参考按路径族求有限几何级数，不使用任何随机数或GPU轨迹。
    // 平行板、同外IOR、无吸收、标量非偏振Fresnel，每次界面使用相同F；有限面边缘须另行Audit。
    Target t;double ci=1/std::sqrt(1+double(c.parameters[0])*c.parameters[0]);
    double ni=c.startInside?c.parameters[3]:c.parameters[2],nt=c.startInside?c.parameters[2]:c.parameters[3];
    t.F=dielectric::Evaluate(ci,ni,nt).F;
    if(!c.startInside){
        t.upper=t.F;
        for(uint32_t j=1;j<c.maxScatter;++j){double w=(1-t.F)*(1-t.F)*std::pow(t.F,int(j)-1);
            (j%2?t.lower:t.upper)+=w;}
        t.tail=(1-t.F)*std::pow(t.F,int(c.maxScatter)-1);
    }else{
        double q=ni/nt;
        for(uint32_t j=1;j<=c.maxScatter;++j){double w=(1-t.F)*q*q*std::pow(t.F,int(j)-1);
            (j%2?t.lower:t.upper)+=w;}
        // tail表示未逃逸的物理分支概率，不是missing RGB（内外Radiance有q²换算）。
        t.tail=std::pow(t.F,int(c.maxScatter));
    }
    for(int k=0;k<3;++k)t.rgb[k]=t.upper*c.upperLe[k]+t.lower*c.lowerLe[k];
    return t;
}
}
