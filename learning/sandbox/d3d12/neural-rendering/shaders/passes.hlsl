// G.10：所有离屏颜色是线性RGB。只有最终写UNORM交换链时执行sRGB编码。
// 相机固定eye=(0,0,-3)，+Z前/+Y上；像素中心与CUDA均为(x+.5,y+.5)。
cbuffer Parameters:register(b0){float aspect;float tanHalfFov;uint foreground;uint encode;};
Texture2D<float4> radiance:register(t0);
Texture2D<float4> meshColor:register(t1);
struct V{float4 p:SV_Position;float3 color:COLOR;float z:TEXCOORD;};
V MeshVS(uint id:SV_VertexID){
    // 两个真实三角形组成每个网格矩形。背景覆盖视锥，前景窄板用于验证遮挡。
    uint tri[6]={0,1,2,2,1,3};uint index=tri[id%6];bool front=id>=6;
    float z=front?2.35:4.5;
    float2 extent=front?float2(.18,.8):float2(z*tanHalfFov*aspect,z*tanHalfFov);
    float2 xy=float2(index&1?1:-1,index&2?1:-1)*extent;
    V o;float nearZ=.1,farZ=10;
    o.p=float4(xy.x/(tanHalfFov*aspect),xy.y/tanHalfFov,
               farZ/(farZ-nearZ)*z-farZ*nearZ/(farZ-nearZ),z);
    o.color=front?float3(.68,.22,.08):float3(.055,.085,.14);o.z=z;return o;
}
struct MeshOut{float4 color:SV_Target0;float linearZ:SV_Target1;};
MeshOut MeshPS(V i){MeshOut o;o.color=float4(i.color,1);o.linearZ=i.z;return o;}
V FullVS(uint id:SV_VertexID){V o=(V)0;float2 uv=float2((id<<1)&2,id&2);o.p=float4(uv*float2(2,-2)+float2(-1,1),0,1);return o;}
float4 CompositePS(V i):SV_Target{
    uint2 pixel=uint2(i.p.xy);float4 r=radiance.Load(int3(pixel,0));
    float3 m=meshColor.Load(int3(pixel,0)).rgb;
    // 积分已在opaque网格处截断：预乘颜色+剩余透射率*最近网格颜色。
    // 不能再将r.rgb乘alpha，否则会发生重复预乘，边缘变暗。
    float3 c=foreground?r.rgb+(1-r.a)*m:m;
    if(encode)c=select(c<=.0031308,12.92*c,1.055*pow(max(c,0),1/2.4)-.055);
    return float4(c,1);
}
