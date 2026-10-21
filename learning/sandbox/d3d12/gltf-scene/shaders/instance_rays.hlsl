#include "instance_shared.hlsli"
RaytracingAccelerationStructure scene : register(t0);
RWStructuredBuffer<uint4> result : register(u0);
struct Payload {uint4 ids;};
[shader("raygeneration")]
void RayGen() {
    uint2 p=DispatchRaysIndex().xy;
    // 与viewport相同的像素中心和Y翻转；不加随机抖动，便于光栅/CPU逐像素对照。
    float2 ndc=float2(2*(p.x+.5)/width-1,1-2*(p.y+.5)/height);
    float4 nearH=mul(inverseViewProjection,float4(ndc,0,1));
    float4 farH=mul(inverseViewProjection,float4(ndc,1,1));
    float3 nearP=nearH.xyz/nearH.w,delta=farH.xyz/farH.w-nearP;
    RayDesc ray;ray.Origin=nearP;ray.Direction=normalize(delta);ray.TMin=0;ray.TMax=length(delta);
    Payload payload;payload.ids=0;
    // 一种射线/一个HitGroup，强制opaque只服务ID诊断，不代表MASK/BLEND已实现。
    TraceRay(scene,RAY_FLAG_FORCE_OPAQUE,0xff,0,0,0,ray,payload);
    result[p.y*width+p.x]=payload.ids;
}
[shader("miss")]
void Miss(inout Payload payload){payload.ids=0;}
[shader("closesthit")]
void ClosestHit(inout Payload payload,in BuiltInTriangleIntersectionAttributes attributes) {
    uint id=InstanceID();
    payload.ids=uint4(id+1,objects[id].material+1,PrimitiveIndex()+1,0);
}
