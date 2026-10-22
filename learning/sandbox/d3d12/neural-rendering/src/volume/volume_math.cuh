#pragma once
#include "volume.h"
#include <cmath>

namespace neural::volume::detail {
// 不把矩阵/投影API藏进体积分：像素中心先变成相机平面方向，再换到世界坐标。
__host__ __device__ inline float3 Add(float3 a, float3 b) { return {a.x+b.x,a.y+b.y,a.z+b.z}; }
__host__ __device__ inline float3 Mul(float3 a, float t) { return {a.x*t,a.y*t,a.z*t}; }
__host__ __device__ inline float3 Direction(const Camera& c, const RenderOptions& o, int x, int y) {
    const float sx=(2.0f*(x+0.5f)/o.width-1)*c.tanHalfFovY*float(o.width)/o.height;
    const float sy=(1-2.0f*(y+0.5f)/o.height)*c.tanHalfFovY;
    float3 d=Add(c.forward,Add(Mul(c.right,sx),Mul(c.up,sy)));
    return Mul(d,1.0f/sqrtf(d.x*d.x+d.y*d.y+d.z*d.z));
}
// slab 法：三个轴分别给出进入/离开区间，求交集；平行轴显式处理，避免 0*inf=NaN。
__host__ __device__ inline bool Box(float3 p, float3 d, float& lo, float& hi) {
    lo=0; hi=1e20f;
    const float origin[3]={p.x,p.y,p.z}, dir[3]={d.x,d.y,d.z};
    for(int a=0;a<3;++a) {
        if(fabsf(dir[a])<1e-10f) { if(origin[a]<-1 || origin[a]>1) return false; }
        else {
            float a0=(-1-origin[a])/dir[a], a1=(1-origin[a])/dir[a];
            lo=fmaxf(lo,fminf(a0,a1)); hi=fminf(hi,fmaxf(a0,a1));
        }
    }
    return hi>lo;
}
// 紧支撑的解析密度：sigma0*(1-r²/R²)^2，边界密度和一阶导数都连续。
// sigma 的单位是世界长度的倒数，不是 alpha；中心完整弦的光学厚度为 16*sigma0*R/15。
__host__ __device__ inline float Density(float3 p) {
    const float r2=(p.x*p.x+p.y*p.y+p.z*p.z)/(0.65f*0.65f);
    const float q=fmaxf(0,1-r2);
    return 20*q*q;
}
// Transfer function 把标量密度/空间位置映射成每次相互作用的线性色。
// 颜色本身不乘密度；密度已在 alpha=1-exp(-sigma*dt) 中参与概率计算。
__host__ __device__ inline float3 Color(float3 p) {
    return {0.25f+0.55f*(p.x+1)*0.5f,0.15f+0.65f*(p.y+1)*0.5f,0.35f+0.45f*(p.z+1)*0.5f};
}
__host__ __device__ inline float Jitter(unsigned pixel, unsigned seed) {
    unsigned h=pixel ^ (seed*0x9e3779b9u); h^=h>>16; h*=0x7feb352du; h^=h>>15;
    return (h&0xffffffu)/16777216.0f;
}
// 每段求积颜色贡献 w=T*alpha；必须先用旧T累积，再更新T，不能交换两行。
__host__ __device__ inline void Accumulate(float sigma,float dt,float3 color,float& T,float3& C) {
    // 小sigma*dt时 1-exp(-x) 相减会丢有效位，-expm1(-x) 保留小量。
    const float alpha=-expm1f(-sigma*dt), weight=T*alpha;
    C=Add(C,Mul(color,weight)); T*=1-alpha;
}
} // namespace neural::volume::detail
