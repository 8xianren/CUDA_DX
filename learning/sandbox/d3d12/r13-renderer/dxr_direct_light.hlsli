// R.13.5：单矩形灯、固定像素中心、多灯面样本；无跨帧历史、无间接反弹。
// 本文件在View/scene声明之后包含。mode由targetInfo.w传入：
// 0正常64样本，1忽略遮挡，2翻转发光面，3孤立白炉，4黑材质，5两倍Le，6正常1样本。
static const float LightPi=3.14159265358979323846;
struct ShadowPayload { uint visible; }; // 仅Miss改为1，命中opaque几何时保持0。
[shader("miss")]
void ShadowMiss(inout ShadowPayload p) { p.visible=1; }
uint light_hash(uint x){x^=x>>16;x*=0x7feb352d;x^=x>>15;x*=0x846ca68b;x^=x>>16;return x;}
float light_uniform(uint pixel,uint sample,uint dimension){
#if ENABLE_PROGRESSIVE
    // 每相机样本只选一个灯面点；维度0/1已给像素位置，灯面使用2/3。
    return progressive_uniform(pixel,2u+dimension);
#else
    // 相同像素/样本/维度跨模式保持一致，以便做可重复的物理参数对照。
    uint bits=light_hash((pixel*0x9e3779b9u)^(2*sample+dimension)^0x51ed270bu);
    return (float(bits>>16)+0.5)/65536.0; // (0,1)内有限离散伪随机数，不宣称严格独立。
#endif
}
float3 diffuse_albedo(uint id){
    return id==1?float3(.7,.18,.08):(id==2?float3(.08,.28,.7):float3(.65,.65,.65));
}
float3 lambert_brdf(float3 rho){return rho/LightPi;}
void estimate_direct(float3 x,float3 n,float3 wo,uint id,uint pixel,uint mode,
                     out float4 direct,out float4 unoccluded){
    direct=0;unoccluded=0;float3 rho=mode==4?float3(0,0,0):diffuse_albedo(id);
#if ENABLE_HISTORY
    if(targetInfo.w&(1u<<17))rho=0; // 材质变化独立于灯强度变化。
#endif
    // 白炉是隔离材质测试：人为规定整个入射半球Li=1且无任何遮挡；不是本场景环境GI。
    if(mode==3){
        float3 sum=0;
        for(uint s=0;s<64;++s){
            float cosine=sqrt(light_uniform(pixel,s,0));float pdf=cosine/LightPi;
            sum+=lambert_brdf(rho)*cosine/pdf; // 余弦采样估计常量环境，预期严格为rho（浮点误差内）。
        }
        direct=float4(sum/64,1);unoccluded=direct;return;
    }
    // 单面Lambert约定：相机在几何背面时不输出反射，不把法线随意翻向相机。
    if(dot(n,wo)<=0)return;
    uint count=mode==6?1:64;
#if ENABLE_PROGRESSIVE
    count=1;
#endif
    float3 Le=float3(12,11,9)*(mode==5?2:1);
#if ENABLE_HISTORY
    if(targetInfo.w&(1u<<16))Le*=2;
#endif
    float3 nl=mode==2?float3(0,0,1):float3(0,0,-1);
    // 中心(2,-.5,3.5)，U=+X、V=-Y，半边长均1，面积A=4，pA=1/4。
    // 灯目前仅为积分参数，不在TLAS中；主射线看不到发光几何。
    for(uint s=0;s<count;++s){
        float2 xi=float2(light_uniform(pixel,s,0),light_uniform(pixel,s,1));
        float3 q=float3(2+(2*xi.x-1),-.5-(2*xi.y-1),3.5);
        float3 delta=q-x;float r2=dot(delta,delta);float3 wi=delta*rsqrt(r2);
        float cs=max(dot(n,wi),0),cl=max(dot(nl,-wi),0);
        if(cs<=0||cl<=0)continue; // 零样本仍占分母，不重抽。
        // 统一用立体角pdf：pOmega=pA*r²/cosLight。此处不要再额外乘cosLight/r²。
        float pdfOmega=.25*r2/cl;
        float3 sampleValue=Le*lambert_brdf(rho)*cs/pdfOmega;
        uint visible=1;
        if(mode!=1){
            float3 origin=x+.0001*n;float3 shadowDelta=q-origin;
            float distance=length(shadowDelta);
            RayDesc shadow;shadow.Origin=origin;shadow.Direction=shadowDelta/distance;
            shadow.TMin=.001;shadow.TMax=distance-.001;
            ShadowPayload p;p.visible=0;
            // 主Miss=0，阴影Miss=1；跳过ClosestHit以免用4B阴影payload进入主命中shader。
            TraceRay(scene,RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH|RAY_FLAG_SKIP_CLOSEST_HIT_SHADER,
                     scene_inclusion_mask(),0,0,1,shadow,p);
            visible=p.visible;
        }
        direct.xyz+=visible*sampleValue;direct.w+=visible;
        unoccluded.xyz+=sampleValue;unoccluded.w+=1;
    }
    direct/=float(count);unoccluded/=float(count);
    // w只是通过余弦筛选并可见的样本比例，不是按贡献加权的光照透过率。
}
