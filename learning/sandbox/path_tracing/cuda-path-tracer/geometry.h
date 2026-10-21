#pragma once
#include <cmath>
#include <cstdint>
#include <cfloat>
#ifdef __CUDACC__
#define PT_HD __host__ __device__
#else
#define PT_HD
#endif
namespace cuda_pt {
constexpr uint32_t Invalid=0xffffffffu,LeafBit=0x80000000u;
struct Vec3 {float x=0,y=0,z=0;};
PT_HD inline Vec3 operator+(Vec3 a,Vec3 b){return {a.x+b.x,a.y+b.y,a.z+b.z};}
PT_HD inline Vec3 operator-(Vec3 a,Vec3 b){return {a.x-b.x,a.y-b.y,a.z-b.z};}
PT_HD inline Vec3 operator*(Vec3 a,float b){return {a.x*b,a.y*b,a.z*b};}
PT_HD inline float Dot(Vec3 a,Vec3 b){return a.x*b.x+a.y*b.y+a.z*b.z;}
PT_HD inline Vec3 Cross(Vec3 a,Vec3 b){return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
PT_HD inline Vec3 Normalize(Vec3 a){float n=Dot(a,a);return n>0?a*(1/sqrtf(n)):Vec3{};}
PT_HD inline float Axis(Vec3 a,unsigned axis){return axis==0?a.x:axis==1?a.y:a.z;}
PT_HD inline bool Finite(float a){return a==a&&fabsf(a)<=FLT_MAX;}
PT_HD inline bool Finite(Vec3 a){return Finite(a.x)&&Finite(a.y)&&Finite(a.z);}
PT_HD inline Vec3 Min(Vec3 a,Vec3 b){return {fminf(a.x,b.x),fminf(a.y,b.y),fminf(a.z,b.z)};}
PT_HD inline Vec3 Max(Vec3 a,Vec3 b){return {fmaxf(a.x,b.x),fmaxf(a.y,b.y),fmaxf(a.z,b.z)};}
// 明确的文件/GPU布局：三个世界顶点各占16B（xyz+身份），尾部16B保存稳定全局ID。
// BVH只重排uint32索引，不改变Triangle数组顺序；命中ID可直接映射回instance/primitive。
struct alignas(16) Triangle {
    Vec3 a;uint32_t instance=0;Vec3 b;uint32_t primitive=0;Vec3 c;uint32_t material=0;
    uint32_t id=0,pad0=0,pad1=0,pad2=0;
};
struct alignas(16) Material {Vec3 base;float pad0=0;Vec3 emission;float pad1=0;};
struct Ray {Vec3 origin;float tmin=0;Vec3 direction;float tmax=1000;};
struct Hit {float t=0,u=0,v=0;uint32_t id=Invalid;};
struct Counters {uint32_t boxes=0,triangles=0,stackMax=0,error=0;};
struct Result {Hit hit;Counters counts;};
// 32B节点：internal的first/second为子节点索引；leaf的first为order起点，second高位标leaf，低位为数量。
struct Node {Vec3 lower;uint32_t first=0;Vec3 upper;uint32_t second=0;};
static_assert(sizeof(Triangle)==64&&sizeof(Material)==32&&sizeof(Ray)==32&&sizeof(Node)==32&&sizeof(Result)==32);
PT_HD inline bool IsLeaf(const Node& node){return (node.second&LeafBit)!=0;}

PT_HD inline bool IntersectBounds(const Ray& ray,Vec3 lo,Vec3 hi,float limit,float& entry,float& exit){
    // 每个坐标轴给出允许的t区间，三轴求交。与当前最近命中的limit求交，可剪掉更远子树。
    // 对精确±0方向单独判断slab包含关系，避免边界处0*(1/0)产生NaN。
    entry=ray.tmin;exit=fminf(ray.tmax,limit);
    for(unsigned axis=0;axis<3;++axis){
        float origin=Axis(ray.origin,axis),direction=Axis(ray.direction,axis),a=Axis(lo,axis),b=Axis(hi,axis);
        if(direction==0){if(origin<a||origin>b)return false;continue;}
        float near=(a-origin)/direction,far=(b-origin)/direction;
        if(near>far){float temp=near;near=far;far=temp;}
        entry=fmaxf(entry,near);exit=fminf(exit,far);if(entry>exit)return false;
    }return entry<=exit; // 闭区间：恰好接触盒子边界不能被错误剔除。
}
PT_HD inline void IntersectTriangle(const Ray& ray,const Triangle& triangle,Hit& closest){
    // o+t*d=a+u*(b-a)+v*(c-a)，用标量三重积解3×3约束；不做背面剔除。
    // u,v>=0且u+v<=1是三角形内部条件，t限制在[tmin,tmax]和当前最近距离内。
    Vec3 e1=triangle.b-triangle.a,e2=triangle.c-triangle.a,p=Cross(ray.direction,e2);
    float det=Dot(e1,p);if(det==0)return; // 包含退化/精确平行情形；本课不是watertight求交器。
    float inv=1/det;Vec3 offset=ray.origin-triangle.a;
    float u=Dot(offset,p)*inv;if(u<0||u>1)return;
    Vec3 q=Cross(offset,e1);float v=Dot(ray.direction,q)*inv;if(v<0||u+v>1)return;
    float t=Dot(e2,q)*inv;if(!Finite(t)||!Finite(u)||!Finite(v)||t<ray.tmin||t>ray.tmax||t>closest.t)return;
    // 精确相同float t时稳定选择更小ID；不使用宽松epsilon把更远三角形当成同一距离。
    if(t<closest.t||triangle.id<closest.id)closest={t,u,v,triangle.id};
}
PT_HD inline Result TraceBrute(const Triangle* triangles,uint32_t count,const Ray& ray){
    Result result{};result.hit.t=ray.tmax;
    for(uint32_t i=0;i<count;++i){IntersectTriangle(ray,triangles[i],result.hit);++result.counts.triangles;}return result;
}
PT_HD inline Result TraceBvh(const Triangle* triangles,uint32_t triangleCount,const Node* nodes,uint32_t nodeCount,
    const uint32_t* order,const Ray& ray){
    Result result{};result.hit.t=ray.tmax;if(nodeCount==0)return result;
    // 每条射线独有LIFO栈。动态索引数组可能放在线程local memory，不等于shared memory或必然寄存器。
    // CPU构建验证最大深度<64；仍显式检测溢出，不能越界后伪装miss。
    struct StackItem {uint32_t index;float entry;};StackItem stack[64];unsigned size=0;
    float entry,exit;++result.counts.boxes;
    if(!IntersectBounds(ray,nodes[0].lower,nodes[0].upper,result.hit.t,entry,exit))return result;
    stack[size++]={0,entry};
    while(size){
        result.counts.stackMax=size>result.counts.stackMax?size:result.counts.stackMax;
        StackItem current=stack[--size];if(current.entry>result.hit.t)continue;
        if(current.index>=nodeCount){result.counts.error=1;return result;}Node node=nodes[current.index];
        if(IsLeaf(node)){
            uint32_t count=node.second&~LeafBit;
            if(node.first>triangleCount||count>triangleCount-node.first){result.counts.error=2;return result;}
            for(uint32_t j=0;j<count;++j){uint32_t i=order[node.first+j];if(i>=triangleCount){result.counts.error=3;return result;}
                IntersectTriangle(ray,triangles[i],result.hit);++result.counts.triangles;}
        }else{
            if(node.first>=nodeCount||node.second>=nodeCount){result.counts.error=4;return result;}
            Node left=nodes[node.first],right=nodes[node.second];float le,lx,re,rx;result.counts.boxes+=2;
            bool l=IntersectBounds(ray,left.lower,left.upper,result.hit.t,le,lx),r=IntersectBounds(ray,right.lower,right.upper,result.hit.t,re,rx);
            unsigned needed=unsigned(l)+unsigned(r);if(size+needed>64){result.counts.error=5;return result;}
            // 先压远节点、再压近节点，LIFO会先弹近者。找到命中后只缩短limit，不立刻结束遍历。
            if(l&&r){if(le<=re){stack[size++]={node.second,re};stack[size++]={node.first,le};}
                else{stack[size++]={node.first,le};stack[size++]={node.second,re};}}
            else if(l)stack[size++]={node.first,le};else if(r)stack[size++]={node.second,re};
        }
    }return result;
}
}
