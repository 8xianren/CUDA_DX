// R.11 第四部分：只验证 Hit 表寻址；Shadow 是应用定义的第二用途，不是 R.12 可见性算法。
RaytracingAccelerationStructure scene : register(t0);
RWStructuredBuffer<uint> output : register(u0);
// 两项内联 local root constants：第一项由CPU写入record身份；第二项为独立cookie。
cbuffer RecordData : register(b0) { uint recordCode; uint cookie; };
struct Payload { uint code; };
[shader("raygeneration")]
void RayGen() {
    // x=4*instance+2*geometry+raytype。两用途射向同一点，不用payload传组合答案。
    uint x=DispatchRaysIndex().x;
    uint instance=x/4, geometry=(x/2)%2, raytype=x%2;
    RayDesc ray;
    ray.Origin=float3(8.0*instance+3.0*geometry,0,-2);
    ray.Direction=float3(0,0,1); ray.TMin=0.001; ray.TMax=10;
    Payload p; p.code=0xffffffff; // 若未执行合法入口，保留哨兵让CPU验收失败。
    // TraceRay：AS、flags、mask、rayContribution、geometry乘数、Miss索引、RayDesc、payload。
    // recordIndex=instanceContribution + GeometryIndex()*2 + raytype。
    // 必须保留ClosestHit：本课Shadow入口输出身份，不使用SKIP_CLOSEST_HIT_SHADER。
    TraceRay(scene,RAY_FLAG_NONE,0xff,raytype,2,0,ray,p);
    output[x]=p.code; // 每调用独写一项uint，无原子、无跨线程共享。
}
[shader("miss")]
void Miss(inout Payload p) { p.code=0; }
// 高字节A/B证明实际执行Primary/Shadow入口；中间来自所选record的local数据。
// cookie若不符，输出失败哨兵。低字节真实InstanceID恒7，不用于选record。
[shader("closesthit")]
void PrimaryHit(inout Payload p, in BuiltInTriangleIntersectionAttributes attr) {
    p.code=cookie==0x5a ? (0xa0000000 | recordCode | InstanceID()) : 0xffffffff;
}
[shader("closesthit")]
void ShadowHit(inout Payload p, in BuiltInTriangleIntersectionAttributes attr) {
    p.code=cookie==0x5a ? (0xb0000000 | recordCode | InstanceID()) : 0xffffffff;
}
