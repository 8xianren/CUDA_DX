// R.13 第一部分：每像素一条针孔相机主射线，输出可独立检查的几何属性。
// 不采样灯、不做渐进累积；先验证相机、PrimitiveIndex、顶点读取和世界法线。
RaytracingAccelerationStructure scene : register(t0);
// BLAS保存遍历结构，并不替应用暴露原始顶点属性：显式把VB/IB另绑为SRV。
// 顶点float3 stride12；索引uint32连续排列，每个三角形3项，共12B。
StructuredBuffer<float3> vertices : register(t1);
ByteAddressBuffer indices : register(t2);
// CPU以16个32位root constants传入b0，四个float4与CPU CameraData严格对应。
cbuffer Camera : register(b0) {
    float4 eyeTan;       // xyz世界相机位置；w=tan(垂直FOV/2)。
    float4 rightAspect;  // xyz世界右向；w=宽/高。
    float4 cameraUp;     // xyz世界上向；w填0。
    float4 cameraForward;// xyz世界前向；w填0。
};
struct PixelResult {
    float4 positionT; // xyz世界命中点；w=单位方向下的射线距离，Miss=-1。
    float4 normalID;  // xyz世界几何法线；w为小整数InstanceID（仅1..3）。
    float4 baryPrim;  // xy内建重心u/v；z为PrimitiveIndex；w=1命中、0 Miss。
};
RWStructuredBuffer<PixelResult> output : register(u0); // stride48，每像素独占一项。

[shader("raygeneration")]
void RayGen() {
    uint2 pixel = DispatchRaysIndex().xy;
    uint2 size = DispatchRaysDimensions().xy;
    // +0.5取像素中心。屏幕y向下、相机Up向上，因此sy使用1-2v。
    // 对称透视、无jitter、方形像素；F/R/U为世界空间单位正交基。
    // 虚拟成像平面中心E+F，满足dot(Q-E,F)=1：半高tan(FOV/2)，半宽aspect*tan(FOV/2)。
    // 这是世界空间中人为选择的平面，不是NDC平面，也不是由near参数确定的裁剪面。
    // normalize只把Q-E变成单位方向；单位方向端点位于单位球面，不再位于此平面。
    float2 uv = (float2(pixel) + 0.5) / float2(size);
    float sx = (2*uv.x-1) * rightAspect.w * eyeTan.w;
    float sy = (1-2*uv.y) * eyeTan.w;
    RayDesc ray;
    ray.Origin = eyeTan.xyz;
    ray.Direction = normalize(cameraForward.xyz + sx*rightAspect.xyz + sy*cameraUp.xyz);
    // 这里限制沿单位射线的距离，并不复现光栅相机的near/far平面。
    // 若near/far表示前向距离，且dot(D,F)>0，则对应tNear=near/dot(D,F)、tFar=far/dot(D,F)。
    ray.TMin = 0.001; ray.TMax = 100;
    PixelResult p;
    p.positionT=float4(0,0,0,-2); p.normalID=0; p.baryPrim=0; // -2表示未正确写结果。
    // 本节只有主射线，一个Miss和一个HitGroup；各实例contribution=0。
    // 不剔除背面，保留几何法线原始绕序；通用正反面材质稍后讨论。
    TraceRay(scene,RAY_FLAG_NONE,0xff,0,0,0,ray,p);
    output[pixel.y*size.x+pixel.x]=p;
}
[shader("miss")]
void PrimaryMiss(inout PixelResult p) {
    p.positionT=float4(0,0,0,-1); p.normalID=0; p.baryPrim=0;
}
[shader("closesthit")]
void SurfaceHit(inout PixelResult p, in BuiltInTriangleIntersectionAttributes attr) {
    // PrimitiveIndex是当前geometry中的三角形序号，不是顶点序号或InstanceID。
    // 本例只有一个geometry，三个实例共用同一VB/IB，无额外geometry基址。
    uint primitive=PrimitiveIndex();
    uint3 ids=indices.Load3(primitive*3*4); // Load3地址以字节计；读三个连续uint32。
    float3 a=vertices[ids.x], b=vertices[ids.y], c=vertices[ids.z];
    float3x4 objectToWorld=ObjectToWorld3x4();
    float3 aw=mul(objectToWorld,float4(a,1));
    float3 bw=mul(objectToWorld,float4(b,1));
    float3 cw=mul(objectToWorld,float4(c,1));
    // 在世界空间对两条边叉积，得到几何法线，正确涵盖本例正尺度/旋转实例。
    // 不能把法线简单乘物体矩阵后归一化来应对非均匀缩放。
    // 顶点平滑法线、逆转置、负行列式实例与faceforward是后续材质内容。
    float3 n=normalize(cross(bw-aw,cw-aw));
    float t=RayTCurrent();
    float3 x=WorldRayOrigin()+t*WorldRayDirection();
    // attr=(u,v)，三顶点权重=(1-u-v,u,v)。CPU用它重建世界点，与射线式再对照。
    p.positionT=float4(x,t);
    p.normalID=float4(n,float(InstanceID()));
    p.baryPrim=float4(attr.barycentrics,float(primitive),1);
}
