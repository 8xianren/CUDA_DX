// R.13.4诊断；ENABLE_DIRECT_LIGHT=1时启用R.13.5的Lambert矩形灯NEE。
RaytracingAccelerationStructure scene : register(t0);
#ifndef ENABLE_DIRECT_LIGHT
#define ENABLE_DIRECT_LIGHT 0
#endif
#ifndef ENABLE_PROGRESSIVE
#define ENABLE_PROGRESSIVE 0
#endif
#ifndef ENABLE_HISTORY
#define ENABLE_HISTORY 0
#endif
#if ENABLE_HISTORY && !ENABLE_PROGRESSIVE
#error History mode requires progressive mode
#endif
#if ENABLE_PROGRESSIVE && !ENABLE_DIRECT_LIGHT
#error Progressive mode requires direct lighting
#endif
StructuredBuffer<float3> vertices : register(t1); // 独立绑定原始VB，stride12。
ByteAddressBuffer indices : register(t2); // uint32 IB；Load3地址以字节为单位。
cbuffer View : register(b0) {
    row_major float4x4 invViewProjection; // offset0，64B；行向量mul(v,M)，CPU不转置。
    float4 eyeNear;                       // offset64：xyz相机位置，w前向near。
    float4 forwardMax;                    // offset80：xyz单位前向，w沿射线的有限TMax。
    uint4 viewRect;                       // offset96：左上x/y、视图宽/高。
    uint4 targetInfo;                     // offset112：输出宽/高、提交序号、光照测试mode（诊断时0）。
}; // 有效载荷128B；每个CPU上传槽按256B对齐，布局与分配步长是两层约定。
uint scene_inclusion_mask(){
#if ENABLE_HISTORY
    return (targetInfo.w>>8)&255u; // R.13.7用可见实例集合模拟场景变化，主/阴影射线必须一致。
#else
    return 255u;
#endif
}
#if ENABLE_PROGRESSIVE
#include "dxr_progressive_sampling.hlsli"
#endif
#if ENABLE_DIRECT_LIGHT
#include "dxr_direct_light.hlsli"
#endif
struct Payload {
    float4 positionT;       // 重心重建世界位置xyz，命中t；Miss的t=-1。
    float4 normalDepth;     // 世界几何法线xyz，视图前向距离。
    float4 inverseNormal;   // 逆转置法线xyz，reversed-Z深度。
    float4 wrongNormal;     // 故意错误的普通方向变换xyz，位置两路重建之差。
    float4 baryPrimitive;   // DXR重心u/v、PrimitiveIndex、命中标记1。
    uint id;               // 共84B，只作诊断；生产积分器不必携带整套中间量。
#if ENABLE_DIRECT_LIGHT
    float4 directLight,openLight; // 扩为116B；光照与无遮挡对照在线性RGB计算。
#endif
};
struct RayRecord {
    float4 originNear;    // xyz实际世界原点、w实际TMin。
    float4 directionHit;  // xyz实际单位方向、w实际DXR命中t（Miss=-1）。
    uint4 stamp;          // 绝对像素x/y、参数提交序号、命中ID；视口外ID=0xffffffff。
    float4 positionT,normalDepth,inverseNormal,wrongNormal,baryPrimitive;
#if ENABLE_DIRECT_LIGHT
    float4 directLight,openLight; // 输出stride160；不参与R.13.4的128B版本。
#endif
#if ENABLE_PROGRESSIVE
    float4 meanCount,sampleCoordinates; // stride192：均值/计数；像素xy与灯面uv四个随机维度。
#endif
};
RWStructuredBuffer<RayRecord> output : register(u0); // 诊断stride128/光照160，所有dispatch像素各写一项。
#if ENABLE_PROGRESSIVE
#include "dxr_progressive_accumulation.hlsli"
#endif

[shader("raygeneration")]
void RayGen() {
    uint2 pixel=DispatchRaysIndex().xy; // 本例dispatch覆盖整个输出，不等于ViewRect尺寸。
    RayRecord result=(RayRecord)0;
    result.stamp=uint4(pixel,targetInfo.z,0xffffffffu);
    uint index=pixel.y*targetInfo.x+pixel.x;
    if(any(pixel<viewRect.xy) || any(pixel>=viewRect.xy+viewRect.zw)) {
#if ENABLE_PROGRESSIVE
        store_progressive(index,result);
#else
        output[index]=result;
#endif
        return; // 外部区域也显式写标记，防止旧槽内容伪装成新结果。
    }
    float2 localPixel=float2(pixel-viewRect.xy);
    float2 offset=float2(.5,.5);
#if ENABLE_PROGRESSIVE
    offset=progressive_pixel_offset(index);
    result.sampleCoordinates=float4(offset,progressive_uniform(index,2),progressive_uniform(index,3));
    if(sampleControls.z&4u){
        // 隔离验证：0与(4,2,1)交替。绕过场景，专测零贡献、HDR和样本数。
        result.stamp.w=0;result.directLight=float4((sampleControls.x&1u)?float3(4,2,1):float3(0,0,0),0);
        store_progressive(index,result);return;
    }
#endif
    float2 uv=(localPixel+offset)/float2(viewRect.zw); // 矩阵无jitter，避免叠加两次偏移。
    float2 ndc=float2(2*uv.x-1,1-2*uv.y);
    // reversed-Z近端为1；最后一个1是选取NDC的齐次代表，不是原始clip.w。
    float4 h=mul(float4(ndc,1,1),invViewProjection);
    if(!all(isfinite(h)) || abs(h.w)<1e-8) {
        result.stamp.w=0xfffffffeu; output[index]=result; return;
    }
    float3 delta=h.xyz/h.w-eyeNear.xyz;
    float len2=dot(delta,delta);
    if(!isfinite(len2) || len2<=0) {
        result.stamp.w=0xfffffffeu; output[index]=result; return;
    }
    float3 direction=delta*rsqrt(len2);
    float cosForward=dot(direction,forwardMax.xyz);
    float tNear=eyeNear.w/cosForward;
    if(cosForward<=0 || !isfinite(tNear) || tNear<0 || tNear>forwardMax.w) {
        result.stamp.w=0xfffffffeu; output[index]=result; return;
    }
    RayDesc ray;
    ray.Origin=eyeNear.xyz; ray.Direction=direction;
    ray.TMin=tNear; ray.TMax=forwardMax.w;
    Payload p=(Payload)0; p.positionT.w=-2; p.id=0xfffffffeu;
    TraceRay(scene,RAY_FLAG_NONE,scene_inclusion_mask(),0,0,0,ray,p);
    result.originNear=float4(ray.Origin,ray.TMin);
    result.directionHit=float4(ray.Direction,p.positionT.w);
    result.positionT=p.positionT; result.normalDepth=p.normalDepth;
    result.inverseNormal=p.inverseNormal; result.wrongNormal=p.wrongNormal;
    result.baryPrimitive=p.baryPrimitive;
#if ENABLE_DIRECT_LIGHT
    result.directLight=p.directLight;result.openLight=p.openLight;
#endif
    result.stamp.w=p.id;
#if ENABLE_PROGRESSIVE
    store_progressive(index,result);
#else
    output[index]=result;
#endif
}
[shader("miss")]
void PrimaryMiss(inout Payload p) {
    p=(Payload)0;p.positionT.w=-1;
#if ENABLE_DIRECT_LIGHT
    // 常规模式黑背景且没有环境照明；白炉模式用白背景展示规定的恒定入射环境。
    if(targetInfo.w==3){p.directLight=float4(1,1,1,0);p.openLight=p.directLight;}
#endif
}
[shader("closesthit")]
void SurfaceHit(inout Payload p,in BuiltInTriangleIntersectionAttributes attr) {
    uint primitive=PrimitiveIndex();
    // 当前仅一个geometry，IB无子网格偏移；通用场景须加geometry对应的index/vertex基址。
    uint3 ids=indices.Load3(primitive*3*4);
    float3 a=vertices[ids.x],b=vertices[ids.y],c=vertices[ids.z];
    float2 uv=attr.barycentrics;
    // Q=a+u(b-a)+v(c-a)，三个权重为(1-u-v,u,v)。这里不额外做透视校正。
    float3 localPoint=(1-uv.x-uv.y)*a+uv.x*b+uv.y*c;
    float3x4 objectToWorld=ObjectToWorld3x4();
    // 此API返回3x4，按矩阵乘列位置使用；不是本课相机row_major 4x4的直接拷贝。
    float3 worldPoint=mul(objectToWorld,float4(localPoint,1));
    float3 aw=mul(objectToWorld,float4(a,1));
    float3 bw=mul(objectToWorld,float4(b,1));
    float3 cw=mul(objectToWorld,float4(c,1));
    float3 ng=normalize(cross(bw-aw,cw-aw)); // 垂直于两条世界边，由索引绕序决定正负。
    float3 no=normalize(cross(b-a,c-a));
    // B是上述列向量物体变换的线性块，WorldToObject3x4左上块为B^-1。
    // mul(no,B^-1)的分量等价于列向量B^-T*no，满足变换后法线与切线仍垂直。
    // 本课实例det(B)>0；负行列式会使绕序法线与未补符号的逆转置方向相反，不能盲比。
    float3 ni=normalize(mul(no,(float3x3)WorldToObject3x4()));
    float3 wrong=normalize(mul((float3x3)objectToWorld,no)); // 错误对照，不用于照明。
    float t=RayTCurrent();
    float3 rayPoint=WorldRayOrigin()+t*WorldRayDirection();
    float zView=dot(worldPoint-eyeNear.xyz,forwardMax.xyz);
    p.positionT=float4(worldPoint,t);
    p.normalDepth=float4(ng,zView);
    p.inverseNormal=float4(ni,eyeNear.w/zView); // 本课无限远reversed-Z，未写入深度纹理。
    p.wrongNormal=float4(wrong,length(worldPoint-rayPoint));
    p.baryPrimitive=float4(uv,float(primitive),1);
    p.id=InstanceID();
#if ENABLE_DIRECT_LIGHT
    uint2 pixel=DispatchRaysIndex().xy;
    estimate_direct(worldPoint,ng,-WorldRayDirection(),p.id,pixel.y*targetInfo.x+pixel.x,targetInfo.w&255u,
                    p.directLight,p.openLight);
#endif
}
