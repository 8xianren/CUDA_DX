#pragma once
#include <cuda_runtime.h>
#include <cstdint>
#include <vector>

namespace neural::volume {
// 世界盒固定为 [-1,1]^3。相机采用 +Z 前方、+Y 上方、图像行向下；
// 三个基向量由调用者保证正交归一，aspect 由输出 width/height 决定。
struct Camera {
    float3 origin{0, 0, -3};
    float3 right{1, 0, 0}, up{0, 1, 0}, forward{0, 0, 1};
    float tanHalfFovY = 0.41421356237f;
};
struct RenderOptions {
    int width = 320, height = 180;
    float step = 0.015625f;       // 世界距离；射线方向在内核中归一化。
    float termination = 0.001f;   // T 小于此值时停止；0 表示不提前终止。
    bool skipEmpty = false;
    bool jitter = false;         // 确定性像素哈希；只移动段内求积点，不改变段长。
    unsigned seed = 0;
};
struct PixelStats {
    unsigned samples = 0, skipped = 0, hit = 0, terminated = 0;
};
struct Field {
    int resolution = 0;
    std::vector<float> density;  // ((z*N+y)*N+x)，x 连续，样本在体素中心。
};
// 解析密度球与稠密场使用同一密度函数；G.1 直接求函数，G.2 采样离散网格。
float AnalyticDensity(float3 p);
Field MakeSphereField(int resolution = 128);
std::vector<float4> RenderCpu(const Field* field, const Camera&, const RenderOptions&,
                             std::vector<PixelStats>* stats = nullptr,
                             const float* meshRayDistance = nullptr);

// 对象独占 CUDA array、texture object 和保守 occupancy grid，禁止浅拷贝。
// 构造完成时上传已经完成。Render 异步入队；输出/深度/统计缓冲由调用方拥有。
class Volume {
public:
    explicit Volume(const Field& field);
    ~Volume();
    Volume(const Volume&) = delete;
    Volume& operator=(const Volume&) = delete;
    // rgbaDevice: width*height 个 float4，线性 RGB 已预乘 alpha，透明背景。
    // depthDevice: 可空，写入首次累计 alpha>=0.5 的世界射线距离，无命中为 +inf；
    // 它是显示/教学代表深度，不能把整个半透明体当作不透明表面使用。
    // meshRayDistance: 可空，不透明网格的正世界射线距离；体积分在此截断。
    // statsDevice: 可空，每像素统计。stream 必须与输出资源的 producer fence 同序。
    // 返回只保证启动成功；调用方需同步/检查异步错误后才能读回或释放资源。
    void Render(float4* rgbaDevice, const Camera&, const RenderOptions&,
                cudaStream_t stream = nullptr, float* depthDevice = nullptr,
                const float* meshRayDistance = nullptr, PixelStats* statsDevice = nullptr) const;
    std::uint64_t StorageBytes() const;
private:
    struct Impl;
    Impl* impl_ = nullptr;
};
} // namespace neural::volume
