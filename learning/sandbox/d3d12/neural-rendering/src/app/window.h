#pragma once
#include "gpu_resources.h"
namespace neural {
// 教学交互只允许两个已导出NeRF相机尺寸，用R切换；关闭窗口结束。
// 固定窗口尺寸使离线NeRF缓存的相机契约不会被任意拖动悄悄破坏。
class Window {
    UploadContext& c;HWND hwnd=nullptr;ComPtr<IDXGISwapChain3> swap;
    std::array<aa::Texture,2> buffers;
public:
    UINT width=0,height=0,presents=0;
    Window(UploadContext&,UINT,UINT);~Window();
    aa::Texture& Back();void Resize(UINT,UINT);void Present();bool Pump();
    void Title(const std::wstring&);
};
}
