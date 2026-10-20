#pragma once
#include "dxr_history_policy.h"
// R.13.7的独立验收：期望reset/计数由测试场景指定，不从被测Tracker推导。
// 全量检查平均、坐标与计数；每段第一帧全量查几何/NEE，其余轮转抽查。
namespace history_reference {
using namespace view_reference;
namespace pr=progressive_reference;
inline bool active(unsigned i,const Case& c){unsigned x=i%pr::Width,y=i/pr::Width;return x>=c.x&&y>=c.y&&x<c.x+c.w&&y<c.y+c.h;}
struct Verify {
    std::vector<V3> sum=std::vector<V3>(pr::Pixels),latest=std::vector<V3>(pr::Pixels);
    unsigned invalid=0,geometryMismatch=0,shadowMismatch=0,checked=0,frames=0;
    double meanError=0,positionError=0,directionError=0,sampleError=0;
    void consume(const pr::Record* data,const RaySubmission& frame,const history_policy::Settings& s,unsigned expectedCount,bool expectedReset,bool fullCheck){
        ++frames;if(expectedReset)std::fill(sum.begin(),sum.end(),V3{});
        static const auto scene=surface_reference::instances();static const auto triangles=lighting_reference::triangles();
        const auto& c=s.camera;V3 f=unit(c.forward),r=unit(cross({0,0,1},f)),u=cross(f,r);
        double tangent=std::tan(c.fov*Pi/360),aspect=double(c.w)/c.h;
        unsigned sample=frame.controls[0];
        for(unsigned i=0;i<pr::Pixels;++i){const auto& g=data[i];const auto& a=g.lighting.surface;
            if(a.stamp[0]!=i%pr::Width||a.stamp[1]!=i/pr::Width||a.stamp[2]!=frame.view.targetInfo[2])++invalid;
            for(unsigned k=0;k<4;++k)if(!std::isfinite(g.meanCount[k])||!std::isfinite(g.lighting.direct[k])||!std::isfinite(g.coordinates[k]))++invalid;
            if(!active(i,c)){
                if(a.stamp[3]!=0xffffffffu||g.meanCount[3]!=0||length(vec(g.meanCount))!=0)++invalid;
                latest[i]={};continue;
            }
            if(g.meanCount[3]!=expectedCount||a.stamp[3]>3)++invalid;
            double sx=(s.flags&2)?.5:pr::random(i,sample,0,s.seed),sy=(s.flags&2)?.5:pr::random(i,sample,1,s.seed);
            double lu=pr::random(i,sample,2,s.seed),lv=pr::random(i,sample,3,s.seed);
            if(g.coordinates[0]!=sx||g.coordinates[1]!=sy||g.coordinates[2]!=lu||g.coordinates[3]!=lv)++invalid;
            V3 value=vec(g.lighting.direct);sum[i]=sum[i]+value;latest[i]=vec(g.meanCount);
            meanError=std::max(meanError,length(latest[i]-sum[i]*(1./expectedCount)));
            if(expectedReset&&length(latest[i]-value)!=0)++invalid;
            if(!fullCheck&&i%211!=sample%211)continue;++checked;
            V3 direction=unit(f+r*((2*(double(i%pr::Width-c.x)+sx)/c.w-1)*aspect*tangent)+u*((1-2*(double(i/pr::Width-c.y)+sy)/c.h)*tangent));
            directionError=std::max(directionError,length(direction-vec(a.directionHit)));
            auto hit=surface_reference::closest(c.eye,direction,c.nearPlane/dot(direction,f),scene,s.mask);
            if(a.stamp[3]!=hit.id){++geometryMismatch;continue;}
            if(!hit.id){if(length(value)!=0)++invalid;continue;}
            positionError=std::max(positionError,length(vec(a.positionT)-hit.point));
            V3 x=vec(a.positionT),n=vec(a.normalDepth),q{2+(2*lu-1),-.5-(2*lv-1),3.5};
            V3 delta=q-x;double r2=dot(delta,delta);V3 wi=delta*(1/std::sqrt(r2));
            double cs=std::max(dot(n,wi),0.),cl=std::max(wi.z,0.);bool visible=false;V3 expected{};
            if(cs>0&&cl>0&&dot(n,vec(a.directionHit)*-1)>0){
                V3 origin{float(a.positionT[0]+.0001f*a.normalDepth[0]),float(a.positionT[1]+.0001f*a.normalDepth[1]),float(a.positionT[2]+.0001f*a.normalDepth[2])};
                visible=lighting_reference::visible(origin,q,triangles,s.mask);
                if(visible&&!s.blackMaterial){V3 rho=lighting_reference::albedo(hit.id);double weight=cs*cl*4/(Pi*r2)*(s.doubleLight?2:1);expected={12*rho.x*weight,11*rho.y*weight,9*rho.z*weight};}
            }
            if(g.lighting.direct[3]!=unsigned(visible))++shadowMismatch;
            sampleError=std::max(sampleError,length(value-expected));
        }
    }
    bool finish(const char* label){bool pass=invalid==0&&geometryMismatch==0&&shadowMismatch==0&&meanError<1e-5&&positionError<1e-4&&directionError<1e-5&&sampleError<1e-5;
        std::printf("%s frames=%u checked=%u invalid=%u geometry=%u shadow=%u mean=%.3g dir=%.3g pos=%.3g sample=%.3g %s\n",label,frames,checked,invalid,geometryMismatch,shadowMismatch,meanError,directionError,positionError,sampleError,pass?"PASS":"FAIL");return pass;}
};
} // namespace history_reference
