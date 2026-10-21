// H6独立中心主射线：不把抖动beauty的首个样本直接当作稳定运动矢量。
#include "../../../path_tracing/dxr-path-tracer/pbr.hlsli"
#include "../../../path_tracing/dxr-path-tracer/surface.hlsli"
ByteAddressBuffer config:register(t6);
ByteAddressBuffer previousVertices:register(t7);
struct Guide {float4 position,normal,previousPixel,previousNormal;};
RWStructuredBuffer<Guide> guides:register(u0);
[shader("raygeneration")]
void RayGen(){
    uint2 pixel=DispatchRaysIndex().xy;uint2 size=config.Load2(0);uint index=pixel.y*size.x+pixel.x;
    float4 eye=asfloat(config.Load4(32));float3 forward=asfloat(config.Load3(48)),right=asfloat(config.Load3(64)),up=asfloat(config.Load3(80));
    float sx=((pixel.x+.5)/size.x*2-1)*(float(size.x)/size.y)*eye.w,sy=(1-(pixel.y+.5)/size.y*2)*eye.w;
    Payload hit=Shoot(eye.xyz,normalize(forward+sx*right+sy*up));Guide output=(Guide)0;
    if(hit.instancePlus!=0){
        Surface surface=LoadSurface(hit);ObjectRecord object=objects[hit.instancePlus-1];MeshRecord mesh=meshes[object.mesh];
        uint3 local=indices.Load3(4*(mesh.firstIndex+3*hit.primitive));uint3 address=48*(local+mesh.firstVertex);
        float3 a=asfloat(previousVertices.Load3(address.x)),b=asfloat(previousVertices.Load3(address.y)),c=asfloat(previousVertices.Load3(address.z));
        uint base=208+64*(hit.instancePlus-1);float4 r0=asfloat(config.Load4(base)),r1=asfloat(config.Load4(base+16)),r2=asfloat(config.Load4(base+32));
        a=float3(dot(r0,float4(a,1)),dot(r1,float4(a,1)),dot(r2,float4(a,1)));
        b=float3(dot(r0,float4(b,1)),dot(r1,float4(b,1)),dot(r2,float4(b,1)));
        c=float3(dot(r0,float4(c,1)),dot(r1,float4(c,1)),dot(r2,float4(c,1)));
        float3 weights=float3(1-hit.bary.x-hit.bary.y,hit.bary);float3 oldPosition=a*weights.x+b*weights.y+c*weights.z;
        float3 oldEye=asfloat(config.Load3(128));float4 oldForward=asfloat(config.Load4(144));float3 oldRight=asfloat(config.Load3(160)),oldUp=asfloat(config.Load3(176));
        float3 delta=oldPosition-oldEye;float depth=dot(delta,oldForward.xyz);
        float2 ndc=float2(dot(delta,oldRight)/(depth*oldForward.w*(float(size.x)/size.y)),dot(delta,oldUp)/(depth*oldForward.w));
        float2 uv=float2(ndc.x*.5+.5,.5-ndc.y*.5);
        output.position=float4(surface.position,hit.instancePlus);output.normal=float4(surface.normal,hit.primitive+1);
        output.previousPixel=float4(uv*size,depth,depth>1e-4&&all(uv>=0)&&all(uv<1));
        // 镜面/高金属区域的一阶表面运动不能解释反射运动，首版明确禁止复用这些区域。
        output.previousNormal=float4(normalize(cross(b-a,c-a)),surface.material.metallic<.5&&surface.material.roughness>=.25);
    }
    guides[index]=output;
}
