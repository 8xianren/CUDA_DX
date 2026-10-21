#pragma once
#include "path_host.h"
#include <iostream>
using namespace cuda_pt;
// CPU/Megakernel/Wavefront共用的结果验收；数值容差和离散路径摘要分开检查。
struct Totals {uint64_t rays=0,shadows=0,vertices=0,rrKilled=0,active[17]{};double mean=0;};
Totals Sum(const std::vector<PixelResult>& pixels){Totals t;for(const auto& p:pixels){Require(p.stats.errors==0&&Finite(p.radiance)&&p.radiance.x>=0&&p.radiance.y>=0&&p.radiance.z>=0,"path nonfinite/negative/traversal error");
    t.rays+=p.stats.rays;t.shadows+=p.stats.shadows;t.vertices+=p.stats.vertices;t.rrKilled+=p.stats.rrKilled;t.mean+=(p.radiance.x+p.radiance.y+p.radiance.z)/3.;for(unsigned d=0;d<17;++d)t.active[d]+=p.stats.active[d];}
    t.mean/=pixels.size();return t;}
double Compare(const std::vector<PixelResult>& a,const std::vector<PixelResult>& b,bool discrete=true){
    Require(a.size()==b.size(),"image extent");double maximum=0;unsigned branches=0;
    for(size_t i=0;i<a.size();++i){auto x=a[i].radiance,y=b[i].radiance;maximum=std::max({maximum,std::abs(double(x.x)-y.x)/(1+std::abs(double(y.x))),std::abs(double(x.y)-y.y)/(1+std::abs(double(y.y))),std::abs(double(x.z)-y.z)/(1+std::abs(double(y.z)))});
        const auto& u=a[i].stats;const auto& v=b[i].stats;if(u.hash!=v.hash||u.rays!=v.rays||u.shadows!=v.shadows||u.vertices!=v.vertices||u.rrKilled!=v.rrKilled)++branches;}
    if(discrete&&branches){std::cerr<<"discrete differing pixels="<<branches<<" maxNormalized="<<maximum<<'\n';}
    Require(!discrete||branches==0,"CPU/GPU path decisions mismatch");return maximum;
}
