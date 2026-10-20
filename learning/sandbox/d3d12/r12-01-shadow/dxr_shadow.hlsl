// R.12：确定性点光源直接光，迁移 PT.5 的有限可见性项；不是完整路径追踪。
RaytracingAccelerationStructure scene : register(t0);
// 每个测试输出两个 DWORD：可见性（0/1；主射线Miss=2）、线性亮度×1e6。
RWStructuredBuffer<uint2> output : register(u0);
struct PrimaryPayload { uint test; uint visible; uint quantized; };
struct ShadowPayload { uint visible; };

[shader("raygeneration")]
void RayGen() {
    uint test=DispatchRaysIndex().x;
    RayDesc ray;
    ray.Origin=float3(test==8 ? 100.0 : 4.0*test,0,-1);
    ray.Direction=float3(0,0,1); ray.TMin=0.001; ray.TMax=10;
    PrimaryPayload p; p.test=test; p.visible=0xffffffff; p.quantized=0xffffffff;
    // 主射线 mask=1，只看到接收表面，不看到 mask=2 的挡板。
    // 全实例 contribution=0，geometry multiplier=0；仅一条 Hit record。
    TraceRay(scene,RAY_FLAG_NONE,1,0,0,0,ray,p);
    output[test]=uint2(p.visible,p.quantized);
}
[shader("miss")]
void PrimaryMiss(inout PrimaryPayload p) { p.visible=2; p.quantized=0; }
[shader("miss")]
void ShadowMiss(inout ShadowPayload p) { p.visible=1; }

[shader("closesthit")]
void SurfaceHit(inout PrimaryPayload p, in BuiltInTriangleIntersectionAttributes attr) {
    // 求交距离从 DXR 取得；只支持本课平移实例，固定世界法线 +Z。
    // 生产模型需加载/插值顶点法线，并正确处理实例逆转置与朝向。
    float3 x=WorldRayOrigin()+RayTCurrent()*WorldRayDirection();
    float3 n=float3(0,0,1), light=float3(4.0*p.test,0,2);
    float3 delta=light-x; float distance=length(delta); float3 wi=delta/distance;
    // 偏移起点后，重新计算方向/距离，使 TMax 与实际 RayDesc 参数化一致。
    // PT.5 CPU 使用未偏移距离减epsilon；此处更严格针对偏移后的端点计算。
    float3 origin=x+0.0001*n;
    float shadowDistance=length(light-origin);
    RayDesc shadow; shadow.Origin=origin;
    shadow.Direction=(light-origin)/shadowDistance;
    shadow.TMin=(p.test==5) ? 0.00001 : 0.001;
    shadow.TMax=shadowDistance-0.001;
    if(p.test==2) shadow.TMax=4.0; // 故意越过点光源，让 z=3 挡板被错误当遮挡。
    if(p.test==7) shadow.TMax=shadowDistance+0.001; // 对照端点附近挡板。
    uint mask=(p.test==3) ? 1 : 3; // mask1排除mask2挡板；mask3包含表面和挡板。
    ShadowPayload s; s.visible=0; // 默认“遮挡”，只有完全 Miss 才改为可见。
    // OPAQUE 三角形：接受首次有效命中即可，且跳过 ClosestHit。
    // 命中时 payload 保持0；无命中执行 Miss index1。无需Shadow ClosestHit/HitGroup。
    // 两种 payload 由应用调用和Miss入口配对；DXR不会自动识别“阴影类型”。
    TraceRay(scene,RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER,
             mask,0,0,1,shadow,s);
    // 点光源 delta 模型：Lo = V * (rho/pi) * I * max(n·wi,0) / distance²。
    // rho=.5，I=8，距离2，cos=1 -> Lo=1/pi；不套面积光PDF或cos_light。
    float lo=s.visible*(0.5/3.141592653589793)*8.0*max(dot(n,wi),0)/(distance*distance);
    p.visible=s.visible; p.quantized=(uint)round(lo*1000000.0);
}
