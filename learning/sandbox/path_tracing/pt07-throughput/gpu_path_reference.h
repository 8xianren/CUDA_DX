#pragma once
#include "gpu_path.h"
#include "throughput_math.h"
namespace path_reference {
using throughput::Vec;using throughput::Dot;using throughput::Unit;
inline Vec V(const float* p){return {p[0],p[1],p[2]};}
inline Vec Sub(Vec a,Vec b){return {a.x-b.x,a.y-b.y,a.z-b.z};}
inline Vec Normal(Vec p){double a=std::abs(p.x),b=std::abs(p.y),c=std::abs(p.z);
    return a>=b&&a>=c?Vec{p.x>0?-1.:1.,0,0}:(b>=c?Vec{0,p.y>0?-1.:1.,0}:Vec{0,0,p.z>0?-1.:1.});}
inline double LightPdf(Vec x,Vec q){Vec d=Sub(q,x);double r2=Dot(d,d);if(r2==0)return 0;
    double cosine=Dot(Normal(q),Unit(d)*(-1));return cosine>0?r2/(24*cosine):0;}
struct Audit {double maxValueError=0,maxPositionError=0;uint64_t rays=0,vertices=0;};
// 和shader逐bit相同的独立RR整数流，用于检查真实决策；几何和积分仍独立double评估。
inline double RouletteUniform(uint32_t& state){state+=0x9e3779b9u;uint32_t x=state;x=(x^(x>>16))*0x21f0aaadu;x=(x^(x>>15))*0x735a2d97u;x^=x>>15;return ((x>>9)+.5)/8388608.;}
inline void Check(bool b,const char* m){if(!b)throw std::runtime_error(m);}
inline void Near(double gpu,double expected,Audit& a){Check(std::isfinite(gpu),"nonfinite GPU output");
    double e=std::abs(gpu-expected);a.maxValueError=std::max(a.maxValueError,e);
    if(e>=2e-4*(1+std::abs(expected)))throw std::runtime_error("CPU equation GPU="+std::to_string(gpu)+" expected="+std::to_string(expected));}
// 不重放GPU随机序列：读取实际选出的方向端点，在double中独立验证每个局部积分方程。
// 此外用解析盒面交点验证GPU几何；最终均值还要和独立闭式解比较，避免只验证自洽。
inline void Validate(const PathConfig& cfg,const std::vector<PathRecord>& records,Audit& audit){
    for(uint32_t path=0;path<cfg.paths;++path){Vec previous{0,0,0};double total[3]{},expectedBeta[3]{1,1,1};bool alive=true;
        uint32_t rrRng=((path+1)*747796405u+cfg.seed*2891336453u)^0xa511e9b3u;
        for(uint32_t depth=0;depth<=cfg.maxScatters;++depth){const auto& r=records[size_t(path)*(cfg.maxScatters+1)+depth];
            if(!alive){Check(r.diagnostics[0]==0&&r.diagnostics[1]==0&&r.diagnostics[2]==0&&r.diagnostics[3]==depth,"invalid dead slot");
                for(int channel=0;channel<3;++channel){Check(r.beta[channel]==0,"dead beta must be zero");Near(r.radiance[channel],total[channel],audit);}continue;}
            if(r.diagnostics[0]==0||r.diagnostics[2]!=0||r.diagnostics[3]!=depth)
                throw std::runtime_error("GPU diagnostic path="+std::to_string(path)+" depth="+std::to_string(depth)+" hit="+std::to_string(r.diagnostics[0])+" error="+std::to_string(r.diagnostics[2])+" prev="+std::to_string(previous.x)+","+std::to_string(previous.y)+","+std::to_string(previous.z)+" x="+std::to_string(r.position[0])+","+std::to_string(r.position[1])+","+std::to_string(r.position[2])+" q="+std::to_string(r.lightPoint[0])+","+std::to_string(r.lightPoint[1])+","+std::to_string(r.lightPoint[2]));
            audit.rays+=r.diagnostics[1];++audit.vertices;Vec x=V(r.position),n=Normal(x),direction=V(r.rayDirection);
            Check(std::abs(Dot(direction,direction)-1)<1e-5,"ray direction not normalized");
            // 沿这条实际方向，从上个顶点解析求盒面的最近正交点，不使用DXR返回t计算答案。
            double t=1e30;double origin[3]{previous.x,previous.y,previous.z},d[3]{direction.x,direction.y,direction.z};
            for(int axis=0;axis<3;++axis)if(std::abs(d[axis])>1e-14){double candidate=((d[axis]>0?1.:-1.)-origin[axis])/d[axis];if(candidate>1e-6)t=std::min(t,candidate);}
            double positionError=std::abs(t-r.position[3]);audit.maxPositionError=std::max(audit.maxPositionError,positionError);
            Vec expectedPoint=previous+direction*t;Vec shift=Sub(expectedPoint,x);
            Check(Dot(shift,shift)<2e-10,"hit point correction exceeds fixture tolerance");
            if(!(positionError<1e-4&&std::abs(x.x)<=1.00001&&std::abs(x.y)<=1.00001&&std::abs(x.z)<=1.00001))
                throw std::runtime_error("box intersection path="+std::to_string(path)+" depth="+std::to_string(depth)+" CPUt="+std::to_string(t)+" GPUt="+std::to_string(r.position[3])+" prev="+std::to_string(previous.x)+","+std::to_string(previous.y)+","+std::to_string(previous.z)+" x="+std::to_string(x.x)+","+std::to_string(x.y)+","+std::to_string(x.z));
            double previousPdf=depth?Dot(Normal(previous),direction)/mis::pi:0;
            Near(r.radiance[3],previousPdf,audit);
            double emissionWeight=depth&&cfg.mode==1?mis::Weight(previousPdf,LightPdf(previous,x),2):1;
            Near(r.beta[3],emissionWeight,audit);
            Vec q=V(r.lightPoint);double lightWeight=0,cosine=0,pL=0;
            if(depth<cfg.maxScatters&&cfg.mode!=0){Vec lightDelta=Sub(q,x);double r2=Dot(lightDelta,lightDelta);
                if(r2>0){cosine=Dot(n,Unit(lightDelta));pL=LightPdf(x,q);}
                if(cosine>0&&pL>0){Check(r.lightPoint[3]==1,"convex box should have visible light sample");
                    lightWeight=cfg.mode==1?mis::Weight(pL,cosine/mis::pi,2):1;}
                else Check(r.lightPoint[3]==0,"same-face sample must contribute zero");
            }
            Near(r.direct[3],lightWeight,audit);
            for(int c=0;c<3;++c){double beta=expectedBeta[c];Near(r.beta[c],beta,audit);
                double direct=lightWeight>0?beta*cfg.rho[c]/mis::pi*cfg.emission[c]*cosine*lightWeight/pL:0;
                Near(r.direct[c],direct,audit);total[c]+=beta*cfg.emission[c]*emissionWeight+direct;Near(r.radiance[c],total[c],audit);}
            previous=x;
            if(depth==cfg.maxScatters){Check(r.roulette[2]==0&&r.roulette[3]==0,"RR after max depth");continue;}
            for(int channel=0;channel<3;++channel)expectedBeta[channel]*=cfg.rho[channel];
            if(cfg.rrMode!=0&&depth+1>=cfg.rrStart){double peak=std::max({expectedBeta[0],expectedBeta[1],expectedBeta[2]});
                double s=peak>0?std::clamp(peak,double(cfg.rrMin),double(cfg.rrMax)):0,u=RouletteUniform(rrRng);
                Near(r.roulette[0],s,audit);Check(r.roulette[1]==u&&r.roulette[2]==1,"RR random stream mismatch");
                alive=u<r.roulette[0];Check(r.roulette[3]==(alive?1:0),"RR survival decision mismatch");
                // float q可能与double q相差舍入，补偿检查使用实际决策q，再核对下一顶点beta。
                if(alive&&cfg.rrMode==1)for(double& value:expectedBeta)value/=r.roulette[0];
            }else Check(r.roulette[2]==0&&r.roulette[3]==1,"unexpected RR decision");
        }
    }
}
}
