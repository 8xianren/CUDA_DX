#ifndef TEACHING_SKY_ENVIRONMENT_HLSLI
#define TEACHING_SKY_ENVIRONMENT_HLSLI

// H 阶段的程序环境：它是按世界方向查询的线性 HDR 辐亮度函数，并不是贴在
// 最后显示阶段的背景色。因此同一个天空会出现在主射线、反射和间接光中。
// +Y 是天顶。这里的渐变/光晕是美术可控近似，并非大气散射或真实太阳光谱。
// 参数暂时是 shader 常量；CPU 的 environmentIntensity 同时缩放天空与太阳。
// 太阳的 0.6 度角半径有意比地球上太阳约 0.27 度的角半径大，使本课低采样
// 阴影边缘容易观察。辐亮度与角半径必须共同决定照度，不能把盘面亮度当功率。
static const float SkyPi = 3.14159265358979323846;
static const float SkySunCosRadius = 0.9999451693655121; // cos(0.6 degree)
static const float3 SkySunRadiance = float3(12000, 10440, 8280);

float3 SkySunDirection() { return normalize(float3(-.48, .68, -.553)); }

// 低频环境与高亮太阳拆成两个积分项。这样每个非 delta 顶点都可以各采一条
// 阴影射线，避免每帧只有 1 spp 时因“这次没选太阳”而丢掉整份直接日光。
float3 SkyDomeRadiance(float3 direction) {
    float height = saturate(direction.y);
    float3 horizon = float3(.45, .70, 1.50);
    float3 zenith = float3(.04, .18, .80);
    float3 lower = float3(.13, .12, .10);
    float3 color = direction.y >= 0
        ? lerp(horizon, zenith, pow(height, .45))
        : lerp(horizon, lower, saturate(-direction.y * 5));
    // 宽光晕归入低频天空；它不是后处理 bloom，也不把太阳圆盘扩大。
    float halo = pow(saturate(dot(direction, SkySunDirection())), 32);
    return color + float3(.32, .21, .10) * halo;
}

float SkySunPdf(float3 direction) {
    // dω = dφ d(cosθ)，球冠的立体角 Ω = 2π(1-cosθmax)。
    // PDF 的单位是 sr^-1，不是屏幕面积密度或 θ 的概率密度。
    return dot(direction, SkySunDirection()) >= SkySunCosRadius
        ? 1 / (2 * SkyPi * (1 - SkySunCosRadius)) : 0;
}

float3 SkyDiskRadiance(float3 direction) {
    return SkySunPdf(direction) > 0 ? SkySunRadiance : float3(0, 0, 0);
}

float SkyDomePdf() { return 1 / (4 * SkyPi); }

float3 SampleSkyDome(float2 random) {
    // 均匀球面采样：cosθ 均匀，θ 本身不能均匀。完整球面也覆盖地平线下方
    // 的环境，倾斜表面和镜面因此没有被静默截去半个环境；背面样本由调用者拒绝。
    float y = 1 - 2 * random.x;
    float r = sqrt(max(0, 1 - y * y));
    float phi = 2 * SkyPi * random.y;
    return float3(r * cos(phi), y, r * sin(phi));
}

float3 SampleSkySun(float2 random) {
    float3 sun = SkySunDirection();
    float3 tangent = normalize(cross(float3(0, 1, 0), sun));
    float3 bitangent = cross(sun, tangent);
    float cosine = lerp(1, SkySunCosRadius, random.x);
    float sine = sqrt(max(0, 1 - cosine * cosine));
    float phi = 2 * SkyPi * random.y;
    return normalize(sun * cosine + sine * (cos(phi) * tangent + sin(phi) * bitangent));
}

// 本实现按 PBRT 4e 的均匀球面/球冠方向采样和无限远环境光约定编写：
// https://pbr-book.org/4ed/Sampling_Algorithms/Sampling_Multidimensional_Functions
// https://pbr-book.org/4ed/Light_Sources/Infinite_Area_Lights
#endif
