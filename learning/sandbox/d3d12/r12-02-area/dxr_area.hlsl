// R.12 第二部分：矩形面积光 NEE。每个 DispatchRays 调用只估计一个光源样本，
// 不在 ClosestHit 内跑长循环；CPU 在 Fence 完成后平均全部样本（包括零贡献）。
// 这是线性标量光照/可见性验收，不是像素图像、间接光或完整路径追踪。
RaytracingAccelerationStructure scene : register(t0);
RWStructuredBuffer<float4> output : register(u0);
static const uint SampleCount = 4096;
static const float Pi = 3.14159265358979323846;
// 20B 主 payload：case 编号 + 16B 结果。结果为贡献、可见性、方向PDF、光源余弦。
// 阴影仍为独立4B payload；所有阴影调用均跳过接收主payload的ClosestHit。
struct PrimaryPayload { uint test; float4 result; };
struct ShadowPayload { uint visible; };

// 无状态整数哈希：样本编号和维度直接决定随机数，方便CPU/GPU逐样本复现。
// 32位无符号运算模2^32回绕；取高16位后映射到开区间(0,1)，避免端点舍入为1。
// 固定种子只保证本例可复现，不证明随机变量严格独立，也不是生产采样器选型。
uint hash_u32(uint x) {
    x ^= x >> 16; x *= 0x7feb352d;
    x ^= x >> 15; x *= 0x846ca68b;
    x ^= x >> 16; return x;
}
float uniform_dimension(uint sample, uint dimension) {
    uint bits = hash_u32((2 * sample + dimension) ^ 0x9e3779b9);
    return (float(bits >> 16) + 0.5) / 65536.0;
}

[shader("raygeneration")]
void RayGen() {
    uint2 id = DispatchRaysIndex().xy; // x=样本编号，y=场景对照编号，不是图像像素。
    RayDesc ray;
    // 与第一部分相同的诊断主射线：从下方命中固定+Z接收面，无背面剔除。
    // 本课只核对直接光公式；通用相机/材质正反面在后续成像中处理。
    ray.Origin = float3(8.0 * id.y, 0, -1);
    ray.Direction = float3(0,0,1); ray.TMin = 0.001; ray.TMax = 2;
    PrimaryPayload p; p.test = id.y; p.result = float4(-1,-1,-1,-1);
    TraceRay(scene, RAY_FLAG_NONE, 1, 0, 0, 0, ray, p);
    // 每次调用独占一个16B元素，无原子加法，无不同调用之间的数据竞争。
    output[id.y * SampleCount + id.x] = p.result;
}
[shader("miss")]
void PrimaryMiss(inout PrimaryPayload p) { p.result = float4(-1,-1,-1,-1); }
[shader("miss")]
void ShadowMiss(inout ShadowPayload p) { p.visible = 1; }

[shader("closesthit")]
void SurfaceHit(inout PrimaryPayload p, in BuiltInTriangleIntersectionAttributes attr) {
    float3 x = WorldRayOrigin() + RayTCurrent() * WorldRayDirection();
    float3 n = float3(0,0,1);
    // 一盏参数化矩形灯：U/V为单位正交轴，h为两方向相同半边长，面积4h²。
    // 0无遮挡，1部分遮挡，2灯背向，3灯后挡板，4小灯，5远灯，6斜灯，7全遮挡。
    // 灯不放入TLAS，仅作为采样/发光参数；因此本例不能通过主射线看见灯本身。
    float height = p.test == 5 ? 6.0 : 3.0;
    float h = p.test == 4 ? 0.5 : 1.0;
    float3 center = float3(8.0 * p.test, 0, height);
    float3 u = float3(1,0,0);
    float3 v = p.test == 2 ? float3(0,1,0) : float3(0,-1,0);
    if (p.test == 6) v = float3(0,-0.8,0.6); // 单位轴；改变朝向，也改变灯点的高度。
    float3 nl = normalize(cross(u,v));
    float area = 4 * h * h;
    uint sample = DispatchRaysIndex().x;
    float su = (2 * uniform_dimension(sample,0) - 1) * h;
    float sv = (2 * uniform_dimension(sample,1) - 1) * h;
    float3 q = center + su*u + sv*v;

    // 物理几何量必须从真实着色点x计算；ray origin偏移只用于数值可见性查询。
    float3 delta = q-x;
    float dist2 = dot(delta,delta);
    if (!(dist2 > 1e-8)) { p.result = float4(-1,-1,-1,-1); return; }
    float3 wi = delta / sqrt(dist2);
    float cos_surface = max(dot(n,wi),0);
    float cos_light = max(dot(nl,-wi),0);
    // 单面发光的背面直接返回零，不先除以cos_light，也不重抽直到得到正面样本。
    if (cos_surface <= 0 || cos_light <= 0) { p.result = float4(0,0,0,0); return; }
    float pdf_A = 1 / area;
    float pdf_omega = pdf_A * dist2 / cos_light;

    float3 origin = x + 0.0001*n;
    float shadowDistance = length(q-origin);
    if (!(shadowDistance > 0.002)) { p.result = float4(-1,-1,-1,-1); return; }
    RayDesc shadow;
    shadow.Origin = origin; shadow.Direction = (q-origin) / shadowDistance;
    shadow.TMin = 0.001; shadow.TMax = shadowDistance - 0.001;
    ShadowPayload s; s.visible = 0;
    TraceRay(scene, RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER,
             3, 0, 0, 1, shadow, s);
    // Le是辐亮度，rho=.7。pω已带有距离平方/光源余弦，不能再重复乘几何项。
    // 遮挡样本也写入输出（贡献为0），归约分母永远为4096，而非可见样本数。
    float value = s.visible * 5.0 * (0.7/Pi) * cos_surface / pdf_omega;
    p.result = float4(value, float(s.visible), pdf_omega, cos_light);
}
