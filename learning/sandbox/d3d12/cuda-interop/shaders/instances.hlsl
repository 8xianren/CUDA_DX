// 与C++/CUDA一致：80B stride，world偏移0，color偏移64。
struct Instance { row_major float4x4 world; float4 color; };
StructuredBuffer<Instance> objects : register(t0);
cbuffer Camera : register(b0) { row_major float4x4 viewProjection; };
cbuffer Draw : register(b1) { uint objectIndex; };
cbuffer Work : register(b2) { uint pixelIterations; };
struct Varying { float4 position:SV_Position; nointerpolation float4 color:COLOR0; };
Varying VS(float3 position:POSITION) {
    Varying v;
    v.position=mul(viewProjection,mul(objects[objectIndex].world,float4(position,1)));
    v.color=objects[objectIndex].color;return v;
}
float4 PS(Varying v):SV_Target {
    // E.3可控像素ALU压力，结果写入RT，不能当成无用循环删除；E.1/E.2参数为0。
    // 显式合成负载不等于生产材质。固定迭代数而非按墙钟运行，比较时工作量一致。
    float3 c=v.color.rgb;
    [loop] for(uint i=0;i<pixelIterations;++i)c=frac(c*1.0001f+0.00001f);
    return float4(c,v.color.a);
}
