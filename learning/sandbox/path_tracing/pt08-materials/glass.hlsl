#include "dielectric.hlsli"
// t0 TLAS、t1 80B对象表、t2 80B配置、u0每路径128B记录；复用共享DXR管线。
struct ObjectRecord {row_major float4x4 world;uint material,node,mesh,pad;};
struct Config {uint width,height,glassID,upperID;uint lowerID,seed,mode,pad;float4 parameters,upperLe,lowerLe;};
struct Record {float4 position,outgoing,beta,random,endpoint,L,wrong;uint4 diagnostics;};
struct Payload {uint material;float t;uint2 pad;};
RaytracingAccelerationStructure scene:register(t0);
StructuredBuffer<ObjectRecord> objects:register(t1);
StructuredBuffer<Config> configs:register(t2);
RWStructuredBuffer<Record> output:register(u0);
float Random(uint index,uint seed){
    // 每路径独立32位hash；保留23位并取格中心，可被CPU逐bit重放且永远不产生0/1端点。
    uint x=(index+1)*747796405u+seed*2891336453u+0x9e3779b9u;
    x=(x^(x>>16))*0x21f0aaadu;x=(x^(x>>15))*0x735a2d97u;x^=x>>15;
    return ((x>>9)+.5)/8388608.;
}
Payload Shoot(float3 origin,float3 direction){
    RayDesc ray;ray.Origin=origin;ray.Direction=direction;ray.TMin=1e-5;ray.TMax=100;
    // OPAQUE只禁止AnyHit对候选求交做拒绝处理，不禁止ClosestHit后显式生成折射射线。
    // 本节玻璃不是alpha镂空：必须命中界面，执行Fresnel和折射，再发下一条射线。
    Payload p=(Payload)0;TraceRay(scene,RAY_FLAG_FORCE_OPAQUE,255,0,0,0,ray,p);return p;
}
[shader("raygeneration")]
void RayGen(){
    Config c=configs[0];uint2 ij=DispatchRaysIndex().xy;uint index=ij.y*c.width+ij.x;
    float2 xy=(float2(ij)+.5)/float2(c.width,c.height)-.5;
    // parameters=(水平斜率,相机所在侧+1/-1,外部IOR,内部IOR)。z<0视为玻璃内部。
    float3 origin=float3(xy,c.parameters.y),d=normalize(float3(c.parameters.x,0,-c.parameters.y));
    Record r=(Record)0;Payload first=Shoot(origin,d);r.diagnostics.y=first.material;r.diagnostics.w=1;
    if(first.material!=c.glassID){output[index]=r;return;}
    float3 p=origin+first.t*d;p.z=0; // 仅本固定平面的浮点投影修正，不是通用网格起点偏移。
    float u=Random(index,c.seed);
    DielectricSample s=SampleDielectric(d,float3(0,0,1),c.parameters.z,c.parameters.w,u,c.mode);
    r.position=float4(p,first.t);r.outgoing=float4(s.direction,s.F);
    r.beta=float4(s.weight,s.etaScale,s.q2,s.mass);r.random=float4(u,s.pr,s.etaI,s.etaT);r.diagnostics.x=s.event;
    if(s.event==0){output[index]=r;return;}
    Payload second=Shoot(p,s.direction);r.diagnostics.z=second.material;r.diagnostics.w++;
    if(second.material!=0)r.endpoint=float4(p+second.t*s.direction,second.t);
    float3 emission=0;
    if(second.material==c.upperID&&s.direction.z>0)emission=c.upperLe.rgb;
    if(second.material==c.lowerID&&s.direction.z<0)emission=c.lowerLe.rgb;
    // 上一步必为delta，灯命中MIS权重1；本场景不生成NEE射线。
    bool lamp=second.material==c.upperID||second.material==c.lowerID;
    r.L=float4(s.weight*emission,lamp?1:0);
    // 错误对照独立存储：漏掉透射q²。它不反馈到正确路径状态。
    r.wrong=float4(r.L.rgb/(s.event==2?s.q2:1),0);
    output[index]=r;
}
[shader("miss")]
void Miss(inout Payload p){p.material=0;p.t=0;}
[shader("closesthit")]
void ClosestHit(inout Payload p,in BuiltInTriangleIntersectionAttributes attributes){
    p.material=objects[InstanceID()].material+1;p.t=RayTCurrent();
}
