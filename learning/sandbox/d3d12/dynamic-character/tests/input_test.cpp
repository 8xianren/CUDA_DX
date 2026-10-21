#include "input/window_input.h"
#include "simulation/free_camera.h"
#include "simulation/character_controller.h"
#include <filesystem>
#include <fstream>
#include <iostream>
using namespace character;
static void Need(bool ok,const char* text){if(!ok)throw std::runtime_error(text);}
int main(int argc,char** argv){try{
    Need(argc==2,"input_test output");std::filesystem::create_directories(argv[1]);
    // 创建隐藏真实Win32窗口，验证适配器消息路径；不发送全局键盘输入。
    HWND window=CreateWindowExW(0,L"STATIC",L"H4 input test",WS_OVERLAPPEDWINDOW,0,0,320,200,nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
    Need(window!=nullptr,"input test window");
    {WindowInput input(window);SendMessageW(window,WM_SETFOCUS,0,0);SendMessageW(window,WM_KEYDOWN,'W',0);
        auto first=input.Consume();Need(first.held[unsigned(Key::Forward)]&&first.pressed[unsigned(Key::Forward)],"key edge missing");
        SendMessageW(window,WM_KEYDOWN,'W',LPARAM(1)<<30);auto repeated=input.Consume();Need(repeated.held[unsigned(Key::Forward)]&&!repeated.pressed[unsigned(Key::Forward)],"repeat generated new edge");
        SendMessageW(window,WM_KILLFOCUS,0,0);auto lost=input.Consume();Need(!lost.focused&&!lost.held[unsigned(Key::Forward)],"focus left sticky key");
        SendMessageW(window,WM_SETFOCUS,0,0);SendMessageW(window,WM_RBUTTONDOWN,0,MAKELPARAM(20,30));SendMessageW(window,WM_MOUSEMOVE,0,MAKELPARAM(30,45));
        auto mouse=input.Consume();Need(mouse.looking&&mouse.mouseX==10&&mouse.mouseY==15,"mouse delta");
        SendMessageW(window,WM_RBUTTONUP,0,0);Need(!input.Consume().looking&&GetCapture()!=window,"capture release");}
    DestroyWindow(window);
    Vec3 baseline;float worst=0;
    for(unsigned fps:{30u,60u,144u}){FreeCamera camera;CameraIntent intent;intent.forward=1;
        for(unsigned i=0;i<fps*2;++i)camera.Update(intent,1.0/fps);
        if(fps==30)baseline=camera.Eye();else worst=std::max(worst,std::sqrt((camera.Eye()-baseline).SquareLength()));
        intent={};intent.lookY=100000;camera.Update(intent,0);Need(std::abs(camera.Forward().y)<1,"pitch limit");
        intent={};intent.reset=true;camera.Update(intent,0);Need((camera.Eye()-Vec3{6,5,9}).SquareLength()==0,"camera reset");}
    Need(worst<1e-4f,"camera dt scaling");
    InputSnapshot focused;focused.held[unsigned(Key::Forward)]=true;auto actions=MapActions(focused);Need(actions.camera.forward==1,"camera mapping");
    focused.focused=false;Need(MapActions(focused).camera.forward==0,"unfocused action");
    std::ofstream(std::filesystem::path(argv[1])/"summary.json")<<"{\"pass\":true,\"real_window_message_path\":true,\"camera_cadence_error\":"<<worst<<"}\n";
    std::cout<<"PASS input focus/edge/mouse, camera cadence error="<<worst<<'\n';
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
