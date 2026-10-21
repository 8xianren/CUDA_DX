#pragma once
#include "reuse_pipeline.h"
namespace restir_di {
inline double Dot(V3 a,V3 b){return a.x*b.x+a.y*b.y+a.z*b.z;}
struct CameraGrid {
    unsigned width=12,height=8;double centerX=0,centerY=0,extentX=2.4,extentY=1.6,z=4;
    uint64_t lightRevision=1;bool cut=false;
};
struct SurfaceConfig {double height=0,slope=0;uint32_t identity=1;bool hideRight=false;};
struct Surface {V3 position,normal;double depth=0;uint32_t identity=0;bool valid=false;};
inline Surface MakeSurface(const CameraGrid& c,const SurfaceConfig& cfg,unsigned pixel){
    // 正交相机朝-Z：像素中心映射到固定世界XY窗口，再求与z=height+slope*x平面的交点。
    // normal由平面方程梯度(-slope,0,1)归一化，不伪造与几何无关的法线变化。
    double x=c.centerX+c.extentX*((pixel%c.width+.5)/c.width-.5),y=c.centerY+c.extentY*((pixel/c.width+.5)/c.height-.5);
    double z=cfg.height+cfg.slope*x,len=std::sqrt(1+cfg.slope*cfg.slope);
    return {{x,y,z},{-cfg.slope/len,0,1/len},c.z-z,cfg.identity,!(cfg.hideRight&&x>0)};
}
inline int Reproject(V3 world,const CameraGrid& previous){
    // 由上一帧x=cx+extent*((i+.5)/width-.5)反解连续像素中心i。
    // 最近中心round(i)等价于floor(width*u)。先判断半开窗口[0,1)，再取整。
    // 图像row向+Y递增，与本课程origin='lower'一致，不混用D3D顶端起点约定。
    double u=(world.x-previous.centerX)/previous.extentX+.5,v=(world.y-previous.centerY)/previous.extentY+.5;
    if(u<0||u>=1||v<0||v>=1)return -1;
    return int(std::floor(v*previous.height))*int(previous.width)+int(std::floor(u*previous.width));
}
inline Evaluation EvaluateSurface(const Scene& s,const Surface& x,LightSample y){
    auto d=Position(s,y)-x.position;double r2=Dot(d,d),h=2-x.position.z;
    double g=std::max(0.,Dot(x.normal,d))*h/(r2*r2);V3 f=s.lights[y.light].emission*(s.rho/Pi*g);
    // 很小的正评分保持固定灯域的支持：即使源法线导致贡献零，未来目标仍有抽中机会。
    // 评分floor不是贡献floor，最终物理F仍可为0；它可能增加方差，不是消偏魔法。
    return {f,1/(s.lights.size()*s.lights[y.light].Area()),std::max(1e-8,Luma(f)),g/Pi};
}
inline bool VisibleSurface(const Scene& s,const Surface& x,LightSample y){
    if(!s.blocker)return true;auto p=Position(s,y);double a=(1-x.position.z)/(2-x.position.z);
    if(a<=0||a>=1)return true;V3 hit=x.position+(p-x.position)*a;
    return !mis::Inside(hit.x,hit.y,s.bx0,s.bx1,s.by0,s.by1);
}
inline V3 ReferenceSurface(const Scene& s,const Surface& surface,unsigned resolution){
    if(!surface.valid)return {};V3 x=surface.position,result{};double h=2-x.z,a=(1-x.z)/h;
    bool hasBlocker=s.blocker&&a>0&&a<1;
    // 独立积分：将板边界通过x+a*(y-x)逆映射到灯面，切分后求积。
    double bx0=(s.bx0-(1-a)*x.x)/a,bx1=(s.bx1-(1-a)*x.x)/a;
    double by0=(s.by0-(1-a)*x.y)/a,by1=(s.by1-(1-a)*x.y)/a;
    for(const auto& l:s.lights){std::vector<double> xs{l.xmin,l.xmax},ys{l.ymin,l.ymax};
        if(hasBlocker){for(double b:{bx0,bx1})if(b>l.xmin&&b<l.xmax)xs.push_back(b);for(double b:{by0,by1})if(b>l.ymin&&b<l.ymax)ys.push_back(b);}
        std::sort(xs.begin(),xs.end());std::sort(ys.begin(),ys.end());
        for(size_t i=1;i<xs.size();++i)for(size_t j=1;j<ys.size();++j){double cx=(xs[i]+xs[i-1])*.5,cy=(ys[j]+ys[j-1])*.5;
            if(hasBlocker&&cx>=bx0&&cx<=bx1&&cy>=by0&&cy<=by1)continue;double dx=(xs[i]-xs[i-1])/resolution,dy=(ys[j]-ys[j-1])/resolution;
            for(unsigned v=0;v<resolution;++v)for(unsigned u=0;u<resolution;++u){double px=xs[i-1]+(u+.5)*dx-x.x,py=ys[j-1]+(v+.5)*dy-x.y;
                double r2=px*px+py*py+h*h,cosNumerator=std::max(0.,surface.normal.x*px+surface.normal.y*py+surface.normal.z*h);
                result=result+l.emission*(s.rho/Pi*cosNumerator*h/(r2*r2)*dx*dy);}
        }
    }return result;
}
}
