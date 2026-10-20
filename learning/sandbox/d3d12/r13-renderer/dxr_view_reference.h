#pragma once
#include <DirectXMath.h>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cmath>
#include <cstdio>
#include <algorithm>
#include <stdexcept>

namespace view_reference {
using namespace DirectX;
constexpr unsigned CanvasW=384,CanvasH=256;
constexpr double Pi=3.14159265358979323846;
struct V3 {double x,y,z;};
inline V3 operator+(V3 a,V3 b){return {a.x+b.x,a.y+b.y,a.z+b.z};}
inline V3 operator-(V3 a,V3 b){return {a.x-b.x,a.y-b.y,a.z-b.z};}
inline V3 operator*(V3 a,double s){return {a.x*s,a.y*s,a.z*s};}
inline double dot(V3 a,V3 b){return a.x*b.x+a.y*b.y+a.z*b.z;}
inline V3 cross(V3 a,V3 b){return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
inline double length(V3 a){return std::sqrt(dot(a,a));}
inline bool finite(V3 a){return std::isfinite(a.x)&&std::isfinite(a.y)&&std::isfinite(a.z);}
inline V3 unit(V3 a){double n=length(a);if(!finite(a)||!std::isfinite(n)||n<1e-12)throw std::runtime_error("invalid camera direction");return a*(1/n);}
inline V3 vec(const float* a){return {a[0],a[1],a[2]};}
inline XMVECTOR xm(V3 a,float w){return XMVectorSet(float(a.x),float(a.y),float(a.z),w);}

// 不传CPU指针/SIMD寄存器对象/bool；只用固定32位标量构成明确的二进制协议。
struct ViewData {
    XMFLOAT4X4 invViewProjection;
    float eyeNear[4]; float forwardMax[4];
    uint32_t viewRect[4]; uint32_t targetInfo[4];
};
static_assert(sizeof(float)==4 && sizeof(ViewData)==128,"CB payload");
static_assert(offsetof(ViewData,eyeNear)==64 && offsetof(ViewData,forwardMax)==80,"float offsets");
static_assert(offsetof(ViewData,viewRect)==96 && offsetof(ViewData,targetInfo)==112,"uint offsets");
struct GpuRecord {float originNear[4],directionHit[4];uint32_t stamp[4];};
static_assert(sizeof(GpuRecord)==48,"RWStructuredBuffer stride");
struct Vertex {float x,y,z;};
// 新世界坐标中的前方矩形：x=4，y向右、z向上；尺寸选用二进制可精确表示的值。
inline const Vertex Vertices[]={{4,-1.375f,-.9375f},{4,1.375f,-.9375f},{4,1.375f,.9375f},{4,-1.375f,.9375f}};
inline const uint32_t Indices[]={0,1,2,0,2,3};
static_assert(sizeof(Vertex)==12,"BLAS vertex stride");
struct Case {
    const char* name="base";V3 eye{0,0,0},forward{1,0,0};
    double fov=60,nearPlane=.1;unsigned x=0,y=0,w=320,h=180;
};
inline std::array<Case,8> cases(){
    std::array<Case,8> result{}; // 每组从同一基线出发，只改一类参数；最后恢复基线检验槽复用。
    result[1].name="translation";result[1].eye={0,.25,.125};
    result[2].name="rotation";result[2].forward={1,.12,.08};
    result[3].name="fov";result[3].fov=50;
    result[4].name="aspect";result[4].h=200;
    result[5].name="viewrect-offset";result[5].x=37;result[5].y=19;
    result[6].name="near-5";result[6].nearPlane=5;
    result[7].name="base-again";return result;
}
inline ViewData make_view(const Case& c,uint32_t serial){
    if(!finite(c.eye)||!std::isfinite(c.fov)||c.fov<=0||c.fov>=180||
       !std::isfinite(c.nearPlane)||c.nearPlane<=0||c.nearPlane>=20||
       c.w==0||c.h==0||uint64_t(c.x)+c.w>CanvasW||uint64_t(c.y)+c.h>CanvasH)
        throw std::runtime_error("invalid view parameters");
    V3 f=unit(c.forward),r=unit(cross({0,0,1},f)),u=cross(f,r);
    XMMATRIX view=XMMatrixLookToLH(xm(c.eye,1),xm(f,0),xm(u,0));
    float sy=float(1/std::tan(c.fov*Pi/360)),sx=float(sy/(double(c.w)/c.h));
    XMMATRIX proj=XMMatrixSet(sx,0,0,0,0,sy,0,0,0,0,0,1,0,0,float(c.nearPlane),0);
    XMVECTOR det;XMMATRIX inv=XMMatrixInverse(&det,XMMatrixMultiply(view,proj));
    if(!std::isfinite(XMVectorGetX(det))||std::fabs(XMVectorGetX(det))<1e-12f)throw std::runtime_error("singular view projection");
    ViewData d{};XMStoreFloat4x4(&d.invViewProjection,inv); // 原样按行存储，绝不再transpose。
    for(int i=0;i<4;++i)for(int j=0;j<4;++j)if(!std::isfinite(d.invViewProjection.m[i][j]))throw std::runtime_error("invalid inverse");
    d.eyeNear[0]=float(c.eye.x);d.eyeNear[1]=float(c.eye.y);d.eyeNear[2]=float(c.eye.z);d.eyeNear[3]=float(c.nearPlane);
    d.forwardMax[0]=float(f.x);d.forwardMax[1]=float(f.y);d.forwardMax[2]=float(f.z);d.forwardMax[3]=20;
    d.viewRect[0]=c.x;d.viewRect[1]=c.y;d.viewRect[2]=c.w;d.viewRect[3]=c.h;
    d.targetInfo[0]=CanvasW;d.targetInfo[1]=CanvasH;d.targetInfo[2]=serial;return d;
}
inline bool verify(const GpuRecord* gpu,const Case& c,uint32_t serial){
    const V3 f=unit(c.forward),r=unit(cross({0,0,1},f)),u=cross(f,r);
    const double tanHalf=std::tan(c.fov*Pi/360),aspect=double(c.w)/c.h;
    unsigned invalid=0,mismatch=0,hits=0,outside=0;double maxD=0,maxOrigin=0,maxNear=0,maxT=0;
    for(unsigned y=0;y<CanvasH;++y)for(unsigned x=0;x<CanvasW;++x){
        const GpuRecord& g=gpu[y*CanvasW+x];
        if(g.stamp[0]!=x||g.stamp[1]!=y||g.stamp[2]!=serial)++invalid;
        bool valid=true;for(float a:g.originNear)valid &= std::isfinite(a);for(float a:g.directionHit)valid &= std::isfinite(a);
        if(!valid){++invalid;continue;}
        const bool in=x>=c.x&&y>=c.y&&x<c.x+c.w&&y<c.y+c.h;
        if(!in){
            ++outside;if(g.stamp[3]!=0xffffffffu)++invalid;
            for(float a:g.originNear)if(a!=0)++invalid;for(float a:g.directionHit)if(a!=0)++invalid;
            continue;
        }
        // 参考方向直接用相机基和FOV计算，完全不读取上传矩阵，避免同一矩阵错误自我验证。
        const double sx=(2*(double(x-c.x)+.5)/c.w-1)*aspect*tanHalf;
        const double sy=(1-2*(double(y-c.y)+.5)/c.h)*tanHalf;
        V3 d=unit(f+r*sx+u*sy);double nearT=c.nearPlane/dot(d,f);
        maxD=std::max(maxD,length(vec(g.directionHit)-d));maxOrigin=std::max(maxOrigin,length(vec(g.originNear)-c.eye));
        maxNear=std::max(maxNear,std::fabs(g.originNear[3]-nearT));
        // 独立解析矩形求交，不调用GPU结果：先解x=4，再检查y/z边界和TMin/TMax。
        const double t=(4-c.eye.x)/d.x;V3 q=c.eye+d*t;
        const bool hit=t>=nearT&&t<=20&&std::fabs(q.y)<=1.375&&std::fabs(q.z)<=.9375;
        if(g.stamp[3]!=(hit?1u:0u))++mismatch;
        if(hit){++hits;maxT=std::max(maxT,std::fabs(g.directionHit[3]-t));}
        else if(g.directionHit[3]!=-1)++invalid;
    }
    const bool pass=invalid==0&&mismatch==0&&maxD<1e-5&&maxOrigin<1e-6&&maxNear<1e-5&&maxT<1e-4&&
                    ((c.nearPlane==5)?hits==0:hits>0);
    std::printf("frame=%u %-15s rays=%u outside=%u hits=%u mismatch=%u invalid=%u dir=%.3g origin=%.3g near=%.3g hitT=%.3g %s\n",
      serial,c.name,c.w*c.h,outside,hits,mismatch,invalid,maxD,maxOrigin,maxNear,maxT,pass?"PASS":"FAIL");
    return pass;
}
} // namespace view_reference
