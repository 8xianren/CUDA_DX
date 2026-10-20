#pragma once
#include "dxr_lighting_reference.h"
#include <filesystem>
#include <limits>
// R.13.6参考层：逐样本double求和独立检查GPU在线平均；少量像素逐帧检查相机/NEE。
// 这里不把2048spp参考图称为真值，也不要求任意像素的单次误差单调下降。
namespace progressive_reference {
using namespace view_reference;
constexpr unsigned Width=160,Height=96,Pixels=Width*Height;
struct Record {lighting_reference::GpuRecord lighting;float meanCount[4],coordinates[4];};
static_assert(sizeof(Record)==192&&offsetof(Record,meanCount)==160,"progressive output layout");
inline double random(unsigned pixel,unsigned sample,unsigned dimension,unsigned seed){
    auto h=lighting_reference::hash;
    uint32_t x=h(pixel^0xa511e9b3u);x=h(x^h(sample+0x63d83595u));
    x=h(x^h(seed+0x9e3779b9u));x=h(x^((dimension+1u)*0x85ebca6bu));
    return ((x>>16)+.5)/65536.;
}
inline Case camera(){Case c;c.w=160;c.h=90;return c;}
inline bool active(unsigned i){return i/Width<90;}
inline bool save(const std::filesystem::path& file,const std::vector<V3>& rgb){
    std::ofstream out(file,std::ios::binary);out<<"PF\n"<<Width<<" "<<Height<<"\n-1.0\n";
    for(unsigned y=Height;y>0;--y)for(unsigned x=0;x<Width;++x){auto p=rgb[(y-1)*Width+x];
        float v[]={float(p.x),float(p.y),float(p.z)};out.write(reinterpret_cast<char*>(v),sizeof(v));}
    out.close();return bool(out);
}
inline V3 tone(V3 x){return {x.x/(1+x.x),x.y/(1+x.y),x.z/(1+x.z)};}
struct Verification {
    unsigned seed,flags,invalid=0,geometryMismatch=0,shadowMismatch=0,checked=0,consumed=0;
    double maxMean=0,maxDirection=0,maxPosition=0,maxSample=0,maxNonlinearGap=0;
    std::vector<V3> sum,displaySum,latest,first;
    std::array<std::vector<V3>,3> checkpoints;
    std::filesystem::path folder;std::string label;
    Verification(unsigned s,unsigned f,std::filesystem::path p,std::string name):seed(s),flags(f),sum(Pixels),displaySum(Pixels),latest(Pixels),first(Pixels),folder(p),label(name){}
    bool consume(const Record* data,unsigned sample){
        // 顺序由宿主槽退役保证；样本序号与Fence值不是同一个概念。
        if(sample!=consumed)++invalid;++consumed;
        static const auto geometry=surface_reference::instances();static const auto triangles=lighting_reference::triangles();
        const auto c=camera();const double tanHalf=std::tan(c.fov*Pi/360),aspect=double(c.w)/c.h;
        unsigned sequence=(flags&1)?0:sample;
        for(unsigned i=0;i<Pixels;++i){const auto& g=data[i];const auto& a=g.lighting.surface;
            if(a.stamp[0]!=i%Width||a.stamp[1]!=i/Width||a.stamp[2]!=sample+1)++invalid;
            for(unsigned k=0;k<4;++k)if(!std::isfinite(g.meanCount[k])||!std::isfinite(g.lighting.direct[k])||!std::isfinite(g.coordinates[k]))++invalid;
            if(!active(i)){if(a.stamp[3]!=0xffffffffu||g.meanCount[3]!=0||length(vec(g.meanCount))!=0)++invalid;continue;}
            if(a.stamp[3]>3||g.meanCount[3]!=sample+1)++invalid;
            double sx=(flags&2)?.5:random(i,sequence,0,seed),sy=(flags&2)?.5:random(i,sequence,1,seed);
            if(g.coordinates[0]!=sx||g.coordinates[1]!=sy||g.coordinates[2]!=random(i,sequence,2,seed)||g.coordinates[3]!=random(i,sequence,3,seed))++invalid;
            V3 value=vec(g.lighting.direct);if(sample==0)first[i]=value;
            if((flags&1)&&length(value-first[i])!=0)++invalid;
            if(flags&4){V3 expected=(sample&1)?V3{4,2,1}:V3{};if(length(value-expected)!=0)++invalid;}
            sum[i]=sum[i]+value;displaySum[i]=displaySum[i]+tone(value);
            latest[i]=vec(g.meanCount);
            maxMean=std::max(maxMean,length(latest[i]-sum[i]*(1./(sample+1))));
            maxNonlinearGap=std::max(maxNonlinearGap,length(tone(latest[i])-displaySum[i]*(1./(sample+1))));
            // 第一个样本全图检查，之后每帧轮转抽取约68个像素；全图均值与四维样本仍逐帧全量检查。
            if((flags&4)||!(sample==0||i%211==sample%211))continue;
            ++checked;
            V3 d=unit(V3{1,(2*(double(i%Width)+sx)/c.w-1)*aspect*tanHalf,(1-2*(double(i/Width)+sy)/c.h)*tanHalf});
            maxDirection=std::max(maxDirection,length(vec(a.directionHit)-d));
            auto hit=surface_reference::closest(c.eye,d,c.nearPlane/d.x,geometry);
            if(a.stamp[3]!=hit.id){++geometryMismatch;continue;}
            if(!hit.id){if(length(value)!=0)++invalid;continue;}
            maxPosition=std::max(maxPosition,length(vec(a.positionT)-hit.point));
            V3 n=vec(a.normalDepth),x=vec(a.positionT),wi;
            V3 q{2+(2*random(i,sequence,2,seed)-1),-.5-(2*random(i,sequence,3,seed)-1),3.5};
            V3 delta=q-x;double r2=dot(delta,delta);wi=delta*(1/std::sqrt(r2));
            double cs=std::max(dot(n,wi),0.),cl=std::max(wi.z,0.);V3 expected{};bool visible=false;
            if(cs>0&&cl>0&&dot(n,vec(a.directionHit)*-1)>0){
                V3 origin{float(a.positionT[0]+.0001f*a.normalDepth[0]),float(a.positionT[1]+.0001f*a.normalDepth[1]),float(a.positionT[2]+.0001f*a.normalDepth[2])};
                visible=lighting_reference::visible(origin,q,triangles);
                if(visible){V3 rho=lighting_reference::albedo(hit.id);double weight=cs*cl*4/(Pi*r2);expected={12*rho.x*weight,11*rho.y*weight,9*rho.z*weight};}
            }
            if(g.lighting.direct[3]!=unsigned(visible))++shadowMismatch;
            maxSample=std::max(maxSample,length(value-expected));
        }
        unsigned n=sample+1;
        if(n==1||n==16||n==256){unsigned slot=n==1?0:n==16?1:2;checkpoints[slot]=latest;
            if(!save(folder/(label+"_"+std::to_string(n)+"spp.pfm"),latest))++invalid;
        }
        return invalid==0;
    }
    bool finish(){
        bool pass=invalid==0&&geometryMismatch==0&&shadowMismatch==0&&maxMean<1e-5&&maxDirection<1e-5&&maxPosition<1e-4&&maxSample<1e-5;
        if((flags&4)&&consumed%2==0){for(unsigned i=0;i<Pixels;++i)if(active(i)&&length(latest[i]-V3{2,1,.5})>1e-6)pass=false;}
        std::printf("%-15s spp=%u checked=%u invalid=%u geometry=%u shadow=%u mean=%.3g dir=%.3g pos=%.3g sample=%.3g nonlinearGap=%.6g %s\n",
          label.c_str(),consumed,checked,invalid,geometryMismatch,shadowMismatch,maxMean,maxDirection,maxPosition,maxSample,maxNonlinearGap,pass?"PASS":"FAIL");
        return pass;
    }
};
inline double mse(const std::vector<V3>& a,const std::vector<V3>& b){double sum=0;unsigned count=0;
    for(unsigned i=0;i<Pixels;++i)if(active(i)){V3 delta=a[i]-b[i];sum+=dot(delta,delta);count+=3;}return sum/count;}
} // namespace progressive_reference
