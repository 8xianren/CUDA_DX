#pragma once
#include "dxr_surface_reference.h"
// R.13.5：先沿用独立几何验证，再用已验证的GPU位置作为积分输入。
// CPU用double面积形式，GPU用float立体角形式；遮挡由CPU逐三角形求交独立检查。
namespace lighting_reference {
using namespace view_reference;
struct GpuRecord {surface_reference::GpuRecord surface;float direct[4],open[4];};
static_assert(sizeof(GpuRecord)==160,"lighting output stride");
inline unsigned mode(unsigned i){return i==7?0:i;}
inline auto cases(){auto out=view_reference::cases();const char* names[]={"nee64","no-shadow","back-emitter","white-furnace","black-rho","double-Le","nee1","nee64-again"};
    for(unsigned i=0;i<8;++i){out[i]=view_reference::cases()[0];out[i].name=names[i];}return out;}
inline uint32_t hash(uint32_t x){x^=x>>16;x*=0x7feb352du;x^=x>>15;x*=0x846ca68bu;x^=x>>16;return x;}
inline double uniform(uint32_t pixel,uint32_t s,uint32_t dim){return ((hash((pixel*0x9e3779b9u)^(2*s+dim)^0x51ed270bu)>>16)+.5)/65536.;}
inline V3 albedo(unsigned id){return id==1?V3{.7,.18,.08}:id==2?V3{.08,.28,.7}:V3{.65,.65,.65};}
struct Triangle {V3 a,e1,e2;unsigned mask;};
inline auto triangles(){std::array<Triangle,6> out{};unsigned k=0;
    for(const auto& i:surface_reference::instances())for(unsigned p=0;p<2;++p){
        V3 a=surface_reference::vertex(i,surface_reference::Indices[3*p]);
        out[k++]={a,surface_reference::vertex(i,surface_reference::Indices[3*p+1])-a,surface_reference::vertex(i,surface_reference::Indices[3*p+2])-a,1u<<(i.id-1)};
    }return out;}
inline bool visible(V3 o,V3 q,const std::array<Triangle,6>& scene,unsigned mask=255){
    V3 delta=q-o;double len=length(delta);V3 d=delta*(1/len);
    // 有限线段：只统计表面与灯之间的opaque遮挡，不能沿无限射线查询。
    for(const auto& t:scene){if(!(mask&t.mask))continue;V3 p=cross(d,t.e2);double det=dot(t.e1,p);if(std::fabs(det)<1e-12)continue;
        V3 a=o-t.a;double u=dot(a,p)/det;if(u<0||u>1)continue;
        V3 b=cross(a,t.e1);double v=dot(d,b)/det;if(v<0||u+v>1)continue;
        double distance=dot(t.e2,b)/det;if(distance>=.001&&distance<=len-.001)return false;
    }return true;}
inline bool verify(const GpuRecord* gpu,const Case& c,unsigned serial,const std::string& prefix){
    const unsigned count=CanvasW*CanvasH,m=mode(serial-1),samples=m==6?1:64;
    std::vector<surface_reference::GpuRecord> geometry(count);
    for(unsigned i=0;i<count;++i)geometry[i]=gpu[i].surface;
    bool pass=surface_reference::verify(geometry.data(),c,serial,prefix);
    const auto scene=triangles();unsigned invalid=0,visibilityMismatch=0,partial=0;
    double maxRGB=0,maxOpen=0,maxRelation=0,maxValue=0;
    // 留存第一帧数值，仅用于同随机数下的参数关系检查，不是渲染历史累积。
    static std::vector<GpuRecord> baseline;
    if(serial==1)baseline.assign(gpu,gpu+count);
    std::ofstream image(prefix+"_"+std::to_string(serial)+".pfm",std::ios::binary);
    image<<"PF\n"<<CanvasW<<" "<<CanvasH<<"\n-1.0\n"; // Windows little-endian，PFM行从底部开始。
    for(unsigned row=CanvasH;row>0;--row)for(unsigned x=0;x<CanvasW;++x)
        image.write(reinterpret_cast<const char*>(gpu[(row-1)*CanvasW+x].direct),3*sizeof(float));
    pass=bool(image)&&pass;
    for(unsigned i=0;i<count;++i){const auto& g=gpu[i];const auto& a=g.surface;
        V3 expected{},open{};double hits=0,eligible=0;
        bool in=a.stamp[3]!=0xffffffffu;unsigned id=in?a.stamp[3]:0;
        V3 rho=albedo(id);
        if(in&&m==3){expected=open=id?rho:V3{1,1,1};hits=eligible=id?1:0;}
        else if(id&&id<=3){
            V3 n=vec(a.normalDepth),point=vec(a.positionT),wo=vec(a.directionHit)*-1;
            if(dot(n,wo)>0)for(unsigned s=0;s<samples;++s){
                V3 q{2+(2*uniform(i,s,0)-1),-.5-(2*uniform(i,s,1)-1),3.5};
                V3 delta=q-point;double r2=dot(delta,delta);V3 wi=delta*(1/std::sqrt(r2));
                double cs=std::max(dot(n,wi),0.),cl=std::max((m==2?-1.:1.)*wi.z,0.);
                if(cs<=0||cl<=0)continue;
                double weight=cs*cl*4/(Pi*r2)*(m==5?2:1)*(m==4?0:1);
                V3 value{12*rho.x*weight,11*rho.y*weight,9*rho.z*weight};
                // 可见性原点沿法线微移；物理积分仍用未偏移point，避免把数值补丁混入几何项。
                V3 origin{float(a.positionT[0]+.0001f*a.normalDepth[0]),float(a.positionT[1]+.0001f*a.normalDepth[1]),float(a.positionT[2]+.0001f*a.normalDepth[2])};
                bool v=m==1||visible(origin,q,scene);open=open+value;eligible+=1;
                if(v){expected=expected+value;hits+=1;}
            }
            expected=expected*(1./samples);open=open*(1./samples);hits/=samples;eligible/=samples;
        }
        for(unsigned k=0;k<4;++k)if(!std::isfinite(g.direct[k])||!std::isfinite(g.open[k]))++invalid;
        maxRGB=std::max(maxRGB,length(vec(g.direct)-expected));maxOpen=std::max(maxOpen,length(vec(g.open)-open));
        if(g.direct[3]!=hits||g.open[3]!=eligible)++visibilityMismatch;
        if(g.direct[3]>0&&g.direct[3]<g.open[3])++partial;
        maxValue=std::max({maxValue,double(g.direct[0]),double(g.direct[1]),double(g.direct[2])});
        if(m==1)maxRelation=std::max(maxRelation,length(vec(g.direct)-vec(g.open)));
        if(m==2||m==4)maxRelation=std::max(maxRelation,length(vec(g.direct)));
        if(m==5||serial==8)maxRelation=std::max(maxRelation,length(vec(g.direct)-vec(baseline[i].direct)*(m==5?2.:1.)));
    }
    pass=pass&&invalid==0&&visibilityMismatch==0&&maxRGB<2e-5&&maxOpen<2e-5&&maxRelation<1e-6;
    if(serial==1)pass=pass&&partial>0&&maxValue>0;
    std::printf("light=%u %-15s invalid=%u visibilityMismatch=%u partial=%u maxRGB=%.6g maxOpen=%.6g relation=%.3g peak=%.6g %s\n",serial,c.name,invalid,visibilityMismatch,partial,maxRGB,maxOpen,maxRelation,maxValue,pass?"PASS":"FAIL");
    return pass;
}
} // namespace lighting_reference
