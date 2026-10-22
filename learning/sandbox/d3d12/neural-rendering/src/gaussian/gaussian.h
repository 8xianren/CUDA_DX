#pragma once
#include <cstdint>
#include <cuda_runtime.h>
#include <memory>
#include <vector>

namespace gs {
// 运行时表示保存已解码的正尺度与 [0,1] opacity；PLY 的 log-scale/logit 必须由资产层转换。
// SH 以 [basis][RGB] 交错，degree 0..3 共 1/4/9/16 个基函数；不是 PLY 的逐通道 rest 布局。
// 四元数顺序 w,x,y,z。id 是资产稳定身份，不是本帧数组索引，排序相同深度时用它破除平局。
struct Gaussian {
    float mean[3]{};
    float scale[3]{.1f, .1f, .1f};
    float rotation[4]{1, 0, 0, 0};
    float opacity{.5f};
    float sh[48]{};
    uint32_t id{};
    uint32_t shDegree{};
};
struct Camera {
    // 前三列是世界到相机的旋转，第四列是平移；相机 +Z 前、+Y 上，像素 +Y 下。
    float worldToCamera[12]{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0};
    float fx{100}, fy{100}, cx{64}, cy{48};
    int width{128}, height{96};
    float nearPlane{.05f}, maxRadiusPixels{2048};
};
enum class Reject : uint32_t { Visible, NonFinite, BehindCamera, Degenerate, Oversize, Offscreen, Count };
struct Projected {
    float u{}, v{}, z{}, xx{}, xy{}, yy{}; // 协方差含 0.3 pixel² 重建低通项。
    float conic[3]{};                      // 对称逆协方差 (A,B,C)，指数 -0.5*(A dx²+2B dxdy+C dy²)。
    float rgb[3]{}, opacity{};
    int minX{}, minY{}, maxX{}, maxY{}; // 半开像素矩形，裁剪到 viewport。
    int tileMinX{}, tileMinY{}, tileMaxX{}, tileMaxY{};
    uint32_t id{}, tileCount{};
    Reject reject{Reject::NonFinite};
};
struct Reference {
    uint64_t key{};
    uint32_t index{}, id{};
};
struct Stats {
    uint32_t gaussianCount{}, visibleCount{}, references{}, tiles{};
    uint32_t rejected[static_cast<unsigned>(Reject::Count)]{};
    size_t persistentBytes{}, scratchBytes{};
    float projectMs{}, scanMs{}, duplicateMs{}, sortMs{}, rangesMs{}, splatMs{};
};
// CPU 参考与 GPU 用相同数据契约，独立构造列表/合成循环；float 运算允许舍入误差。
Projected projectCpu(const Gaussian &, const Camera &);
std::vector<Reference> referencesCpu(const std::vector<Gaussian> &, const std::vector<Projected> &,
                                     const Camera &);
std::vector<float4> splatCpu(const std::vector<Projected> &, const std::vector<Reference> &, const Camera &,
                             const float *meshLinearZ = nullptr);
std::vector<Gaussian> makeScene(uint32_t count = 256);

class Renderer {
  public:
    Renderer();
    ~Renderer();
    Renderer(const Renderer &) = delete;
    Renderer &operator=(const Renderer &) = delete;
    void setScene(std::vector<Gaussian> scene);
    // 输出由调用方分配，RGBA 为线性预乘，A=1-T；z 为有贡献高斯的归一化加权平均相机 Z，空像素为 +inf。
    // meshLinearZ 可为空；不为空时只累积 mean.z 小于网格深度的高斯。这是中心深度近似，不是体积精确裁切。
    // 所有核/CUB 操作在 stream 顺序执行。为了检查 prefix 总数和回传计时，本教学 API 在返回前同步该 stream。
    Stats render(const Camera &, float4 *rgba, float *z = nullptr, const float *meshLinearZ = nullptr,
                 cudaStream_t stream = nullptr);
    const std::vector<Gaussian> &scene() const;
    std::vector<Projected> readProjected() const;
    std::vector<Reference> readReferences() const;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
} // namespace gs
