#pragma once
#include "dxr_view_reference.h"
#include <fstream>
#include <string>
#include <vector>
// 相机结构/八组测试沿用R.13.3。独立几何参考只用CPU double和实际上传的float顶点/实例。
namespace surface_reference {
using namespace view_reference;
struct GpuRecord {
    float originNear[4],directionHit[4];uint32_t stamp[4];
    float positionT[4],normalDepth[4],inverseNormal[4],wrongNormal[4],baryPrimitive[4];
};
static_assert(sizeof(GpuRecord)==128 && offsetof(GpuRecord,positionT)==48,"surface record layout");
// 倾斜局部平面x+.3y+.2z=0；法线不与缩放轴重合，才能暴露错误法线变换。
inline const Vertex Vertices[]={{.5f,-1,-1},{-.1f,1,-1},{-.5f,1,1},{.1f,-1,1}};
inline const uint32_t Indices[]={0,2,1,0,3,2}; // 绕序法线大致指向-X，面对基线相机。
struct Instance {float m[3][4];uint32_t id;};
inline std::array<Instance,3> instances(){
    auto make=[](XMMATRIX rowMatrix,uint32_t id){
        XMFLOAT4X4 raw;XMStoreFloat4x4(&raw,rowMatrix);Instance out{};out.id=id;
        // CPU DirectXMath行向量4x4 -> DXR矩阵乘列位置的3x4；必须显式转换布局。
        for(unsigned i=0;i<3;++i)for(unsigned j=0;j<4;++j)out.m[i][j]=raw.m[j][i];
        return out;
    };
    // 先缩放局部位置，再旋转，最后平移；三个正行列式实例共享一个BLAS和一套VB/IB。
    return {{
      make(XMMatrixScaling(.5f,.85f,1.0f)*XMMatrixRotationZ(float(-12*Pi/180))*XMMatrixTranslation(4,-1.1f,.1f),1),
      make(XMMatrixScaling(1.8f,.7f,.8f)*XMMatrixRotationZ(float(25*Pi/180))*XMMatrixTranslation(5,1.0f,.3f),2),
      make(XMMatrixScaling(.3f,3,3)*XMMatrixRotationY(float(Pi/2))*XMMatrixTranslation(5,0,-1.3f),3)
    }};
}
inline V3 transform(const Instance& i,V3 p){return {
    i.m[0][0]*p.x+i.m[0][1]*p.y+i.m[0][2]*p.z+i.m[0][3],
    i.m[1][0]*p.x+i.m[1][1]*p.y+i.m[1][2]*p.z+i.m[1][3],
    i.m[2][0]*p.x+i.m[2][1]*p.y+i.m[2][2]*p.z+i.m[2][3]};}
inline V3 vertex(const Instance& i,unsigned v){const auto& p=Vertices[v];return transform(i,{p.x,p.y,p.z});}
struct Hit {uint32_t id=0;double t=20;V3 point{},normal{};};
inline Hit closest(V3 o,V3 d,double nearT,const std::array<Instance,3>& scene,unsigned mask=255){
    Hit h;
    // 解O+tD=A+u(B-A)+v(C-A)，以下是该3x3系统的标量三重积求解（Moller-Trumbore）。
    // CPU遍历只有6个三角形；GPU实际仍通过DXR加速结构求交，不是执行这个循环。
    for(const auto& i:scene)for(unsigned p=0;p<2;++p){
        if(!(mask&(1u<<(i.id-1))))continue; // 与TLAS实例的1/2/4掩码对应；旧测试默认包含全部。
        V3 a=vertex(i,Indices[3*p]),b=vertex(i,Indices[3*p+1]),c=vertex(i,Indices[3*p+2]);
        V3 e1=b-a,e2=c-a,pv=cross(d,e2);double det=dot(e1,pv);
        if(std::fabs(det)<1e-12)continue;
        V3 tv=o-a;double u=dot(tv,pv)/det;if(u<0||u>1)continue;
        V3 qv=cross(tv,e1);double v=dot(d,qv)/det;if(v<0||u+v>1)continue;
        double t=dot(e2,qv)/det;if(t<nearT||t>h.t)continue;
        h.id=i.id;h.t=t;h.point=o+d*t;h.normal=unit(cross(e1,e2));
    }return h;
}
inline bool write_ppm(const std::string& name,const std::vector<uint8_t>& rgb){
    std::ofstream f(name,std::ios::binary);f<<"P6\n"<<CanvasW<<" "<<CanvasH<<"\n255\n";
    f.write(reinterpret_cast<const char*>(rgb.data()),std::streamsize(rgb.size()));return bool(f);
}
inline uint8_t byte(double x){return uint8_t(std::lround(std::clamp(x,0.,1.)*255));}
inline bool verify(const GpuRecord* gpu,const Case& c,uint32_t serial,const std::string& prefix){
    const auto scene=instances();const V3 f=unit(c.forward),r=unit(cross({0,0,1},f)),u=cross(f,r);
    const double tanHalf=std::tan(c.fov*Pi/360),aspect=double(c.w)/c.h;
    unsigned invalid=0,mismatch=0;std::array<unsigned,4> counts{};
    double maxD=0,maxNear=0,maxT=0,maxPosition=0,maxNormal=0,maxInverse=0,maxBary=0,maxDepth=0,maxWrongAngle=0;
    // 图像编码只用于诊断，不代表光照值，也不做曝光/tone mapping/sRGB转换。
    std::array<std::vector<uint8_t>,6> images;for(auto& a:images)a.resize(CanvasW*CanvasH*3);
    const V3 palette[]={{.025,.035,.06},{.96,.32,.12},{.12,.55,.95},{.3,.7,.3}};
    for(unsigned y=0;y<CanvasH;++y)for(unsigned x=0;x<CanvasW;++x){
        const unsigned index=y*CanvasW+x;const auto& g=gpu[index];
        if(g.stamp[0]!=x||g.stamp[1]!=y||g.stamp[2]!=serial)++invalid;
        bool valid=true;
        for(const float* block:{g.originNear,g.directionHit,g.positionT,g.normalDepth,g.inverseNormal,g.wrongNormal,g.baryPrimitive})
            for(unsigned k=0;k<4;++k)valid &= std::isfinite(block[k]);
        if(!valid){++invalid;continue;} // 不让NaN进入数组索引或图像字节转换。
        bool in=x>=c.x&&y>=c.y&&x<c.x+c.w&&y<c.y+c.h;
        if(!in){if(g.stamp[3]!=0xffffffffu)++invalid;continue;}
        if(g.stamp[3]>3){++invalid;continue;}unsigned id=g.stamp[3];++counts[id];
        V3 d=unit(f+r*((2*(double(x-c.x)+.5)/c.w-1)*aspect*tanHalf)+u*((1-2*(double(y-c.y)+.5)/c.h)*tanHalf));
        double nearT=c.nearPlane/dot(d,f);Hit ref=closest(c.eye,d,nearT,scene);
        maxD=std::max(maxD,length(vec(g.directionHit)-d));maxNear=std::max(maxNear,std::fabs(g.originNear[3]-nearT));
        if(length(vec(g.originNear)-c.eye)>1e-6)++invalid;
        if(id!=ref.id)++mismatch;
        if(!id){if(g.directionHit[3]!=-1||g.positionT[3]!=-1||g.baryPrimitive[3]!=0)++invalid;}
        else {
            if(g.baryPrimitive[3]!=1||g.positionT[3]!=g.directionHit[3])++invalid;
            if(id==ref.id){
                maxT=std::max(maxT,std::fabs(g.positionT[3]-ref.t));
                maxPosition=std::max(maxPosition,length(vec(g.positionT)-ref.point));
                maxNormal=std::max(maxNormal,length(vec(g.normalDepth)-ref.normal));
                double z=dot(ref.point-c.eye,f);
                maxDepth=std::max({maxDepth,std::fabs(g.normalDepth[3]-z),std::fabs(g.inverseNormal[3]-c.nearPlane/z)});
            }
            maxInverse=std::max(maxInverse,length(vec(g.normalDepth)-vec(g.inverseNormal)));
            const double bu=g.baryPrimitive[0],bv=g.baryPrimitive[1];float prim=g.baryPrimitive[2];
            if(bu< -1e-5||bv< -1e-5||bu+bv>1+1e-5||(prim!=0&&prim!=1))++invalid;
            else {
                const auto& i=scene[id-1];unsigned p=unsigned(prim);
                V3 q=vertex(i,Indices[3*p])*(1-bu-bv)+vertex(i,Indices[3*p+1])*bu+vertex(i,Indices[3*p+2])*bv;
                // GPU给出的primitive可在共享边上选择任意合法三角形，但重建必须与位置/射线一致。
                maxBary=std::max({maxBary,length(q-vec(g.positionT)),length(vec(g.positionT)-(vec(g.originNear)+vec(g.directionHit)*g.positionT[3])),double(g.wrongNormal[3])});
                // 验证错误对照确实是普通方向变换，保证后面的角度展示有正确含义。
                V3 la{Vertices[Indices[3*p]].x,Vertices[Indices[3*p]].y,Vertices[Indices[3*p]].z};
                V3 lb{Vertices[Indices[3*p+1]].x,Vertices[Indices[3*p+1]].y,Vertices[Indices[3*p+1]].z};
                V3 lc{Vertices[Indices[3*p+2]].x,Vertices[Indices[3*p+2]].y,Vertices[Indices[3*p+2]].z};
                V3 no=unit(cross(lb-la,lc-la));V3 wrong=unit(transform(i,no)-transform(i,{0,0,0}));
                if(length(wrong-vec(g.wrongNormal))>1e-5)++invalid;
            }
            maxWrongAngle=std::max(maxWrongAngle,std::acos(std::clamp(dot(unit(vec(g.normalDepth)),unit(vec(g.wrongNormal))),-1.,1.))*180/Pi);
        }
        double distance=id?std::clamp((10-g.positionT[3])/10.,0.,1.):0;
        double depth=id?std::clamp(double(g.inverseNormal[3])*20,0.,1.):0;
        V3 rgb[]={palette[id],id?vec(g.normalDepth)*.5+V3{.5,.5,.5}:palette[0],
            id?vec(g.wrongNormal)*.5+V3{.5,.5,.5}:palette[0],
            id?V3{1-g.baryPrimitive[0]-g.baryPrimitive[1],g.baryPrimitive[0],g.baryPrimitive[1]}:palette[0],
            {distance,distance,distance},{depth,depth,depth}};
        for(unsigned k=0;k<6;++k){images[k][3*index]=byte(rgb[k].x);images[k][3*index+1]=byte(rgb[k].y);images[k][3*index+2]=byte(rgb[k].z);}
    }
    bool pass=invalid==0&&mismatch==0&&maxD<1e-5&&maxNear<1e-5&&maxT<1e-4&&maxPosition<1e-4&&maxNormal<1e-5&&maxInverse<1e-5&&maxBary<1e-4&&maxDepth<1e-4;
    if(serial==1)pass &= counts[1]>0&&counts[2]>0&&counts[3]>0&&maxWrongAngle>10;
    std::printf("frame=%u %-15s miss/id1/id2/id3=%u/%u/%u/%u mismatch=%u invalid=%u dir=%.3g near=%.3g t=%.3g pos=%.3g normal=%.3g inverse=%.3g bary=%.3g depth=%.3g wrong_angle=%.2f %s\n",
      serial,c.name,counts[0],counts[1],counts[2],counts[3],mismatch,invalid,maxD,maxNear,maxT,maxPosition,maxNormal,maxInverse,maxBary,maxDepth,maxWrongAngle,pass?"PASS":"FAIL");
    if(pass&&(serial==1||serial==3)){
        const char* names[]={"ids","normals","wrong_normals","barycentric","distance","depth"};
        for(unsigned k=0;k<6;++k)pass=write_ppm(prefix+"_"+std::to_string(serial)+"_"+names[k]+".ppm",images[k])&&pass;
        if(!pass)std::fprintf(stderr,"Diagnostic image write failed\n");
    }return pass;
}
} // namespace surface_reference
