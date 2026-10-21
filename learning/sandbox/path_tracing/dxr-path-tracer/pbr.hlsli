// PT.8共享局部坐标材质：wo/wi均离开表面，n=+Z。roughness²<=1e-4是明确delta近似阈值。
static const float PbrPi=3.14159265358979323846;
#ifdef PBR_ENERGY_BALANCED
#include "energy_lut.hlsli"
#endif
struct PbrMaterial {float3 base;float metallic,roughness;};
float3 PbrFresnel(float3 f0,float c){float x=1-saturate(c);return f0+(1-f0)*x*x*x*x*x;}
float3 PbrF0(PbrMaterial m){return lerp(.04.xxx,m.base,m.metallic);}
bool PbrDelta(PbrMaterial m){return m.roughness*m.roughness<=1e-4;}
float PbrSpecProbability(PbrMaterial m,uint mode){return m.metallic==1||dot(m.base,1.xxx)==0?1:(mode==0?.5:.8);}
float PbrD(float3 h,float alpha){float a2=alpha*alpha;float d=dot(h.xy,h.xy)+a2*h.z*h.z;return a2/(PbrPi*d*d);}
float PbrLambda(float3 w,float alpha){float s=alpha*alpha*dot(w.xy,w.xy)/(w.z*w.z);return s/(2*(sqrt(1+s)+1));}
struct PbrEvaluation {float3 f,diffuse,specular;float pdf,specPdf,diffPdf;};
PbrEvaluation PbrEvalHalf(PbrMaterial m,float3 wo,float3 wi,float3 h,uint mode){
    PbrEvaluation e=(PbrEvaluation)0;if(wo.z<=0||wi.z<=0)return e;
    float cosine=dot(wo,h);
    float dielectricF=PbrFresnel(.04.xxx,cosine).x;
#ifdef PBR_ENERGY_BALANCED
    // 模型与采样策略分开：只换f，不改变NDF/余弦混合PDF，也不截断路径权重。
    e.diffuse=(1-m.metallic)*m.base*(1-EnergyAt(m.roughness,wo.z))*(1-EnergyAt(m.roughness,wi.z))/(PbrPi*(1-EnergyMean(m.roughness)));
#else
    // 保留原基线作为可重跑的能量失败负对照；完整主线使用PBR_ENERGY_BALANCED构建。
    e.diffuse=(1-m.metallic)*(1-dielectricF)*m.base/PbrPi;
#endif
    if(!PbrDelta(m)){
        float alpha=m.roughness*m.roughness,ndf=PbrD(h,alpha);
        float geometry=1/(1+PbrLambda(wo,alpha)+PbrLambda(wi,alpha));
        e.specular=PbrFresnel(PbrF0(m),cosine)*ndf*geometry/(4*wo.z*wi.z);
        e.specPdf=ndf*h.z/(4*cosine);
    }
    e.f=e.diffuse+e.specular;e.diffPdf=wi.z/PbrPi;
    float ps=PbrSpecProbability(m,mode);e.pdf=ps*e.specPdf+(1-ps)*e.diffPdf;return e;
}
PbrEvaluation PbrEval(PbrMaterial m,float3 wo,float3 wi,uint mode){return PbrEvalHalf(m,wo,wi,normalize(wo+wi),mode);}
struct PbrSample {float3 wi,weight,halfVector;float pdf,mass,selectedPdf;uint event,branch;};
PbrSample PbrDraw(PbrMaterial m,float3 wo,float3 random,uint mode){
    PbrSample s=(PbrSample)0;float ps=PbrSpecProbability(m,mode);bool spec=random.x<ps;s.branch=spec?1:2;
    if(spec&&PbrDelta(m)){
        s.wi=float3(-wo.xy,wo.z);s.mass=ps;s.weight=PbrFresnel(PbrF0(m),wo.z)/ps;s.event=3;return s;
    }
    if(spec){
        float alpha=m.roughness*m.roughness,r=alpha*sqrt(random.y/(1-random.y)),phi=2*PbrPi*random.z;
        float3 h=normalize(float3(r*cos(phi),r*sin(phi),1));s.halfVector=h;float oh=dot(wo,h);s.event=1;
        if(oh<=0)return s;s.wi=2*oh*h-wo;if(s.wi.z<=0)return s;
    }else{
        float r=sqrt(random.y),phi=2*PbrPi*random.z;s.wi=float3(r*cos(phi),r*sin(phi),sqrt(1-r*r));s.halfVector=normalize(wo+s.wi);
    }
    // 对NDF分支保留原微面法线；掠射窄高光的wo+wi会相消，重新归一化会严重扰动PDF。
    PbrEvaluation e=PbrEvalHalf(m,wo,s.wi,s.halfVector,mode);s.pdf=e.pdf;s.selectedPdf=spec?ps*e.specPdf:(1-ps)*e.diffPdf;
    s.weight=e.f*s.wi.z/e.pdf;s.event=2;return s;
}
