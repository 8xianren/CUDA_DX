// PT.6：复用D.4根签名/SBT/提交，只让DXR返回最近命中的材质编号。
// 积分、采样和PDF暂在CPU逐项验收；不是已经实现GPU路径积分器。
struct ObjectRecord {row_major float4x4 world;uint material,node,mesh,padding;};
struct InputRay {float3 origin;float tmin;float3 direction;float tmax;};
RaytracingAccelerationStructure scene:register(t0);
StructuredBuffer<ObjectRecord> objects:register(t1);
StructuredBuffer<InputRay> rays:register(t6);
RWStructuredBuffer<float4> result:register(u0);
struct Payload {float4 value;};
[shader("raygeneration")]
void RayGen(){
    uint i=DispatchRaysIndex().x;InputRay r=rays[i];RayDesc ray;
    ray.Origin=r.origin;ray.Direction=r.direction;ray.TMin=r.tmin;ray.TMax=r.tmax;
    Payload p;p.value=0;
    // 固定不透明测试场景，一种射线一个HitGroup；无需在ClosestHit递归发射射线。
    TraceRay(scene,RAY_FLAG_FORCE_OPAQUE,255,0,0,0,ray,p);result[i]=p.value;
}
[shader("miss")]
void Miss(inout Payload p){p.value=0;}
[shader("closesthit")]
void ClosestHit(inout Payload p,in BuiltInTriangleIntersectionAttributes a){
    p.value=float4(objects[InstanceID()].material+1,RayTCurrent(),0,0);
}
