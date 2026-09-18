// R.1/R.2/R.3 的 shader 演示“真实 Vertex/Index Buffer 如何进入 VS”。
// Index Buffer 由 Input Assembler 消费，不需要在 HLSL 中声明资源；它决定每次
// VS 调用选取哪个 Vertex，Input Layout 再把该 Vertex 的属性填入 VertexInput。
// R.3 新增 b0 Constant Buffer：矩阵由 CPU 构造并上传，shader 只应用它。

cbuffer ObjectConstants : register(b0)
{
    // 现在只上传 View * Projection。每实例自己的 World 在 StructuredBuffer 里。
    // 显式 row_major，使内存中的行排列和 DirectXMath 保存的 XMFLOAT4X4 一致。
    row_major float4x4 gViewProjection;
};

// 每实例数据走 StructuredBuffer，不走 CBV：元素可以是 96 字节，不必 256 对齐。
// t1 由 Root SRV 提供 GPU 地址；Root SRV 没有 NumElements，Shader 不得越界。
struct InstanceData
{
    row_major float4x4 world; // 64 bytes
    float4 color;             // 16 bytes
    uint instanceId;          // 4 bytes
    uint3 _pad;               // 12 bytes -> stride=96，16 字节对齐
};
StructuredBuffer<InstanceData> gInstances : register(t1);

// 材质是 CPU 侧策略数据，不是纹理像素本身。C++ 每 Draw 一次通过 root
// constants 写入 b1；它不拥有 Texture Resource，也不替代 PSO。
// alphaMode：0=OPAQUE，1=MASK，2=BLEND，对齐 glTF 的字符串语义。
cbuffer MaterialConstants : register(b1)
{
    float4 gBaseColorFactor; // 线性 RGB + 覆盖度 A
    float gMetallicFactor;
    float gRoughnessFactor;
    float gAlphaCutoff;
    uint gAlphaMode;
};

// Texture2D 是 Shader 对纹理资源的逻辑访问接口；它不保存像素本身。
// t0 会由 C++ 的 SRV 描述符表映射到实际的二维纹理资源。
Texture2D<float4> gColorTexture : register(t0);

// SamplerState 保存过滤和寻址规则。它不是纹理，也不是 SRV；s0 会由独立的
// SAMPLER 描述符堆中的采样器描述符提供。
SamplerState gColorSampler : register(s0);

struct VertexInput
{
    // 语义名 POSITION/ COLOR 必须和 C++ Input Layout 的 SemanticName 相同。
    float3 position : POSITION;
    float4 color    : COLOR0;
    float2 uv       : TEXCOORD0;
    // SV_InstanceID 由 IA 生成，不是 Vertex Buffer 里的属性。
    // 硬件会加上 DrawIndexedInstanced 的 StartInstanceLocation。
    uint instanceId : SV_InstanceID;
};

struct VertexOutput
{
    float4 clipPosition : SV_Position;
    float4 color        : COLOR0;
    float2 uv           : TEXCOORD0;
};

VertexOutput VSMain(VertexInput input)
{
    VertexOutput output;
    InstanceData inst = gInstances[input.instanceId];
    // 行向量：Local * InstanceWorld * ViewProjection。
    // 网格顶点仍来自共享 VB；World 每实例一份，来自 StructuredBuffer。
    float4 world_position = mul(float4(input.position, 1.0f), inst.world);
    output.clipPosition = mul(world_position, gViewProjection);
    output.color = input.color * inst.color;
    output.uv = input.uv;
    return output;
}

float4 PSMain(VertexOutput input) : SV_Target0
{
    // t0 的 SRV 格式是 R8G8B8A8_UNORM_SRGB。Sample 返回前，GPU 已把纹理
    // RGB 从 sRGB 编码值解码到线性空间；Alpha 不经过 sRGB 曲线，仍是 0..1
    // 覆盖度。input.color 与 gBaseColorFactor 也约定为线性乘数。
    float4 sampled =
        gColorTexture.Sample(gColorSampler, input.uv) * input.color *
        gBaseColorFactor;

    // metallic/roughness 真正进入 BRDF 是后续 glTF/PBR 的事。这里只做可见的
    // 非物理调制，证明材质字段已经被绑定；不能把下面两行当成金属工作流。
    sampled.rgb = lerp(sampled.rgb,
                       sampled.rgb * float3(0.72f, 0.73f, 0.76f),
                       saturate(gMetallicFactor));
    sampled.rgb *= lerp(0.62f, 1.0f, saturate(gRoughnessFactor));

    if (gAlphaMode == 0) {
        // OPAQUE：覆盖度固定为 1。BlendEnable=FALSE 时硬件不会自动改写 Alpha，
        // 所以必须在 Shader 里明确输出，避免以后离屏合成读到纹理残值。
        sampled.a = 1.0f;
    } else if (gAlphaMode == 1) {
        // MASK：小于 cutoff 的 texel 直接丢弃，不写入颜色也不写入深度。
        // 通过测试后仍按不透明表面处理，因此输出 Alpha=1。
        clip(sampled.a - gAlphaCutoff);
        sampled.a = 1.0f;
    }
    // BLEND 保留 sampled.a，交给透明 PSO 的 straight-alpha BlendState。

    return sampled;
}
