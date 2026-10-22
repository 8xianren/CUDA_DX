#pragma once
// F.4：CPU、光栅化输入与后处理共同遵守的数据约定。此文件不拥有任何 GPU 资源。
#include <cmath>
#include <cstdint>
#include <stdexcept>

namespace aa {
struct Float2 { float x=0, y=0; };
struct ClipPoint { float x=0, y=0, z=0, w=1; };

enum PostFlag : std::uint32_t {
    HistoryValid=1u<<0, Reproject=1u<<1, RejectDepth=1u<<2,
    ClampHistory=1u<<3, ClampYCoCg=1u<<4, MotionIncludesJitter=1u<<5,
    Sharpen=1u<<6 // 宿主保留位：锐化须另调 SharpenCS，TaaCS 不读取自身输出邻域。
};
// 恰好 16 DWORD；SetComputeRoot32BitConstants 的 Num32BitValues=16。
// 禁止增加 bool：C++ bool 与 HLSL bool 的存储大小不是同一个契约。
struct PostConstants {
    std::uint32_t inputWidth=1, inputHeight=1, outputWidth=1, outputHeight=1;
    Float2 jitterUV{}, previousJitterUV{};
    float historyWeight=.9f, depthRelativeThreshold=.02f;
    float fxaaThreshold=.125f, fxaaMinThreshold=.0312f;
    std::uint32_t flags=Reproject|RejectDepth|ClampHistory|ClampYCoCg, frameIndex=0;
    float sharpenStrength=0, padding=0;
};
static_assert(sizeof(PostConstants)==64, "HLSL b0 must contain exactly 16 DWORDs");

// Halton 是把 base 进制数字倒放到小数部分的 radical inverse；不是随机数生成器。
// frameIndex 从 0 开始；加 1 避免第一个 (0,0) 样本偏在像素左上角。
inline float RadicalInverse(std::uint32_t n, std::uint32_t base) {
    if(base<2) throw std::invalid_argument("Halton base must be >= 2");
    float value=0, place=1;
    while(n) { place/=float(base); value+=float(n%base)*place; n/=base; }
    return value;
}
inline Float2 HaltonJitterPixels(std::uint32_t frameIndex, std::uint32_t period=8) {
    if(!period) throw std::invalid_argument("Halton period must be positive");
    const auto n=frameIndex%period+1;
    return {RadicalInverse(n,2)-.5f,RadicalInverse(n,3)-.5f};
}
inline Float2 JitterUV(Float2 pixels, std::uint32_t width, std::uint32_t height) {
    if(!width||!height) throw std::invalid_argument("viewport must be nonempty");
    return {pixels.x/float(width),pixels.y/float(height)};
}
// D3D：NDC x 向右、y 向上；纹理 UV y 向下；z∈[0,1] 不参与此 2D 换算。
// clip.w<=0 的顶点不应提供有效历史；不把它钳成 epsilon 掩盖穿越近裁面。
inline Float2 ClipToUV(ClipPoint p) {
    if(!(p.w>0)||!std::isfinite(p.w)) throw std::invalid_argument("invalid previous clip w");
    return {.5f*(p.x/p.w+1),.5f*(1-p.y/p.w)};
}
// 本课 motion 始终 previousUV - currentUV，默认由不带 jitter 的位置生成。
// 例如当前像素向右移动 8 px，motion.x=-8/width；历史查询应往左。
inline Float2 MotionUV(ClipPoint currentNoJitter, ClipPoint previousNoJitter) {
    const auto c=ClipToUV(currentNoJitter), p=ClipToUV(previousNoJitter);
    return {p.x-c.x,p.y-c.y};
}
inline Float2 PreviousUV(Float2 uv, Float2 motion, Float2 jitter, Float2 previousJitter,
                         bool motionIncludesJitter=false) {
    return {uv.x+motion.x+(motionIncludesJitter?0:previousJitter.x-jitter.x),
            uv.y+motion.y+(motionIncludesJitter?0:previousJitter.y-jitter.y)};
}

enum class ResetReason : std::uint32_t { None, FirstFrame, CameraCut, Resize,
    FieldOfView, DynamicResolution, Teleport, ExposureDiscontinuity };
struct FrameIdentity {
    std::uint32_t renderWidth=0,renderHeight=0,displayWidth=0,displayHeight=0;
    float verticalFov=0,exposure=1;
    bool cameraCut=false,teleport=false;
};
// GPU 完成一个结果后才 Commit；Begin 不会使未写完/失效的纹理获得历史资格。
// CPU 仍需 Fence 保证纹理可复用。本类只负责语义有效性，不能代替队列同步。
class HistoryValidity {
    FrameIdentity previous_{};
    bool haveHistory_=false;
public:
    ResetReason Begin(const FrameIdentity& f) const {
        if(!haveHistory_) return ResetReason::FirstFrame;
        if(f.cameraCut) return ResetReason::CameraCut;
        if(f.teleport) return ResetReason::Teleport;
        if(f.displayWidth!=previous_.displayWidth||f.displayHeight!=previous_.displayHeight)
            return ResetReason::Resize;
        if(f.renderWidth!=previous_.renderWidth||f.renderHeight!=previous_.renderHeight)
            return ResetReason::DynamicResolution;
        if(std::abs(f.verticalFov-previous_.verticalFov)>1e-6f) return ResetReason::FieldOfView;
        // 本课不做 pre-exposure 补偿；曝光跳变须拒绝历史，不能混合不同标度的颜色。
        if(std::abs(f.exposure-previous_.exposure)>1e-6f) return ResetReason::ExposureDiscontinuity;
        return ResetReason::None;
    }
    void Commit(const FrameIdentity& f) { previous_=f; haveHistory_=true; }
    void Invalidate() { haveHistory_=false; }
};
} // namespace aa
