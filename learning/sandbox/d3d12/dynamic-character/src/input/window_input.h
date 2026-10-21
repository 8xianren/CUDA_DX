#pragma once
#include "input/actions.h"
#include <windows.h>
#include <commctrl.h>
namespace character {
// Win32适配器借用应用窗口，不创建渲染设备；必须先于被借用窗口销毁。
class WindowInput {
    HWND window_;InputSnapshot pending_;POINT last_{};
    static LRESULT CALLBACK Procedure(HWND,UINT,WPARAM,LPARAM,UINT_PTR,DWORD_PTR);
    void Release();
public:
    explicit WindowInput(HWND);
    ~WindowInput();
    WindowInput(const WindowInput&)=delete;WindowInput& operator=(const WindowInput&)=delete;
    InputSnapshot Consume();
};
}
