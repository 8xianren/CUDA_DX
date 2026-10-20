// R.11 第二部分：全局资源 t0/u0 与每条 Hit record 的局部常量 b0 是两条绑定路径。
// Global Root Signature 仍由命令列表绑定 TLAS SRV、输出 buffer UAV。
RaytracingAccelerationStructure scene : register(t0);
RWStructuredBuffer<uint> output : register(u0);
// CPU 把两个 DWORD 顺序写在 identifier 后（record 的 +32/+36 字节）。
// local root signature 的 Num32BitValues=2，使 GPU 按此顺序取得 material 与 cookie。
// 这是 root constants，不是 CBV 地址；不用建立一块按 256B 对齐的 constant buffer。
cbuffer LocalData : register(b0) {
    uint material;
    uint cookie;
};
struct Payload { uint result; };

[shader("raygeneration")]
void RayGen() {
    uint x = DispatchRaysIndex().x;
    // 与第一部分相同：前三条击中 x=0 实例，4/5/6 击中 x=3 实例，3/7 为 Miss。
    float originX = (x < 4) ? (float(x) - 1.0) * 0.4 : 3.0 + (float(x) - 5.0) * 0.4;
    if (x == 3 || x == 7) originX = 10.0;
    RayDesc ray;
    ray.Origin = float3(originX, 0, -2);
    ray.Direction = float3(0, 0, 1);
    ray.TMin = 0.001;
    ray.TMax = 100;
    Payload payload;
    payload.result = 0xffffffff;
    // RayContribution=0、geometry multiplier=0、Miss index=0。
    // 两实例的 InstanceContributionToHitGroupIndex 分别为 0/1，故选不同 Hit record。
    // 本课只一种应用射线用途，不把 record 当成“射线类型”。
    TraceRay(scene, RAY_FLAG_NONE, 0xff, 0, 0, 0, ray, payload);
    output[x] = payload.result;
}
[shader("miss")]
void Miss(inout Payload payload) { payload.result = 0; }

// 高四位分别是 A/B 程序标记；中间两字节验证两项 local root 数据；低字节是 InstanceID。
// 两实例故意用相同 ID=7，因此不能靠 InstanceID 伪造“不同 Hit Group”结果。
// CPU 的 --swap-local 测试只交换 SBT 局部数据：高四位应不变，中间字节必须交换。
[shader("closesthit")]
void ClosestHitA(inout Payload payload, in BuiltInTriangleIntersectionAttributes attr) {
    payload.result = 0xA0000000u | ((material & 0xffu) << 16) | ((cookie & 0xffu) << 8) | InstanceID();
}
[shader("closesthit")]
void ClosestHitB(inout Payload payload, in BuiltInTriangleIntersectionAttributes attr) {
    payload.result = 0xB0000000u | ((material & 0xffu) << 16) | ((cookie & 0xffu) << 8) | InstanceID();
}
