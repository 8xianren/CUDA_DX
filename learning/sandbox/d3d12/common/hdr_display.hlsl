// R.13/PT.10共用光栅显示pass：直接读取GPU线性历史，无CPU上传图像。
// ByteAddressBuffer显式接收像素字节步长，RGB占每条记录开头12B；无纹理采样器。
ByteAddressBuffer hdrHistory : register(t0);
cbuffer Display : register(b0) {
    uint4 sourceRect;    // 内部HDR有效ViewRect：x/y/w/h，不等于窗口尺寸。
    uint4 destination;   // 保持源比例后在Back Buffer中的x/y/w/h，外围写黑。
    uint sourceStride;   // HDR每行像素数，非字节数。
    float exposureEV;    // 相对补偿，不写回HDR或计数。
    uint pixelByteStride; // R.13=16，PT.10=128；RGB均在各像素记录开头。
    uint mode;      // 总计12 DWORD=48B；宿主与shader必须同时重编译。
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
    // 窗口/源<=4096，乘法不溢出。禁止零尺寸进入绘制。
    uint2 local=p-destination.xy;
    uint2 pixel=sourceRect.xy+((2*local+1)*sourceRect.zw)/(2*destination.zw);
    uint address=(pixel.y*sourceStride+pixel.x)*pixelByteStride;
    float3 hdr=asfloat(hdrHistory.Load3(address));
    // 非有限值应由积分验收拒绝；显示时显式标紫，避免悄悄转成看似正常的黑色。
    if(any(!isfinite(hdr))||any(hdr<0))return float4(1,0,1,1);
    float3 exposed=hdr*exp2(exposureEV);
    float3 linearDisplay=mode==1?saturate(exposed):exposed/(1+exposed);
    // mode2/3专供“漏编码/重复编码”负对照，正常显示固定mode0。
    if(mode==2)return float4(linearDisplay,1);
    float3 encoded=float3(encode_srgb(linearDisplay.r),encode_srgb(linearDisplay.g),encode_srgb(linearDisplay.b));
    if(mode==3)encoded=float3(encode_srgb(encoded.r),encode_srgb(encoded.g),encode_srgb(encoded.b));
    // PSO与RTV均为R8G8B8A8_UNORM，故这里手动且仅做一次sRGB；alpha固定1、不编码。
    return float4(encoded,1);
}
