#include "input/window_input.h"
#include <windowsx.h>
#include <stdexcept>
namespace character {
static Key Translate(WPARAM key){switch(key){case 'W':return Key::Forward;case 'S':return Key::Backward;case 'A':return Key::Left;case 'D':return Key::Right;
case 'E':return Key::Up;case 'Q':return Key::Down;case VK_SHIFT:return Key::Fast;case VK_SPACE:return Key::Pause;case 'N':return Key::Step;case 'R':return Key::Reset;case VK_ESCAPE:return Key::Escape;default:return Key::Count;}}
WindowInput::WindowInput(HWND w):window_(w){pending_.focused=GetFocus()==w;
    if(!SetWindowSubclass(w,Procedure,1,reinterpret_cast<DWORD_PTR>(this)))throw std::runtime_error("input subclass failed");}
WindowInput::~WindowInput(){Release();RemoveWindowSubclass(window_,Procedure,1);}
void WindowInput::Release(){pending_.held.fill(false);pending_.pressed.fill(false);pending_.mouseX=pending_.mouseY=0;pending_.looking=false;if(GetCapture()==window_)ReleaseCapture();}
InputSnapshot WindowInput::Consume(){auto result=pending_;pending_.pressed.fill(false);pending_.mouseX=pending_.mouseY=0;return result;}
LRESULT CALLBACK WindowInput::Procedure(HWND w,UINT message,WPARAM wp,LPARAM lp,UINT_PTR,DWORD_PTR data){
    auto& self=*reinterpret_cast<WindowInput*>(data);auto& p=self.pending_;
    switch(message){
    case WM_SETFOCUS:p.focused=true;break;
    case WM_KILLFOCUS:p.focused=false;self.Release();break;
    case WM_KEYDOWN:case WM_SYSKEYDOWN:{auto key=Translate(wp);if(key!=Key::Count&&p.focused){unsigned i=unsigned(key);if(!p.held[i])p.pressed[i]=true;p.held[i]=true;}break;}
    case WM_KEYUP:case WM_SYSKEYUP:{auto key=Translate(wp);if(key!=Key::Count)p.held[unsigned(key)]=false;break;}
    case WM_RBUTTONDOWN:if(p.focused){p.looking=true;self.last_={GET_X_LPARAM(lp),GET_Y_LPARAM(lp)};SetCapture(w);}break;
    case WM_RBUTTONUP:p.looking=false;if(GetCapture()==w)ReleaseCapture();break;
    case WM_CAPTURECHANGED:p.looking=false;break;
    case WM_MOUSEMOVE:if(p.focused&&p.looking){POINT now{GET_X_LPARAM(lp),GET_Y_LPARAM(lp)};p.mouseX+=float(now.x-self.last_.x);p.mouseY+=float(now.y-self.last_.y);self.last_=now;}break;
    }
    return DefSubclassProc(w,message,wp,lp);
}
}
