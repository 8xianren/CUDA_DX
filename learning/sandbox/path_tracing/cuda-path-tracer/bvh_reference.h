#pragma once
#include "bvh_build.h"
#include <random>
namespace cuda_pt {
struct DVec {double x,y,z;};
inline DVec D(Vec3 v){return {v.x,v.y,v.z};}
inline DVec operator+(DVec a,DVec b){return {a.x+b.x,a.y+b.y,a.z+b.z};}
inline DVec operator-(DVec a,DVec b){return {a.x-b.x,a.y-b.y,a.z-b.z};}
inline DVec operator*(DVec a,double b){return {a.x*b,a.y*b,a.z*b};}
inline double Dot(DVec a,DVec b){return a.x*b.x+a.y*b.y+a.z*b.z;}
inline DVec Cross(DVec a,DVec b){return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
struct DoubleHit {double t=0,u=0,v=0;uint32_t id=Invalid;};
inline DoubleHit Reference(const Scene& scene,const Ray& ray){
    DoubleHit best;best.t=ray.tmax;DVec o=D(ray.origin),d=D(ray.direction);
    for(const auto& t:scene.triangles){
        // 与GPU标量三重积解法独立：先求射线与平面交点，再用Gram矩阵求面内重心坐标。
        DVec a=D(t.a),e1=D(t.b)-a,e2=D(t.c)-a,n=Cross(e1,e2);double nd=Dot(n,d);if(nd==0)continue;
        double distance=Dot(n,a-o)/nd;if(distance<ray.tmin||distance>best.t)continue;
        DVec q=o+d*distance-a;double aa=Dot(e1,e1),ab=Dot(e1,e2),bb=Dot(e2,e2),aq=Dot(e1,q),bq=Dot(e2,q),det=aa*bb-ab*ab;
        if(det<=0)continue;double u=(aq*bb-bq*ab)/det,v=(bq*aa-aq*ab)/det;
        if(u<0||v<0||u+v>1)continue;
        if(distance<best.t||t.id<best.id)best={distance,u,v,t.id};
    }return best;
}
inline std::vector<Ray> GalleryRays(const Bvh& b,unsigned count){
    Require(!b.nodes.empty(),"gallery rays require nonempty tree");std::vector<Ray> rays;rays.reserve(count);
    std::mt19937 generator(20261021);auto random=[&]{return float((double(generator())+.5)/4294967296.);};
    Vec3 lo=b.nodes[0].lower,hi=b.nodes[0].upper,center=(lo+hi)*.5f,extent=hi-lo;
    Vec3 forward=Normalize(Vec3{0,1.7f,0}-Vec3{0,3.8f,15}),right=Normalize(Cross(forward,{0,1,0})),up=Cross(right,forward);
    for(unsigned i=0;i<count;++i){Ray r;unsigned kind=i%4;
        if(kind==0){float x=2*random()-1,y=2*random()-1;r.origin={0,3.8f,15};r.direction=Normalize(forward+right*(x*2*.31529879f)+up*(y*.31529879f));r.tmin=1e-5f;r.tmax=1000;}
        else if(kind==1){r.origin=center+Vec3{(2*random()-1)*extent.x*1.5f,(2*random()-1)*extent.y*1.5f,(2*random()-1)*extent.z*1.5f};
            Vec3 target=lo+Vec3{random()*extent.x,random()*extent.y,random()*extent.z};r.direction=Normalize(target-r.origin);r.tmin=1e-5f;r.tmax=1000;}
        else if(kind==2){r.origin=lo+Vec3{random()*extent.x,random()*extent.y,random()*extent.z};r.direction=Normalize(Vec3{2*random()-1,2*random()-1,2*random()-1});r.tmin=1e-5f;r.tmax=1000;}
        else{r.origin=center+Vec3{(2*random()-1)*extent.x,(2*random()-1)*extent.y,(2*random()-1)*extent.z};
            unsigned axis=i%3;r.direction={};float sign=random()<.5f?-1.f:1.f;if(axis==0)r.direction.x=sign;else if(axis==1)r.direction.y=sign;else r.direction.z=sign;
            r.tmin=0;r.tmax=.01f+random()*10;}
        ValidateRay(r);rays.push_back(r);
    }return rays;
}
inline Scene Fixture(unsigned duplicateCount=1,float scale=1){Scene scene;scene.materials.push_back({});
    for(unsigned i=0;i<duplicateCount;++i){Triangle t;t.a={0,0,0};t.b={scale,0,0};t.c={0,scale,0};t.id=i;scene.triangles.push_back(t);}return scene;
}
}
