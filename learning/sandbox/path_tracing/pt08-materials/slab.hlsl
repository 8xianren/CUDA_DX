#include "dielectric.hlsli"
// 固定布局与slab_reference.h逐项对应，StructuredBuffer没有cbuffer的16B数组补齐规则。
// 一个RayGen线程负责一条完整路径，拥有独立Record；不跨线程共享状态，无需原子操作。
struct ObjectRecord {row_major float4x4 world;uint material,node,mesh,pad;};
struct Config {
    uint width,height,topID,bottomID;
    uint upperID,lowerID,seed,mode;
    uint maxScatter,startInside,disableOffset,pad1;
    float4 parameters,upperLe,lowerLe; // 斜率、起点z、外IOR、内IOR；两灯线性辐亮度
};
struct Step {
    float4 position; // xyz命中点，w本段射线t
    float4 direction; // xyz出射方向，w入射介质IOR
    float4 state; // 更新后的beta、etaScale，本次weight、q²
    float4 probability; // u、反射概率pr、F、实际事件概率mass
    uint4 ids; // 命中材质、事件1反射/2透射、更新前inside、更新后inside
};
struct Record {
    float4 radiance; // RGB最终贡献，w最终beta；截断/错误时RGB保持零
    uint4 status; // 1上灯/2下灯/3截断/4无效采样/400+介质错/500+几何错/600+灯错，后三项为散射数/射线数/inside
    Step steps[16];
};
struct Payload {uint material;float t;uint2 pad;};
RaytracingAccelerationStructure scene:register(t0);
StructuredBuffer<ObjectRecord> objects:register(t1);
StructuredBuffer<Config> configs:register(t2);
RWStructuredBuffer<Record> output:register(u0);

float Random(uint index,uint seed,uint depth) {
    // 深度参与hash，避免每次反弹复用同一个u产生错误的路径相关性。
    uint x=(index+1)*747796405u+seed*2891336453u+depth*277803737u+0x9e3779b9u;
    x=(x^(x>>16))*0x21f0aaadu;x=(x^(x>>15))*0x735a2d97u;x^=x>>15;
    return ((x>>9)+.5)/8388608.;
}
Payload Shoot(float3 o,float3 d) {
    RayDesc ray;ray.Origin=o;ray.Direction=d;ray.TMin=1e-5;ray.TMax=1000;
    Payload p=(Payload)0;
    TraceRay(scene,RAY_FLAG_FORCE_OPAQUE,255,0,0,0,ray,p);
    return p;
}
[shader("raygeneration")]
void RayGen() {
    Config c=configs[0];uint2 ij=DispatchRaysIndex().xy;uint index=ij.y*c.width+ij.x;
    Record r=(Record)0;
    float3 o=float3((float2(ij)+.5)/float2(c.width,c.height)-.5,c.parameters.y);
    float3 d=normalize(float3(c.parameters.x,0,-1));
    float beta=1,etaScale=1;uint inside=c.startInside;
    // depth是已经完成的散射数。即便达到上限，仍发一次射线接收灯光；若又撞到界面才截断。
    // 所有TraceRay从RayGen顺序调用，ClosestHit不递归，因此流水线递归深度仍为1。
    for(uint depth=0;depth<=c.maxScatter;++depth) {
        Payload hit=Shoot(o,d);r.status.z++;
        if(hit.material==c.upperID||hit.material==c.lowerID) {
            bool upper=hit.material==c.upperID;
            if(inside!=0||(upper?d.z<=0:d.z>=0)){r.status.x=600+hit.material;break;}
            r.radiance.rgb=beta*(upper?c.upperLe.rgb:c.lowerLe.rgb);
            r.status.x=upper?1:2;break;
        }
        if(hit.material!=c.topID&&hit.material!=c.bottomID){r.status.x=500+hit.material;break;}
        if(depth==c.maxScatter){r.status.x=3;break;}
        bool top=hit.material==c.topID;
        float3 ng=top?float3(0,0,1):float3(0,0,-1);
        // ng始终朝玻璃外部；dot(d,ng)<0是准备入内，>0是准备出外。
        // 当前只支持一块玻璃和外部空气。显式状态检查能发现法线/介质/起点不一致。
        bool entering=dot(d,ng)<0;
        if(entering==(inside!=0)){r.status.x=400+hit.material;break;}
        float3 p=o+hit.t*d;p.z=top?0:-1; // 固定平面投影；不是任意三角网格的稳健起点算法
        float u=Random(index,c.seed,depth);
        DielectricSample s=SampleDielectric(d,ng,c.parameters.z,c.parameters.w,u,c.mode);
        if(s.event==0){r.status.x=4;break;}
        Step step=(Step)0;step.position=float4(p,hit.t);step.ids=uint4(hit.material,s.event,inside,inside);
        // 透射才跨过边界。反射（含全反射）保留原介质，不能每遇到一个面就翻转inside。
        if(s.event==2)inside=1-inside;
        beta*=s.weight;etaScale*=s.etaScale;
        step.direction=float4(s.direction,s.etaI);step.state=float4(beta,etaScale,s.weight,s.q2);
        step.probability=float4(u,s.pr,s.F,s.mass);step.ids.w=inside;
        r.steps[depth]=step;r.status.y++;
        o=p;d=s.direction;
        // 半宽256、厚度1、世界变换恒等的受限fixture：2^-10大于本实验求交误差，远小于厚度。
        // 沿出射侧的几何法线偏移；反射偏向原介质，透射偏向新介质。并非通用网格误差界。
        // disableOffset只用于复现自相交负对照，正确路径均启用偏移；CPU参考同步应用相同起点。
        if(c.disableOffset==0)o.z+=(d.z>0?1:-1)*(1.0/1024.0);
    }
    r.radiance.w=beta;r.status.w=inside;output[index]=r;
}
[shader("miss")]
void Miss(inout Payload p){p.material=0;p.t=0;}
[shader("closesthit")]
void ClosestHit(inout Payload p,in BuiltInTriangleIntersectionAttributes attributes){
    p.material=objects[InstanceID()].material+1;p.t=RayTCurrent();
}
