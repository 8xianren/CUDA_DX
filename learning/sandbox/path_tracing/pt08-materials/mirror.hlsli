// PT.8 的最小材质采样契约；这是教学接口，不是HLSL内建API。
// weight已包含散射项/抽样概率/几何余弦的最终比值，积分器不能再次乘cos或除PDF。
// pdfOmega是连续部分相对立体角的密度；eventMass是离散事件的概率，两者不可直接相加或做MIS。
struct MirrorSample {float3 wi;float3 weight;float pdfOmega,eventMass;uint isDelta;};
MirrorSample SampleMirror(float3 wo,float3 n,float3 R){
    // wo和wi都离开表面。调用者保证单位向量、dot(wo,n)>0、线性RGB的R位于[0,1]。
    // 把wo的切向分量反号、法向分量保留；纯镜面只有这一种离散事件，选择概率为1。
    MirrorSample s;s.wi=2*dot(wo,n)*n-wo;s.weight=R;
    s.pdfOmega=0;s.eventMass=1;s.isDelta=1;return s;
}
