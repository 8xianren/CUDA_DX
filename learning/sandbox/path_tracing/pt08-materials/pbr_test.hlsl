#include "../dxr-path-tracer/pbr.hlsli"
#include "../dxr-path-tracer/surface.hlsli"
struct Config {uint width,height,seed,mode;float slope;uint tiles,pad0,pad1;};
StructuredBuffer<Config> configs:register(t6);
struct Record {float4 baseMetal,pointRough,normalPs,outgoingPdf,weightMass,emissionU0,random12Uv;uint4 tags;};
RWStructuredBuffer<Record> output:register(u0);
float Random(uint index,uint seed,uint dim){uint x=(index+1)*747796405u+seed*2891336453u+dim*277803737u+0x9e3779b9u;
    x=(x^(x>>16))*0x21f0aaadu;x=(x^(x>>15))*0x735a2d97u;x^=x>>15;return ((x>>9)+.5)/8388608.;}
[shader("raygeneration")]
void RayGen(){
    Config c=configs[0];uint2 ij=DispatchRaysIndex().xy;uint index=ij.y*c.width+ij.x;Record r=(Record)0;
#ifdef PBR_ENERGY_BALANCED
    if(c.pad0==1){
        // 同一材质shader的全参数域探针：只查表/Eval，不伪称这里执行了TraceRay。
        // 含delta、阈值右侧、完整log(alpha)区间、co=0/1端点以及独立随机wi。
        float rough=ij.x==0?0:(ij.x==1?.01:(ij.x==2?.0100001:sqrt(1e-4*exp2(log2(1e4)*float(ij.x-3)/(c.width-4)))));
        float u=float(ij.y)/(c.height-1),co=u*u*u*u,ci=Random(index,17,1),phi=2*PbrPi*Random(index,17,2);
        float3 wo=float3(sqrt(max(0,1-co*co)),0,co),wi=float3(sqrt(1-ci*ci)*cos(phi),sqrt(1-ci*ci)*sin(phi),ci);
        PbrMaterial m;m.base=float3(.2,.6,.9);m.metallic=.3;m.roughness=rough;
        PbrEvaluation e=PbrEval(m,wo,wi,0),reverse=PbrEval(m,wi,wo,0);
        r.baseMetal=float4(EnergyAt(rough,co),EnergyAt(rough,ci),EnergyMean(rough),max(max(abs(e.f.x-reverse.f.x),abs(e.f.y-reverse.f.y)),abs(e.f.z-reverse.f.z))/(1+max(max(e.f.x,e.f.y),e.f.z)));
        r.pointRough=float4(co,ci,phi,rough);r.normalPs=float4(wo,0);r.outgoingPdf=float4(wi,e.pdf);r.weightMass=float4(e.f,0);
        if(co>0){PbrSample s=PbrDraw(m,wo,float3(Random(index,93,0),Random(index,93,1),Random(index,93,2)),0);
            r.emissionU0=float4(s.wi,s.mass);r.random12Uv=float4(s.weight,s.pdf);r.tags=uint4(s.event+4*s.branch,asuint(s.halfVector));}
        if(r.tags.x%4==2)r.weightMass.w=PbrEval(m,wo,r.emissionU0.xyz,0).pdf; // 重构半角PDF负对照。
        output[index]=r;return;
    }
#endif
    // 相机平移补偿slope，让不同角度仍然命中同一网格中心，便于隔离材质和采样变化。
    float3 origin=float3((ij.x+.5)*2/64-c.tiles-c.slope,(ij.y+.5)*2/c.height-1,1);
    float3 d=normalize(float3(c.slope,0,-1));Payload hit=Shoot(origin,d);r.tags.w=1;
    if(hit.instancePlus==0){output[index]=r;return;}
    Surface surface=LoadSurface(hit);float3 t,b;LocalFrame(surface.normal,t,b);
    float3 wo=float3(dot(-d,t),dot(-d,b),dot(-d,surface.normal));if(wo.z<=0){output[index]=r;return;}
    float3 u=float3(Random(index,c.seed,0),Random(index,c.seed,1),Random(index,c.seed,2));
    PbrSample sample=PbrDraw(surface.material,wo,u,c.mode);
    r.baseMetal=float4(surface.material.base,surface.material.metallic);r.pointRough=float4(surface.position,surface.material.roughness);
    r.normalPs=float4(surface.normal,PbrSpecProbability(surface.material,c.mode));r.outgoingPdf=float4(sample.wi,sample.pdf);
    r.weightMass=float4(sample.weight,sample.mass);r.emissionU0=float4(surface.emission,u.x);r.random12Uv=float4(u.yz,surface.uv);
    r.tags.xyz=uint3(sample.event,sample.branch,surface.materialID);
    if(sample.event==2||sample.event==3){
        float3 direction=sample.wi.x*t+sample.wi.y*b+sample.wi.z*surface.normal;
        // 本fixture尺度下的法线偏移；白炉环境在Miss处Li=1，真实第二次TraceRay验证无遮挡。
        Payload second=Shoot(surface.position+surface.normal*(1.0/1024.0),direction);r.tags.w++;
        if(second.instancePlus!=0)r.tags.x=0; // 不把意外几何命中当作白环境，否则会掩盖求交错误。
    }
    output[index]=r;
}
