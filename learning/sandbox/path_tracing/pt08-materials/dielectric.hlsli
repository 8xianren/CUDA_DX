// 平滑、非偏振、无吸收介质的相机Radiance采样。所有方向在世界空间；ng为单位几何外向法线。
// 输入由宿主保证有限、单位方向/法线、正IOR，u位于[0,1)，mode0按F抽样、mode1半半抽样。
struct DielectricSample {
    float3 direction;
    float F,weight,mass,pr,etaScale,q2,etaI,etaT;
    uint event; // 1反射、2透射、0无效。两个成功事件都是delta，连续pdfOmega=0。
};
DielectricSample SampleDielectric(float3 d,float3 ng,float outside,float inside,float u,uint mode){
    DielectricSample s=(DielectricSample)0;
    float side=dot(d,ng);if(side==0)return s;
    bool entering=side<0;float3 n=entering?ng:-ng;
    s.etaI=entering?outside:inside;s.etaT=entering?inside:outside;
    float q=s.etaI/s.etaT;s.q2=q*q;
    float ci=saturate(-dot(d,n)),k=1-s.q2*max(0,1-ci*ci),ct=0;
    if(outside==inside){s.F=0;ct=ci;} // 同IOR无光学界面；透射方向直接保持d。
    else if(k<=0)s.F=1; // 全反射/临界极限先分支，不对负数开根。
    else {
        ct=sqrt(k);
        float rs=(s.etaI*ci-s.etaT*ct)/(s.etaI*ci+s.etaT*ct);
        float rp=(s.etaI*ct-s.etaT*ci)/(s.etaI*ct+s.etaT*ci);
        s.F=saturate(.5*(rs*rs+rp*rp));
    }
    s.pr=s.F<=0?0:(s.F>=1?1:(mode==1?.5:s.F));
    if(u<s.pr){s.event=1;s.direction=d-2*dot(d,n)*n;s.mass=s.pr;s.weight=s.F/s.mass;s.etaScale=1;}
    else {s.event=2;s.direction=outside==inside?d:q*d+(q*ci-ct)*n;
        s.mass=1-s.pr;s.weight=(1-s.F)*s.q2/s.mass;s.etaScale=1/s.q2;}
    // weight已经除过离散mass；积分器只乘一次，不能再乘F/1-F或除mass。
    return s;
}
