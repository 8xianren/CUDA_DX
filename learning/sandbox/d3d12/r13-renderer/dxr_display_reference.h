#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <stdexcept>

// R.13.8a：显示数学的CPU参考。输入是未曝光、scene-linear、按线性sRGB原色解释的RGB。
// 本课只处理非负、有限的光照数据；不声称能处理任意广色域转换后的负RGB。
// 所有函数只返回新值，不修改渲染历史，没有GPU资源、异步操作或所有权转移。
namespace display_reference {
inline void require(bool ok,const char* message) { if(!ok)throw std::runtime_error(message); }
inline double unit(double x) { return std::clamp(x,0.0,1.0); }

// 参数是“相对曝光补偿”，不是由快门/光圈/ISO定义的相机绝对EV。
// 限制范围使测试和后续UI使用同一有效输入约束；失败抛异常，不能静默产生NaN。
inline double exposure_multiplier(double compensationEV) {
    require(std::isfinite(compensationEV)&&std::abs(compensationEV)<=16,"Exposure compensation outside [-16,16]");
    return std::exp2(compensationEV);
}
inline double reinhard(double exposed) {
    require(std::isfinite(exposed)&&exposed>=0,"Invalid exposed radiance");
    return exposed/(1.0+exposed); // 对每个通道分别压缩；这是教学曲线，不是UE的完整film管线。
}
// 输入是显示端线性RGB分量，不是未压缩HDR；输出是sRGB码值，尚未量化。
// 规范的分段函数不是简单pow(x,1/2.2)，alpha也不能套用此RGB编码。
inline double srgb_encode(double linear) {
    require(std::isfinite(linear)&&linear>=0&&linear<=1,"sRGB input outside [0,1]");
    return linear<=0.0031308?12.92*linear:1.055*std::pow(linear,1.0/2.4)-0.055;
}
inline double srgb_decode(double encoded) {
    require(std::isfinite(encoded)&&encoded>=0&&encoded<=1,"sRGB code outside [0,1]");
    return encoded<=0.04045?encoded/12.92:std::pow((encoded+0.055)/1.055,2.4);
}
// 明确采用half-up取整。后续GPU格式转换在恰好半码点上可能采用不同tie规则；
// CPU/GPU对照应解释这种1码差异，不能把本函数视为所有硬件舍入规则的复制。
inline uint8_t quantize8(double encoded) {
    require(std::isfinite(encoded),"Non-finite display code");
    return static_cast<uint8_t>(std::floor(255.0*unit(encoded)+0.5));
}
inline double display_linear(double history,double compensationEV) {
    require(std::isfinite(history)&&history>=0,"Invalid linear history");
    return reinhard(history*exposure_multiplier(compensationEV));
}
inline uint8_t display_byte(double history,double compensationEV) {
    return quantize8(srgb_encode(display_linear(history,compensationEV)));
}
} // namespace display_reference
