// F.9：可解析运动的测试场景。并非 CPU 插值；每个真实帧由 GPU 像素着色器绘制，
// 额外帧由 AMD 官方帧生成 DLL 根据连续颜色、深度与运动矢量计算。
cbuffer Scene : register(b0)
{
    float width;
    float height;
    float currentX;
    float previousX;
};
float4 VSMain(uint vertex : SV_VertexID) : SV_Position
{
    // 超大的全屏三角形免去对角线接缝；光栅器会裁剪屏幕以外区域。
    float2 p = float2((vertex << 1) & 2, vertex & 2);
    return float4(p * float2(2, -2) + float2(-1, 1), 0, 1);
}
struct Targets
{
    float4 color : SV_Target0;
    float depth : SV_Target1;
    float2 motion : SV_Target2;
};
Targets PSMain(float4 position : SV_Position)
{
    Targets o;
    float2 p = position.xy;
    float checker = fmod(floor(p.x / 32) + floor(p.y / 32), 2);
    float3 c = lerp(float3(.10, .17, .24), float3(.20, .27, .34), checker);
    float z = 20;
    o.motion = 0;
    bool object = abs(p.x - currentX) < 74 && abs(p.y - height * .52) < 100;
    if (object)
    {
        c = float3(.95, .24, .06);
        // SDK 契约是当前位置 -> 上帧位置。值已是像素，调用端的 scale=(1,1)。
        // 物体往右，历史位置在左，所以 currentX 增大时运动矢量为负。
        o.motion = float2(previousX - currentX, 0);
        z = 2;
    }
    // 固定前景细杆有意遮挡运动方块，暴露插值中的遮挡/显露边界。
    if (p.y > height * .25 && p.y < height * .82 && fmod(p.x, 160) < 5)
    {
        c = float3(.04, .7, .25);
        o.motion = 0;
        z = 1;
    }
    // 正向 D3D 深度 [0,1]，near=.1, far=100，匹配 prepare 的相机参数。
    // 从 d(n)=0、d(f)=1 得 d(z)=f/(f-n)-fn/((f-n)z)。不是线性距离。
    o.depth = 100.0 / 99.9 - 10.0 / (99.9 * z);
    // SDR 编码值直接存 UNORM；SDK 的 swapchain 以 sRGB transfer function 解释。
    o.color = float4(c, 1);
    return o;
}
