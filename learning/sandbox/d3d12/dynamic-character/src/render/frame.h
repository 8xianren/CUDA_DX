#pragma once
#include "core/math.h"
#include <vector>
#include <cstdint>
namespace character {
// 渲染入口只读快照：没有按键、角色状态枚举、Assimp指针或OS窗口。
// 提交期间由调用方保持有效；后端必须复制进自己的帧资源才能异步跨帧使用。
struct RenderFrame {
    Vec3 eye,forward;float tanHalfFov=.45f;
    Mat4 characterWorld;
    std::vector<Mat4> rigWorlds;
    std::vector<std::vector<Mat4>> palettes;
    uint64_t sceneRevision=0,lightRevision=0;
    float lightScale=1,exposure=0;
    unsigned spp=1,maxScatters=4;
    bool resetHistory=false,temporal=false;
    // 由应用明确选择展示环境；测试默认保留旧黑背景，历史必须在配置变化后失效。
    bool skyEnabled=false,smoothNormals=false;float skyIntensity=1;
};
struct RenderSettings {unsigned width=320,height=180;bool validation=true,window=false,readback=true;};
struct RendererStats {
    double frameMilliseconds=0,cudaMilliseconds=0,asMilliseconds=0,pathMilliseconds=0,temporalMilliseconds=0,displayMilliseconds=0;
    uint64_t frameNumber=0,localMemoryBytes=0;unsigned accumulatedSamples=0;
};
}
