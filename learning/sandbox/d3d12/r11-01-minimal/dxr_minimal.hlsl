// R.11：8 条射线穿过两个 TLAS 实例，输出 0=Miss、1/2=两个 ClosestHit。
// t0 是加速结构 SRV，u0 是 RWStructuredBuffer UAV；绑定由 C++ 的 global root signature 完成。
RaytracingAccelerationStructure scene : register(t0);
RWStructuredBuffer<uint> output : register(u0);
struct Payload { uint result; };

[shader("raygeneration")]
void RayGen() {
    uint x = DispatchRaysIndex().x;
    // 三角形局部顶点 (-1,-1),(1,-1),(0,1)，实例中心分别是 x=0 和 x=3。
    // 像素 0/1/2 -> 首个实例；4/5/6 -> 第二个实例；3/7 -> 背景。
    float originX = (x < 4) ? (float(x) - 1.0) * 0.4 : 3.0 + (float(x) - 5.0) * 0.4;
    if (x == 3 || x == 7) originX = 10.0;
    RayDesc ray;
    ray.Origin = float3(originX, 0, -2);
    ray.Direction = float3(0, 0, 1);
    ray.TMin = 0.001;
    ray.TMax = 100;
    Payload payload;
    payload.result = 0xffffffff; // 哨兵：防止未调用 Miss/Hit 时被误判为有效输出。
    // 一个 ray type：RayContribution=0、Multiplier=0；实例 contribution 也为 0。
    // 所有命中都索引 SBT hit 表的第一个（唯一）HitGroup 记录。
    TraceRay(scene, RAY_FLAG_NONE, 0xff, 0, 0, 0, ray, payload);
    output[x] = payload.result;
}

[shader("miss")]
void Miss(inout Payload payload) { payload.result = 0; }

[shader("closesthit")]
void ClosestHit(inout Payload payload, in BuiltInTriangleIntersectionAttributes attr) {
    // 此处不使用重心坐标 attr。InstanceID 是 CPU 在描述符中填入的自定义值，不要求唯一。
    payload.result = InstanceID();
}
