#include "mirror.hlsli"
// 共享根签名：t0 TLAS，t1 80B对象记录，t2 64B本课配置，u0 96B逐路径记录。
struct ObjectRecord {row_major float4x4 world;uint material,node,mesh,pad;};
struct Config {uint width,height,mirrorID,lampID;float4 slope;float4 R,Le;};
struct Record {float4 position,reflected,beta,L,wrong;uint4 diagnostics;};
struct Payload {uint material;float t;uint2 pad;};
RaytracingAccelerationStructure scene:register(t0);
StructuredBuffer<ObjectRecord> objects:register(t1);
StructuredBuffer<Config> configs:register(t2);
RWStructuredBuffer<Record> output:register(u0);
Payload Shoot(float3 o,float3 d){
    // fixture为米尺度、不透明平面。正TMin避免从镜面原点再次命中自己；不是通用误差界偏移。
    RayDesc ray;ray.Origin=o;ray.Direction=d;ray.TMin=1e-5;ray.TMax=100;
    Payload p=(Payload)0;TraceRay(scene,RAY_FLAG_FORCE_OPAQUE,255,0,0,0,ray,p);return p;
}
[shader("raygeneration")]
void RayGen(){
    Config c=configs[0];uint2 ij=DispatchRaysIndex().xy;uint index=ij.y*c.width+ij.x;
    float2 xy=((float2(ij)+.5)/float2(c.width,c.height)*2-1)*1.6;
    float3 origin=float3(xy,1),d=normalize(float3(c.slope.xy,-1));
    Record r=(Record)0;Payload first=Shoot(origin,d);r.diagnostics.x=first.material;r.diagnostics.z=1;
    if(first.material!=c.mirrorID){output[index]=r;return;}
    float3 p=origin+first.t*d;p.z=0; // 已知平面的解析投影只消除本fixture的浮点残差。
    MirrorSample s=SampleMirror(-d,float3(0,0,1),c.R.rgb);
    r.position=float4(p,first.t);r.reflected=float4(s.wi,s.eventMass);r.beta=float4(s.weight,s.isDelta);
    // 纯delta没有可供普通面积灯NEE积分的连续部分，因此不发阴影射线；diagnostics.w保持0。
    Payload second=Shoot(p,s.wi);r.diagnostics.y=second.material;r.diagnostics.z++;
    if(second.material==c.lampID){
        // 从delta事件到发光面，竞争的连续灯采样在这个单点方向的概率质量为0，MIS权重为1。
        r.L=float4(s.weight*c.Le.rgb,1);
        float distance2=second.t*second.t;float pLight=distance2/(4*s.wi.z);
        // 故意错误的对照：把eventMass=1当成sr^-1的密度，与灯的连续密度比较。
        // 该值仅写入诊断列，绝不参与正确L；会无端削弱镜中灯的亮度。
        float wrongW=s.eventMass*s.eventMass/(s.eventMass*s.eventMass+pLight*pLight);
        r.wrong=float4(r.L.rgb*wrongW,pLight);
    }
    output[index]=r;
}
[shader("miss")]
void Miss(inout Payload p){p.material=0;p.t=0;}
[shader("closesthit")]
void ClosestHit(inout Payload p,in BuiltInTriangleIntersectionAttributes attributes){
    p.material=objects[InstanceID()].material+1;p.t=RayTCurrent();
}
