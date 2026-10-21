// PT.6限定Lambert receiver与平行方形灯；实际遮挡由导入glTF的DXR三角形求交。
// 泛化法线/纹理/PBR交给PT.8；本节关注相机→采样→PDF→MIS完整GPU执行。
struct ObjectRecord { row_major float4x4 world; uint material,node,mesh,padding; };
struct Config {
    uint width,height,rounds,seed;
    uint receiver,emitter,pad0,pad1;
    float halfLight,rho,le,halfView;
    float panX,panY,cameraZ,pad2;
};
struct Pixel { float4 estimates; uint4 diagnostics; };
struct Payload { uint material; float t; uint2 padding; }; // 16B，0表示miss，其他为material+1。
RaytracingAccelerationStructure scene : register(t0);
StructuredBuffer<ObjectRecord> objects : register(t1);
StructuredBuffer<Config> configs : register(t2);
RWStructuredBuffer<Pixel> output : register(u0);
static const float PI=3.14159265358979323846;
// 32bit确定性混合；每像素/seed独立状态。用于教学可复现，不声称优于生产采样器。
uint Next(inout uint state){state+=0x9e3779b9u;uint x=state;x=(x^(x>>16))*0x21f0aaadu;x=(x^(x>>15))*0x735a2d97u;return x^(x>>15);}
float Uniform(inout uint state){return ((Next(state)>>9)+0.5)/8388608.0;} // 开区间(0,1)，避免半球地平线。
Payload Shoot(float3 origin,float3 direction){
    RayDesc ray;ray.Origin=origin;ray.Direction=direction;ray.TMin=1e-5;ray.TMax=1e6;
    Payload hit=(Payload)0;
    // force opaque禁用alpha路径；mask255看全部实例；单hit group和单miss记录均索引0。
    TraceRay(scene,RAY_FLAG_FORCE_OPAQUE,255,0,0,0,ray,hit);return hit;
}
float Weight(float own,float other,uint exponent){
    if(own<=0)return 0;float scale=max(own,other);float a=own/scale,b=other/scale;
    if(exponent==2){a*=a;b*=b;}return a/(a+b);
}
[shader("raygeneration")]
void RayGen(){
    Config c=configs[0];uint2 pixel=DispatchRaysIndex().xy;uint index=pixel.y*c.width+pixel.x;
    // 正交相机：像素中心均匀分布在观察矩形，所有方向为-Z。图像向下对应世界-Y。
    float2 uv=(float2(pixel)+0.5)/float2(c.width,c.height);
    float3 origin=float3(c.panX+(2*uv.x-1)*c.halfView,c.panY+(1-2*uv.y)*c.halfView,c.cameraZ);
    Payload primary=Shoot(origin,float3(0,0,-1));Pixel outValue=(Pixel)0;
    outValue.diagnostics.x=primary.material;
    if(primary.material!=c.receiver+1){output[index]=outValue;return;}
    float3 position=origin+primary.t*float3(0,0,-1);
    uint rng=(index+1)*747796405u+c.seed*2891336453u;
    for(uint s=0;s<c.rounds;++s){
        // 2个灯样本+2个BSDF样本供四种估计器对照；MIS各只用第一个，共2方向。
        // 所以每种估计器的预算都是2*rounds，不是把四种结果合成一个输出颜色。
        for(uint sampleKind=0;sampleKind<4;++sampleKind){
            float u=Uniform(rng),v=Uniform(rng);float3 direction;
            if(sampleKind<2){float3 q=float3((2*u-1)*c.halfLight,(2*v-1)*c.halfLight,2);direction=normalize(q-position);}
            else {float r=sqrt(u),phi=2*PI*v;direction=float3(r*cos(phi),r*sin(phi),sqrt(1-u));}
            float cosine=direction.z;float pB=cosine/PI;
            float t=(2-position.z)/direction.z;float2 q=position.xy+t*direction.xy;
            // 共同立体角测度：距离²/(灯面积*cosLight)。可见性不进入PDF，遮挡进入F。
            float pL=(sampleKind<2||all(abs(q)<=c.halfLight))?t*t/(4*c.halfLight*c.halfLight*cosine):0;
            Payload secondary=Shoot(position,direction);bool visible=secondary.material==c.emitter+1;
            if(sampleKind<2)outValue.diagnostics.y+=visible?1:0;else outValue.diagnostics.z+=visible?1:0;
            float F=visible?c.rho/PI*c.le*cosine:0;
            float own=sampleKind<2?pL:pB,other=sampleKind<2?pB:pL;
            float contribution=own>0?F/own:0;
            if(sampleKind<2)outValue.estimates.y+=contribution;else outValue.estimates.x+=contribution;
            if(sampleKind==0||sampleKind==2){outValue.estimates.z+=Weight(own,other,1)*contribution;outValue.estimates.w+=Weight(own,other,2)*contribution;}
        }
    }
    outValue.estimates.xy/=2*c.rounds;
    outValue.estimates.zw/=c.rounds; // 两个已加权积分估计器相加，不能额外除以2。
    output[index]=outValue; // 每个RayGen只写自己的像素，无原子操作/跨像素同步。
}
[shader("miss")] void Miss(inout Payload hit){hit=(Payload)0;}
[shader("closesthit")] void ClosestHit(inout Payload hit,BuiltInTriangleIntersectionAttributes attributes){
    hit.material=objects[InstanceID()].material+1;hit.t=RayTCurrent();
    // 只报告命中，不在此TraceRay。RayGen中的下一条射线在当前TraceRay返回后发出。
}
