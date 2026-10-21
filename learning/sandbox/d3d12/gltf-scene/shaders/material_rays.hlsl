// D.3：共享VB/IB、实例、网格范围、材质、纹理与采样器各有独立寻址职责。
struct ObjectRecord {row_major float4x4 world;uint material,node,mesh,padding;};
struct MeshRecord {uint firstVertex,firstIndex,indexCount,padding;};
struct MaterialRecord {float4 factor;uint textureIndex,samplerIndex,pad0,pad1;};
struct MaterialRay {float3 origin;float tmin;float3 direction;float tmax;};
RaytracingAccelerationStructure scene:register(t0);
StructuredBuffer<ObjectRecord> objects:register(t1);
ByteAddressBuffer vertices:register(t2);
ByteAddressBuffer indices:register(t3);
StructuredBuffer<MeshRecord> meshes:register(t4);
StructuredBuffer<MaterialRecord> materials:register(t5);
StructuredBuffer<MaterialRay> rays:register(t6);
Texture2D<float4> textures[]:register(t0,space1);
SamplerState samplers[]:register(s0);
RWStructuredBuffer<float4> result:register(u0);
struct Payload {float4 color;};
[shader("raygeneration")]
void RayGen(){
    uint i=DispatchRaysIndex().x;MaterialRay r=rays[i];
    RayDesc ray;ray.Origin=r.origin;ray.Direction=r.direction;ray.TMin=r.tmin;ray.TMax=r.tmax;
    Payload p;p.color=-1;
    // 只验证基础色读取，暂不实现MASK/BLEND可见性；alpha仍返回供数值验证。
    TraceRay(scene,RAY_FLAG_FORCE_OPAQUE,255,0,0,0,ray,p);result[i]=p.color;
}
[shader("miss")]
void Miss(inout Payload p){p.color=-1;}
[shader("closesthit")]
void ClosestHit(inout Payload p,in BuiltInTriangleIntersectionAttributes a){
    ObjectRecord object=objects[InstanceID()];MeshRecord mesh=meshes[object.mesh];
    // PrimitiveIndex是BLAS内三角形编号。每个BLAS只有一个geometry，索引仍为mesh局部值。
    uint3 local=indices.Load3(4*(mesh.firstIndex+3*PrimitiveIndex()));
    uint3 address=48*(local+mesh.firstVertex); // C++ Vertex=48B，uv偏移24B，color偏移32B。
    float3 w=float3(1-a.barycentrics.x-a.barycentrics.y,a.barycentrics);
    float2 uv=asfloat(vertices.Load2(address.x+24))*w.x
             +asfloat(vertices.Load2(address.y+24))*w.y+asfloat(vertices.Load2(address.z+24))*w.z;
    float4 color=asfloat(vertices.Load4(address.x+32))*w.x
                +asfloat(vertices.Load4(address.y+32))*w.y+asfloat(vertices.Load4(address.z+32))*w.z;
    // 固定Assimp版本把glTF v翻转过一次；WIC没有倒排图像行，在采样边界恢复glTF方向。
    uv.y=1-uv.y;
    MaterialRecord material=materials[object.material];
    // 同wave的命中可能对应不同材质，descriptor索引必须标明可能不一致。
    // 只有mip0，明确SampleLevel(...,0)；没有凭空生成屏幕导数或ray footprint。
    float4 texel=textures[NonUniformResourceIndex(material.textureIndex)].SampleLevel(
        samplers[NonUniformResourceIndex(material.samplerIndex)],uv,0);
    p.color=texel*material.factor*color; // RGB已经由SRGB SRV解码；alpha、factor、顶点色保持线性。
}
