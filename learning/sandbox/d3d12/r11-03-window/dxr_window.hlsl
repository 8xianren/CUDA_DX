// R.11 第三部分：一条 RayGen 对应一个纹素，输出经 UAV texture 写入，而不是 root UAV buffer。
RaytracingAccelerationStructure scene : register(t0);
RWTexture2D<float4> output : register(u0);
// 仍使用第二部分两项内联局部常量。不同 HitGroup 用不同主颜色，参数影响亮度。
cbuffer LocalData : register(b0) { uint material; uint cookie; };
struct Payload { float4 color; };
[shader("raygeneration")]
void RayGen() {
    uint2 p = DispatchRaysIndex().xy;
    uint2 size = DispatchRaysDimensions().xy;
    // 正交相机：像素中心映射到世界 x=[-2,5], y=[-2,2]，y 翻转让三角形顶点朝上。
    // 两实例中心 x=0/3；射线沿 +Z。线程只写自己的像素，无跨像素数据竞争。
    float2 uv = (float2(p) + 0.5) / float2(size);
    RayDesc ray;
    ray.Origin = float3(-2.0 + uv.x * 7.0, 2.0 - uv.y * 4.0, -2.0);
    ray.Direction = float3(0,0,1); ray.TMin=0.001; ray.TMax=100;
    Payload payload; payload.color=float4(1,0,1,1); // 未执行合法命中/Miss 时显示品红哨兵。
    // 单 geometry/ray 用途；实例 contribution 0/1 是唯一改变 Hit record 索引的项。
    TraceRay(scene, RAY_FLAG_NONE, 0xff, 0, 0, 0, ray, payload);
    output[p] = payload.color;
}
[shader("miss")]
void Miss(inout Payload payload) { payload.color=float4(0.04,0.06,0.12,1); }
[shader("closesthit")]
void ClosestHitA(inout Payload payload, in BuiltInTriangleIntersectionAttributes attr) {
    payload.color=float4(0.75 + float(material & 0xffu)/1024.0, float(cookie & 0xffu)/1024.0, 0.05, 1);
}
[shader("closesthit")]
void ClosestHitB(inout Payload payload, in BuiltInTriangleIntersectionAttributes attr) {
    payload.color=float4(0.05, 0.65 + float(material & 0xffu)/1024.0, float(cookie & 0xffu)/1024.0, 1);
}
