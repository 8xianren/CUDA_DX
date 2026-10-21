#include "instance_shared.hlsli"
// 一次draw一个node-primitive引用；ObjectIndex是每对象常量，不复制共享顶点。
cbuffer ObjectIndex : register(b1) {uint objectIndex;};
struct Output {float4 position:SV_Position;nointerpolation uint id:INSTANCE;};
Output VS(float3 localPosition:POSITION) {
    Output o;o.position=mul(viewProjection,mul(objects[objectIndex].world,float4(localPosition,1)));
    o.id=objectIndex;return o;
}
uint4 PS(Output input,uint primitive:SV_PrimitiveID):SV_Target {
    return uint4(input.id+1,objects[input.id].material+1,primitive+1,0);
}
