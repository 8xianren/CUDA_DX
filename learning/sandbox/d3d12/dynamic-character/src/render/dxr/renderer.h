#pragma once
#include "render/frame.h"
#include "animation/animation.h"
#include <filesystem>
#include <memory>
namespace character {
struct RenderImage {
    unsigned width=0,height=0,samples=0,generation=0;
    std::vector<std::array<float,4>> color,temporalColor;
    std::vector<std::array<float,16>> motionGuides; // 仅验收读回；产品显示直接读GPU资源。
};
// PImpl隔离D3D12/CUDA/Windows类型。应用只提交快照，后端统一管理显存和同步。
class DxrRenderer {
    struct Impl;std::unique_ptr<Impl> impl_;
public:
    DxrRenderer(const Rig&,CpuScene,const RenderSettings&,const std::filesystem::path& shaders,const std::filesystem::path& energy);
    ~DxrRenderer();
    DxrRenderer(const DxrRenderer&)=delete;DxrRenderer& operator=(const DxrRenderer&)=delete;
    RenderImage Render(const RenderFrame&,bool rebuild=false);
    unsigned DebugErrors();
    const RendererStats& Stats()const;
    // 平台桥接只在App使用；领域模块不持有原生句柄。返回借用窗口，禁止调用方销毁。
    void* NativeWindow()const;
    bool PumpWindow();
    bool Suspended()const;
    void ApplyWindowResize();
};
}
