#pragma once
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>
#include <algorithm>

namespace camera_reference {
constexpr double Pi=3.14159265358979323846;
struct V3 {double x,y,z;};
inline V3 operator+(V3 a,V3 b){return {a.x+b.x,a.y+b.y,a.z+b.z};}
inline V3 operator-(V3 a,V3 b){return {a.x-b.x,a.y-b.y,a.z-b.z};}
inline V3 operator*(V3 a,double s){return {a.x*s,a.y*s,a.z*s};}
inline double dot(V3 a,V3 b){return a.x*b.x+a.y*b.y+a.z*b.z;}
inline V3 cross(V3 a,V3 b){return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
inline double length(V3 a){return std::sqrt(dot(a,a));}
inline V3 unit(V3 a){return a*(1/length(a));}
// CPU顶点与HLSL StructuredBuffer<float3>均使用12B stride，不添加alignas(16)。
struct Vertex {float x,y,z;};
inline const Vertex Vertices[]={{-1,-1,0},{1,-1,0},{1,1,0},{-1,1,0}};
inline const uint32_t Indices[]={0,1,2,0,2,3};
static_assert(sizeof(Vertex)==12,"vertex stride");
struct Instance {float m[3][4]; uint32_t id;};
// CPU按列向量数学构造3x4矩阵，按行存入D3D12实例Transform。
// 三实例共享同一平面BLAS：左右竖板分别绕Y旋转，地板绕X转-90度。
inline std::array<Instance,3> instances(){
    std::array<Instance,3> result{};
    auto yrot=[](double angle,double sx,double sy,double tx,double ty,double tz,uint32_t id){
        const double c=std::cos(angle),s=std::sin(angle);
        Instance r{{{float(c*sx),0,float(s),float(tx)},
                     {0,float(sy),0,float(ty)},
                     {float(-s*sx),0,float(c),float(tz)}},id};return r;
    };
    result[0]=yrot(-25*Pi/180,.8,1.15,-1.05,0,0,1);
    result[1]=yrot(35*Pi/180,.9,.85,1.0,.05,-.6,2);
    result[2]=Instance{{{3,0,0,0},{0,0,1,-1.25},{0,-3,0,0}},3};
    return result;
}
inline V3 transform(const Instance& m,V3 p){
    return {m.m[0][0]*p.x+m.m[0][1]*p.y+m.m[0][2]*p.z+m.m[0][3],
            m.m[1][0]*p.x+m.m[1][1]*p.y+m.m[1][2]*p.z+m.m[1][3],
            m.m[2][0]*p.x+m.m[2][1]*p.y+m.m[2][2]*p.z+m.m[2][3]};
}
inline V3 world_vertex(const Instance& m,unsigned index){auto v=Vertices[index];return transform(m,{v.x,v.y,v.z});}
struct CameraData {float eyeTan[4],rightAspect[4],up[4],forward[4];};
static_assert(sizeof(CameraData)==64,"16 DWORD root constants");
// F指向target；世界参考上向+Y。R=F×up得到本课+X右向，U=R×F。
// 当前两组参数保证eye!=target且up不平行F；通用接口必须检查退化输入。
inline CameraData camera(bool square){
    const V3 eye=square?V3{2,1.8,5}:V3{0,1,5},target{0,0,0};
    const V3 f=unit(target-eye),r=unit(cross(f,{0,1,0})),u=cross(r,f);
    CameraData c{};
    c.eyeTan[0]=float(eye.x);c.eyeTan[1]=float(eye.y);c.eyeTan[2]=float(eye.z);
    c.eyeTan[3]=float(std::tan((square?50.0:60.0)*Pi/360));
    c.rightAspect[0]=float(r.x);c.rightAspect[1]=float(r.y);c.rightAspect[2]=float(r.z);
    c.rightAspect[3]=square?1.0f:320.0f/180.0f;
    c.up[0]=float(u.x);c.up[1]=float(u.y);c.up[2]=float(u.z);
    c.forward[0]=float(f.x);c.forward[1]=float(f.y);c.forward[2]=float(f.z);return c;
}
inline V3 vec(const float* p){return {p[0],p[1],p[2]};}
// CPU使用PT.2的世界成像平面lower-left形式，GPU使用中心+sx*R+sy*U形式。
// 读取同一份float相机参数后以double计算，避免把参数量化差误叫DXR求交错误。
inline V3 ray_direction(const CameraData& c,unsigned x,unsigned y,unsigned width,unsigned height){
    const V3 horizontal=vec(c.rightAspect)*(2*c.eyeTan[3]*c.rightAspect[3]);
    const V3 vertical=vec(c.up)*(2*c.eyeTan[3]);
    const V3 lower=vec(c.forward)-horizontal*.5-vertical*.5;
    return unit(lower+horizontal*((x+.5)/width)+vertical*(1-(y+.5)/height));
}
struct Hit {uint32_t id=0;double t=100;V3 position{},normal{};};
// CPU独立暴力Moller-Trumbore：遍历3实例×2三角形，返回最近合法命中。
// 没有调用GPU结果参与参考计算；共享边上不强求唯一triangle index，只要求几何一致。
inline Hit closest(V3 o,V3 d,const std::array<Instance,3>& scene){
    Hit hit;
    for(const auto& inst:scene)for(unsigned p=0;p<2;++p){
        V3 a=world_vertex(inst,Indices[p*3]),b=world_vertex(inst,Indices[p*3+1]),c=world_vertex(inst,Indices[p*3+2]);
        V3 e1=b-a,e2=c-a,pv=cross(d,e2); double determinant=dot(e1,pv);
        if(std::fabs(determinant)<1e-12)continue;
        V3 tv=o-a;double u=dot(tv,pv)/determinant;if(u<0||u>1)continue;
        V3 qv=cross(tv,e1);double v=dot(d,qv)/determinant;if(v<0||u+v>1)continue;
        double t=dot(e2,qv)/determinant;if(t<.001||t>hit.t)continue;
        hit.id=inst.id;hit.t=t;hit.position=o+d*t;hit.normal=unit(cross(e1,e2));
    }return hit;
}
struct GpuPixel {float positionT[4],normalID[4],baryPrim[4];};
static_assert(sizeof(GpuPixel)==48,"HLSL PixelResult stride");
inline uint8_t byte(double v){return uint8_t(std::lround(std::clamp(v,0.0,1.0)*255));}
// PPM是最小诊断图格式；直接编码法线/伪彩色/距离，绝不是线性辐亮度的显示管线。
// 文件写入仅发生在GPU完成且数值验证通过之后，所有权由CPU持有。
inline bool write_ppm(const std::string& path,unsigned w,unsigned h,const std::vector<uint8_t>& rgb){
    std::ofstream f(path,std::ios::binary);f<<"P6\n"<<w<<" "<<h<<"\n255\n";
    f.write(reinterpret_cast<const char*>(rgb.data()),std::streamsize(rgb.size()));return bool(f);
}
inline bool verify(const GpuPixel* gpu,const CameraData& cam,unsigned w,unsigned h,const std::string& prefix){
    auto scene=instances();std::array<unsigned,4> counts{};
    unsigned mismatch=0,invalid=0;double maxT=0,maxPosition=0,maxNormal=0,maxBaryPosition=0;
    std::vector<uint8_t> normal(w*h*3),depth(w*h*3),ids(w*h*3);
    const V3 palette[]={{.025,.035,.06},{.95,.32,.18},{.15,.65,.95},{.38,.72,.32}};
    for(unsigned y=0;y<h;++y)for(unsigned x=0;x<w;++x){
        unsigned i=y*w+x;const auto& a=gpu[i];
        for(float f:a.positionT)if(!std::isfinite(f))++invalid;
        for(float f:a.normalID)if(!std::isfinite(f))++invalid;
        for(float f:a.baryPrim)if(!std::isfinite(f))++invalid;
        // 无效输出不转换成数组索引，避免诊断程序自身越界。
        float idf=a.normalID[3];unsigned id=0;
        if(!(idf>=0&&idf<=3&&std::floor(idf)==idf)){++invalid;continue;}id=unsigned(idf);++counts[id];
        const V3 d=ray_direction(cam,x,y,w,h);const Hit ref=closest(vec(cam.eyeTan),d,scene);
        if(id!=ref.id)++mismatch;
        if(id==0){if(a.positionT[3]!=-1||a.baryPrim[3]!=0)++invalid;}
        else {
            if(a.baryPrim[3]!=1||a.positionT[3]<.001f)++invalid;
            if(id==ref.id){
                maxT=std::max(maxT,std::fabs(a.positionT[3]-ref.t));
                maxPosition=std::max(maxPosition,length(vec(a.positionT)-ref.position));
                maxNormal=std::max(maxNormal,length(vec(a.normalID)-ref.normal));
            }
            const double u=a.baryPrim[0],v=a.baryPrim[1];const float prim=a.baryPrim[2];
            if(!(u>=-1e-5&&v>=-1e-5&&u+v<=1+1e-5&&(prim==0||prim==1)))++invalid;
            else {
                const unsigned p=unsigned(prim);const auto& inst=scene[id-1];
                V3 pa=world_vertex(inst,Indices[p*3]),pb=world_vertex(inst,Indices[p*3+1]),pc=world_vertex(inst,Indices[p*3+2]);
                V3 fromBary=pa*(1-u-v)+pb*u+pc*v;
                maxBaryPosition=std::max(maxBaryPosition,length(fromBary-vec(a.positionT)));
            }
        }
        const V3 n=id?vec(a.normalID)*.5+V3{.5,.5,.5}:palette[0];
        const double z=id?std::clamp((12-a.positionT[3])/10.0,0.0,1.0):0;
        const V3 color=palette[id];
        normal[3*i]=byte(n.x);normal[3*i+1]=byte(n.y);normal[3*i+2]=byte(n.z);
        depth[3*i]=depth[3*i+1]=depth[3*i+2]=byte(z);
        ids[3*i]=byte(color.x);ids[3*i+1]=byte(color.y);ids[3*i+2]=byte(color.z);
    }
    // 独立相机约束：正交基、纵横比，以及奇数分辨率中心像素精确看向F。
    const V3 f=vec(cam.forward),r=vec(cam.rightAspect),u=vec(cam.up);
    bool basis=std::fabs(dot(f,r))<1e-6&&std::fabs(dot(f,u))<1e-6&&std::fabs(dot(r,u))<1e-6;
    basis &= std::fabs(length(f)-1)<1e-6&&std::fabs(length(r)-1)<1e-6&&std::fabs(length(u)-1)<1e-6;
    basis &= std::fabs(cam.rightAspect[3]-double(w)/h)<1e-6;
    if(w%2&&h%2)basis &= length(ray_direction(cam,w/2,h/2,w,h)-unit(f))<1e-12;
    const bool pass=basis&&invalid==0&&mismatch==0&&maxT<1e-4&&maxPosition<1e-4&&maxNormal<1e-5&&maxBaryPosition<1e-4&&
       counts[0]>0&&counts[1]>0&&counts[2]>0&&counts[3]>0;
    std::printf("Camera %ux%u basis=%s coverage miss=%u id1=%u id2=%u id3=%u\n",w,h,basis?"PASS":"FAIL",counts[0],counts[1],counts[2],counts[3]);
    std::printf("CPU/GPU id_mismatch=%u invalid=%u max_t=%.3g max_position=%.3g max_normal=%.3g bary_position=%.3g\n",mismatch,invalid,maxT,maxPosition,maxNormal,maxBaryPosition);
    if(!pass)return false;
    bool saved=write_ppm(prefix+"_normals.ppm",w,h,normal)&&write_ppm(prefix+"_distance.ppm",w,h,depth)&&write_ppm(prefix+"_ids.ppm",w,h,ids);
    std::printf("Diagnostic PPM prefix: %s (%s)\n",prefix.c_str(),saved?"saved":"WRITE FAILED");return saved;
}
} // namespace camera_reference
