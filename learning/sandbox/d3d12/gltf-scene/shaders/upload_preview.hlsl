// D.1仅验证局部网格的GPU输入；xy缩放/偏移是诊断用正交映射，不是D.2世界相机。
cbuffer Draw : register(b0) {
    float4 xyMap; // xy为缩放，zw为平移
    float4 baseColor;
};
Texture2D<float4> baseTexture : register(t0);
SamplerState previewSampler : register(s0);
struct Input {float3 position:POSITION;float2 uv:TEXCOORD;float4 color:COLOR;};
struct Varying {float4 position:SV_Position;float2 uv:TEXCOORD;float4 color:COLOR;};
Varying VS(Input i) {
    Varying o;o.position=float4(i.position.xy*xyMap.xy+xyMap.zw,0.5,1);
    // C.3实测Assimp把glTF的v变为1-v；WIC行0为图片顶部，预览显式还原。
    o.uv=float2(i.uv.x,1-i.uv.y);o.color=i.color;return o;
}
float4 PS(Varying i):SV_Target {
    // SRGB SRV自动把RGB变为线性；因子和顶点颜色已经是线性值，不重复解码。
    // 输出是基础色诊断，不含光照/HDR曝光与色调映射；SRGB RTV只做输出编码。
    return float4(baseTexture.SampleLevel(previewSampler,i.uv,0).rgb*baseColor.rgb*i.color.rgb,1);
}
