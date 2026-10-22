#include "window.h"
#include <stdexcept>
namespace neural {
static LRESULT CALLBACK Procedure(HWND h,UINT m,WPARAM w,LPARAM l){
    if(m==WM_CLOSE){DestroyWindow(h);return 0;}
    return DefWindowProcW(h,m,w,l);
}
Window::Window(UploadContext& context,UINT w,UINT h):c(context){
    WNDCLASSW wc{};wc.lpfnWndProc=Procedure;wc.hInstance=GetModuleHandleW(nullptr);wc.lpszClassName=L"GNeuralRendering";
    RegisterClassW(&wc);DWORD style=WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU|WS_MINIMIZEBOX;
    RECT r{0,0,LONG(w),LONG(h)};AdjustWindowRect(&r,style,FALSE);
    hwnd=CreateWindowW(wc.lpszClassName,L"G1-G10 | 1 Mesh  2 Volume  3 Gaussian  4 NeRF  R Resize",style,
        CW_USEDEFAULT,CW_USEDEFAULT,r.right-r.left,r.bottom-r.top,nullptr,nullptr,wc.hInstance,nullptr);
    if(!hwnd)throw std::runtime_error("G window creation failed");
    ComPtr<IDXGIFactory4> factory;Check(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory)),"G factory");
    DXGI_SWAP_CHAIN_DESC1 d{};d.Width=w;d.Height=h;d.Format=DXGI_FORMAT_R8G8B8A8_UNORM;d.SampleDesc.Count=1;
    d.BufferCount=2;d.BufferUsage=DXGI_USAGE_RENDER_TARGET_OUTPUT;d.SwapEffect=DXGI_SWAP_EFFECT_FLIP_DISCARD;
    ComPtr<IDXGISwapChain1> initial;Check(factory->CreateSwapChainForHwnd(c.queue.Get(),hwnd,&d,nullptr,nullptr,&initial),"G swapchain");
    Check(initial.As(&swap),"G swap3");factory->MakeWindowAssociation(hwnd,DXGI_MWA_NO_ALT_ENTER);
    Resize(w,h);ShowWindow(hwnd,SW_SHOW);
}
Window::~Window(){if(hwnd&&IsWindow(hwnd))DestroyWindow(hwnd);}
aa::Texture& Window::Back(){return buffers[swap->GetCurrentBackBufferIndex()];}
void Window::Resize(UINT w,UINT h){
    c.SubmitWait();for(auto& b:buffers)b.resource.Reset();
    Check(swap->ResizeBuffers(2,w,h,DXGI_FORMAT_R8G8B8A8_UNORM,0),"G ResizeBuffers");width=w;height=h;
    for(UINT i=0;i<2;++i){auto& b=buffers[i];b.width=w;b.height=h;b.format=DXGI_FORMAT_R8G8B8A8_UNORM;b.state=D3D12_RESOURCE_STATE_PRESENT;
        Check(swap->GetBuffer(i,IID_PPV_ARGS(&b.resource)),"G backbuffer");}
    RECT r{0,0,LONG(w),LONG(h)};AdjustWindowRect(&r,DWORD(GetWindowLongPtrW(hwnd,GWL_STYLE)),FALSE);
    SetWindowPos(hwnd,nullptr,0,0,r.right-r.left,r.bottom-r.top,SWP_NOMOVE|SWP_NOZORDER);
}
void Window::Present(){Back().To(c,D3D12_RESOURCE_STATE_PRESENT);c.SubmitWait([&]{Check(swap->Present(1,0),"G present");});++presents;}
bool Window::Pump(){MSG m;while(PeekMessageW(&m,nullptr,0,0,PM_REMOVE)){TranslateMessage(&m);DispatchMessageW(&m);}return IsWindow(hwnd)!=FALSE;}
void Window::Title(const std::wstring& value){SetWindowTextW(hwnd,value.c_str());}
}
