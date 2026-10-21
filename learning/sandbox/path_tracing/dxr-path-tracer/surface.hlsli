// 场景资源绑定沿用D.3根参数：t0 TLAS,t1对象,t2 VB,t3 IB,t4网格,t5材质，纹理space1/sampler space0。
struct ObjectRecord {row_major float4x4 world;uint material,node,mesh,padding;};
struct MeshRecord {uint firstVertex,firstIndex,indexCount,padding;};
struct MaterialRecord {float4 base,emission;float metallic,roughness;uint baseTexture,mrTexture;uint emissionTexture,baseSampler,mrSampler,emissionSampler;};
RaytracingAccelerationStructure scene:register(t0);
StructuredBuffer<ObjectRecord> objects:register(t1);
ByteAddressBuffer vertices:register(t2);
ByteAddressBuffer indices:register(t3);
StructuredBuffer<MeshRecord> meshes:register(t4);
StructuredBuffer<MaterialRecord> materials:register(t5);
Texture2D<float4> textures[]:register(t0,space1);
SamplerState samplers[]:register(s0);
// 16B payload只返回身份和重心坐标。RayGen读取几何/材质，保留顺序TraceRay、递归深度1。
struct Payload {uint instancePlus,primitive;float2 bary;};
struct Surface {float3 position,normal,geometryNormal,emission;float2 uv;PbrMaterial material;uint materialID;float dielectricIOR;};
float4 SampleSlot(uint textureID,uint samplerID,float2 uv){
    if(textureID==0xffffffff)return 1;
    return textures[NonUniformResourceIndex(textureID)].SampleLevel(samplers[NonUniformResourceIndex(samplerID)],uv,0);
}
Surface LoadSurface(Payload p,bool smooth=false){
    ObjectRecord object=objects[p.instancePlus-1];MeshRecord mesh=meshes[object.mesh];MaterialRecord mat=materials[object.material];
    uint3 local=indices.Load3(4*(mesh.firstIndex+3*p.primitive));uint3 address=48*(local+mesh.firstVertex);
    float3 a=asfloat(vertices.Load3(address.x)),b=asfloat(vertices.Load3(address.y)),c=asfloat(vertices.Load3(address.z));
    // 几何法线由实际变换后的三角形边推导；默认以此着色，smooth显式选择顶点插值法线。
    a=mul(object.world,float4(a,1)).xyz;b=mul(object.world,float4(b,1)).xyz;c=mul(object.world,float4(c,1)).xyz;
    float3 w=float3(1-p.bary.x-p.bary.y,p.bary);Surface s;
    s.position=a*w.x+b*w.y+c*w.z;s.geometryNormal=normalize(cross(b-a,c-a));s.normal=s.geometryNormal;
    if(smooth&&mat.emission.w<=0){
        // 蒙皮缓存中的顶点法线按重心插值，再乘实例的逆转置。列的叉积构成余子式，
        // 除以行列式后即逆转置；支持非均匀缩放。几何法线仍独立用于单面性与射线偏移。
        float3 n=asfloat(vertices.Load3(address.x+12))*w.x+asfloat(vertices.Load3(address.y+12))*w.y+asfloat(vertices.Load3(address.z+12))*w.z;
        float3 x=float3(object.world[0][0],object.world[1][0],object.world[2][0]);
        float3 y=float3(object.world[0][1],object.world[1][1],object.world[2][1]);
        float3 z=float3(object.world[0][2],object.world[1][2],object.world[2][2]);
        float determinant=dot(x,cross(y,z));float3 transformed=n.x*cross(y,z)+n.y*cross(z,x)+n.z*cross(x,y);
        if(abs(determinant)>1e-12&&dot(transformed,transformed)>1e-16){
            s.normal=normalize(transformed/determinant);
            if(dot(s.normal,s.geometryNormal)<0)s.normal=-s.normal;
        }
    }
    s.uv=asfloat(vertices.Load2(address.x+24))*w.x+asfloat(vertices.Load2(address.y+24))*w.y+asfloat(vertices.Load2(address.z+24))*w.z;
    s.uv.y=1-s.uv.y; // 固定Assimp版本翻过v；在采样边界恢复glTF约定。
    float4 color=asfloat(vertices.Load4(address.x+32))*w.x+asfloat(vertices.Load4(address.y+32))*w.y+asfloat(vertices.Load4(address.z+32))*w.z;
    s.material.base=mat.base.rgb*color.rgb*SampleSlot(mat.baseTexture,mat.baseSampler,s.uv).rgb;
    float4 mr=SampleSlot(mat.mrTexture,mat.mrSampler,s.uv);s.material.metallic=mat.metallic*mr.b;s.material.roughness=mat.roughness*mr.g;
    s.emission=mat.emission.rgb*SampleSlot(mat.emissionTexture,mat.emissionSampler,s.uv).rgb;s.materialID=object.material;s.dielectricIOR=mat.emission.w;
    return s;
}
void LocalFrame(float3 n,out float3 t,out float3 b){t=normalize(cross(abs(n.z)<.999?float3(0,0,1):float3(0,1,0),n));b=cross(n,t);}
Payload Shoot(float3 origin,float3 direction){
    RayDesc ray;ray.Origin=origin;ray.Direction=direction;ray.TMin=1e-5;ray.TMax=1000;
    Payload p=(Payload)0;TraceRay(scene,RAY_FLAG_FORCE_OPAQUE,255,0,0,0,ray,p);return p;
}
[shader("miss")]
void Miss(inout Payload p){p.instancePlus=0;}
[shader("closesthit")]
void ClosestHit(inout Payload p,in BuiltInTriangleIntersectionAttributes a){p.instancePlus=InstanceID()+1;p.primitive=PrimitiveIndex();p.bary=a.barycentrics;}
