#include "path_pixel.hlsli"
StructuredBuffer<HistoryPixel> history : register(t0);
RWStructuredBuffer<float4> packet : register(u0);
cbuffer Packing : register(b0) { uint width,height,count,generation; };
// 六个平面，每平面width*height个float4。CPU/CUDA/OIDN均按此契约访问；
// float4的w有独立语义，不可把整个平面误认为紧密float3数组。
[numthreads(8,8,1)]
void Pack(uint3 id : SV_DispatchThreadID){
    if(id.x>=width||id.y>=height)return;
    uint i=id.y*width+id.x,n=width*height;HistoryPixel p=history[i];
    uint error=(p.meta.x!=count||p.meta.y!=generation||p.meta.z!=2||p.value.errors.x!=0||p.value.errors.y!=0)?1:0;
    packet[i]=float4(p.value.radiance.rgb,1);
    packet[n+i]=p.value.albedo; // RGB=平均反照率，w=命中覆盖率。
    packet[2*n+i]=float4(p.value.normal.xyz,0); // 单位样本法线的均值，不再归一化。
    float coverage=p.value.albedo.w;
    packet[3*n+i]=float4(coverage>0?p.value.normal.w/coverage:0,coverage,0,0);
    // 深度是“命中条件下”的平均view-z，仅诊断；RT降噪器没有depth输入。
    packet[4*n+i]=float4(0,0,0,1);
    packet[5*n+i]=asfloat(uint4(count,generation,error,0)); // 审计字段按位保存uint。
}
