#pragma once
#include <d3d12.h>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <string>

namespace aa {
enum class SdkKind { Fsr, XeSS };
enum class SdkQuality { Native, Quality, Balanced, Performance };

// 由宿主拥有的纹理。Dispatch 只借用，不 AddRef，不提交命令列表，也不等待 Fence。
// 调用前宿主必须完成下述状态转换；返回后输入状态不变，输出仍为 UAV。
// SDK 会覆盖 descriptor heaps/root signature/PSO，后续宿主绘制必须重新绑定。
struct SdkFrame {
    ID3D12GraphicsCommandList* commands = nullptr;
    ID3D12Resource* color = nullptr;       // 渲染分辨率 RGBA16_FLOAT，线性 HDR，NON_PIXEL_SHADER_RESOURCE
    ID3D12Resource* depth = nullptr;       // R32_FLOAT 或 R32_TYPELESS+D32，普通 D3D 深度，NON_PIXEL_SHADER_RESOURCE
    ID3D12Resource* motion = nullptr;      // RG16_FLOAT，current→previous，渲染像素单位，无 jitter，NON_PIXEL_SHADER_RESOURCE
    ID3D12Resource* output = nullptr;      // 输出分辨率 RGBA16_FLOAT，UNORDERED_ACCESS
    ID3D12Resource* reactive = nullptr;    // 可选 R8_UNORM，NON_PIXEL_SHADER_RESOURCE；0稳定/1响应快
    uint32_t renderWidth = 0, renderHeight = 0;
    float jitterX = 0, jitterY = 0;       // 投影注入像素偏移：+x 向右、+y 向下，[-0.5,0.5]
    float deltaTimeMs = 16.666667f;
    float nearPlane = 0.1f, farPlane = 100.0f, verticalFovRadians = 1.04719755f;
    float preExposure = 1.0f;            // 输入颜色事先乘过的比例P；本课曝光E固定1
    bool reset = false;                  // camera cut、模式切换后第一帧必须为 true
};

class SdkUpscaler {
public:
    SdkUpscaler();
    ~SdkUpscaler();
    SdkUpscaler(const SdkUpscaler&) = delete;
    SdkUpscaler& operator=(const SdkUpscaler&) = delete;

    // depsRoot = 本课 build/deps。Initialize/Shutdown/Resize 前由宿主等待所有使用该
    // context 的 GPU 工作完成。output 变化需要重建；FSR render 可在 maxRender 内逐帧变化。
    // FSR maxRender 传输出尺寸可覆盖50%–100%；XeSS还受quality的官方min/max范围约束，
    // 不能仅凭maxRender字段就认为任何质量档都支持全区间，本课XeSS采用查询的推荐尺寸。
    bool Initialize(ID3D12Device* device, SdkKind kind, SdkQuality quality,
                    uint32_t outputWidth, uint32_t outputHeight,
                    uint32_t maxRenderWidth, uint32_t maxRenderHeight,
                    const std::filesystem::path& depsRoot);
    bool Dispatch(const SdkFrame& frame);
    void Shutdown();
    bool Ready() const;
    const std::string& Status() const;
    const std::string& Provider() const;
    uint32_t RecommendedWidth() const;
    uint32_t RecommendedHeight() const;
    // 内部分辨率变化后重新查询，不能把Native的8相固定套到所有超分倍率。
    // FSR用官方query；XeSS按官方“至少8*(输出宽/输入宽)^2”取上整。
    uint32_t JitterPhaseCount(uint32_t renderWidth, uint32_t outputWidth) const;
private:
    struct Impl;
    std::unique_ptr<Impl> p_;
};
} // namespace aa
