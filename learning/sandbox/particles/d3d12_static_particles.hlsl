// P.4.2 静态粒子着色器
//
// 本例不创建传统 Vertex Buffer。每个粒子实例固定绘制 6 个顶点，
// Vertex Shader 用 SV_VertexID 在代码内生成两个三角形组成的四边形，
// 再用 SV_InstanceID 从 SoA StructuredBuffer 中读取该粒子的位置与颜色。

// 同一块 D3D12 Buffer 的第一个 float4[N] 区段被创建为 t0 SRV。
// xyz 是裁剪空间中心位置；w 暂时作为粒子半径（NDC 单位）。
StructuredBuffer<float4> gPositions : register(t0);

// 同一块 Buffer 的第三个 float4[N] 区段被创建为 t1 SRV。
// 中间的 velocity 区段本节不参与渲染，因此没有绑定到 Root Signature。
StructuredBuffer<float4> gColors : register(t1);

struct VertexOutput
{
    float4 clipPosition : SV_Position;
    float4 color        : COLOR0;

    // localPosition 是四边形内部的局部坐标，范围约为 [-1, 1]。
    // Pixel Shader 用它判断像素是否位于单位圆内，从而把方片裁成圆粒子。
    float2 localPosition : TEXCOORD0;
};

VertexOutput VSMain(uint vertexId : SV_VertexID,
                    uint instanceId : SV_InstanceID)
{
    // 两个三角形组成一个 quad。DrawInstanced 每个实例提交 6 个顶点，
    // 所以 vertexId 对每个实例都在 [0, 5] 范围内。
    static const float2 corners[6] =
    {
        float2(-1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0),
        float2(-1.0, -1.0),
        float2( 1.0,  1.0),
        float2( 1.0, -1.0)
    };

    const float4 positionSize = gPositions[instanceId];
    const float2 local = corners[vertexId];

    VertexOutput output;
    // NDC 的 x/y 都是 [-1, 1]，但它们分别铺满 1280 和 720 个像素。
    // 若两个方向直接使用相同 NDC 半径，一个逻辑上的圆会在宽屏窗口里变成
    // 横向椭圆。x 半径乘 height/width 后，最终像素半径满足：
    //   xPixels = radius * (height/width) * width/2
    //           = radius * height/2
    //           = yPixels
    // 本节窗口大小固定，所以先写成编译期常量；支持窗口缩放时应把尺寸或
    // 逆 viewport 通过 Constant Buffer/Root Constants 传给着色器。
    static const float aspectCorrection = 720.0 / 1280.0;
    const float2 screenCorrectedRadius =
        float2(positionSize.w * aspectCorrection, positionSize.w);

    output.clipPosition = float4(
        positionSize.xy + local * screenCorrectedRadius,
        positionSize.z,
        1.0);
    output.color = gColors[instanceId];
    output.localPosition = local;
    return output;
}

float4 PSMain(VertexOutput input) : SV_Target0
{
    const float radiusSquared = dot(input.localPosition,
                                    input.localPosition);

    // quad 四角位于单位圆外。clip(x) 在 x < 0 时丢弃当前像素，
    // 因而只留下 localPosition 长度不超过 1 的圆形区域。
    clip(1.0 - radiusSquared);

    // 在圆周附近做一个简单亮度渐变，让粒子边缘更容易观察。
    // 这不是严格的屏幕空间抗锯齿；后续可以使用 fwidth/smoothstep 改进。
    const float edgeLighting =
        0.55 + 0.45 * saturate((1.0 - radiusSquared) * 4.0);
    return float4(input.color.rgb * edgeLighting, 1.0);
}
