#pragma once
#include "geometry.h"
#include <type_traits>
namespace cuda_pt {
// 数值类型显式区分：GPU路径用float；CPU参考用double，但读取同一份float场景和相机输入。
// 共同的代数函数便于后续Megakernel/Wavefront只改变调度，不改变积分器。
template<class T> struct PVec {T x=0,y=0,z=0;};
template<class T> PT_HD inline PVec<T> PV(Vec3 p){return {T(p.x),T(p.y),T(p.z)};}
template<class T> PT_HD inline Vec3 FV(PVec<T> p){return {float(p.x),float(p.y),float(p.z)};}
template<class T> PT_HD inline PVec<T> operator+(PVec<T> a,PVec<T> b){return {a.x+b.x,a.y+b.y,a.z+b.z};}
template<class T> PT_HD inline PVec<T> operator-(PVec<T> a,PVec<T> b){return {a.x-b.x,a.y-b.y,a.z-b.z};}
template<class T> PT_HD inline PVec<T> operator*(PVec<T> a,T b){return {a.x*b,a.y*b,a.z*b};}
template<class T> PT_HD inline PVec<T> operator*(PVec<T> a,PVec<T> b){return {a.x*b.x,a.y*b.y,a.z*b.z};}
template<class T> PT_HD inline T PDot(PVec<T> a,PVec<T> b){return a.x*b.x+a.y*b.y+a.z*b.z;}
template<class T> PT_HD inline PVec<T> PCross(PVec<T> a,PVec<T> b){return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
template<class T> PT_HD inline T PSqrt(T v){if constexpr(std::is_same_v<T,float>)return sqrtf(v);else return sqrt(v);}
template<class T> PT_HD inline T PSin(T v){if constexpr(std::is_same_v<T,float>)return sinf(v);else return sin(v);}
template<class T> PT_HD inline T PCos(T v){if constexpr(std::is_same_v<T,float>)return cosf(v);else return cos(v);}
template<class T> PT_HD inline T PMax(T a,T b){return a>b?a:b;}
template<class T> PT_HD inline T PMin(T a,T b){return a<b?a:b;}
template<class T> PT_HD inline T MaxComponent(PVec<T> p){return PMax(p.x,PMax(p.y,p.z));}
template<class T> PT_HD inline PVec<T> PNormalize(PVec<T> p){return p*(T(1)/PSqrt(PDot(p,p)));}
template<class T> PT_HD inline bool PFinite(PVec<T> p){return p.x==p.x&&p.y==p.y&&p.z==p.z&&p.x<T(FLT_MAX)&&p.y<T(FLT_MAX)&&p.z<T(FLT_MAX)&&p.x>T(-FLT_MAX)&&p.y>T(-FLT_MAX)&&p.z>T(-FLT_MAX);}
template<class T> PT_HD inline T Pi(){return T(3.1415926535897932384626433832795);}
PT_HD inline uint32_t PathHash(uint32_t x){x=(x^(x>>16))*0x21f0aaadu;x=(x^(x>>15))*0x735a2d97u;return x^(x>>15);}
PT_HD inline float PathRandom(uint32_t pixel,uint32_t sample,uint32_t seed,uint32_t depth,uint32_t dimension){
    // 无状态随机维度：队列中的位置/线程号不参与随机数。相同路径被重新排序仍获得相同样本。
    // 23bit整数+.5乘2^-23得到严格(0,1)且float精确表示的值；double参考也读取这个值。
    uint32_t key=(pixel+1)*747796405u+(sample+1)*2891336453u+seed*277803737u+depth*1597334677u+dimension*3812015801u;
    return (float(PathHash(key)>>9)+.5f)*(1.f/8388608.f);
}
template<class T> PT_HD inline T PowerWeight(T a,T b){if(a<=0)return 0;T ratio=b/a;return T(1)/(T(1)+ratio*ratio);}
template<class T> PT_HD inline PVec<T> CosineDirection(PVec<T> normal,T u,T v){
    // 圆盘CDF r²=u，因此r=sqrt(u)；z=sqrt(1-u)。正交基将局部+z转为表面法线。
    T radius=PSqrt(u),phi=T(2)*Pi<T>()*v;
    PVec<T> helper=normal.z>T(.999)||normal.z<T(-.999)?PVec<T>{1,0,0}:PVec<T>{0,0,1};
    auto tangent=PNormalize(PCross(helper,normal)),bitangent=PCross(normal,tangent);
    return PNormalize(tangent*(radius*PCos(phi))+bitangent*(radius*PSin(phi))+normal*PSqrt(T(1)-u));
}
}
