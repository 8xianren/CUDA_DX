// R.13.8b：独立光栅显示pass。t0直接读取DXR写入的同一块float4历史（xyz均值，w计数）。
// 根SRV只传buffer GPU地址，StructuredBuffer<float4>确定16字节stride，不需要采样器。
StructuredBuffer<float4> hdrHistory : register(t0);
cbuffer Display : register(b0) {
    uint4 sourceRect;    // 内部HDR有效ViewRect：x/y/w/h，不等于窗口尺寸。
    uint4 destination;   // 保持源比例后在Back Buffer中的x/y/w/h，外围写黑。
    uint sourceStride;   // HDR每行像素数=160，非字节数。
    float exposureEV;    // 相对补偿，不写回HDR或计数。
    uint2 reserved;      // 总计12 DWORD=48B；宿主与shader必须同时重编译。
};
float4 VSMain(uint id : SV_VertexID) : SV_Position {
    // 无VB：三个裁剪空间顶点(-1,-1),(-1,3),(3,-1)，覆盖整个[-1,1]^2。
    // 超出视口的部分由光栅化裁剪；关闭剔除，无深度，无混合。
    float2 p = id==0 ? float2(-1,-1) : (id==1 ? float2(-1,3) : float2(3,-1));
    return float4(p,0,1);
}
float encode_srgb(float x) {
    return x<=0.0031308 ? 12.92*x : 1.055*pow(x,1.0/2.4)-0.055;
}
float4 PSMain(float4 position : SV_Position) : SV_Target {
    uint2 p=uint2(position.xy);
    if(any(p<destination.xy)||any(p>=destination.xy+destination.zw))return float4(0,0,0,1);
    // 目标像素中心归一化，再映到源ViewRect。整数有理式避免float在源像素边界两侧舍入。
    // 本课窗口<=4096，源<=160x96，乘法不溢出。禁止零尺寸进入绘制。
    uint2 local=p-destination.xy;
    uint2 pixel=sourceRect.xy+((2*local+1)*sourceRect.zw)/(2*destination.zw);
    float3 exposed=hdrHistory[pixel.y*sourceStride+pixel.x].xyz*exp2(exposureEV);
    float3 linearDisplay=exposed/(1+exposed);
    // PSO与RTV均为R8G8B8A8_UNORM，故这里手动且仅做一次sRGB；alpha固定1、不编码。
    return float4(encode_srgb(linearDisplay.r),encode_srgb(linearDisplay.g),encode_srgb(linearDisplay.b),1);
}
