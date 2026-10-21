#include "assets/character_import.h"
#include "assets/demo_scene.h"
#include "app/extract_frame.h"
#include "app/locomotion_mapping.h"
#include "app/startup.h"
#include "app/demo_behavior.h"
#include "input/window_input.h"
#include "render/dxr/renderer.h"
#include <objbase.h>
#include <chrono>
#include <iostream>
#include <fstream>
using namespace character;
int main(int argc,char** argv){
    // 在创建窗口前声明像素感知，避免Windows高DPI位图缩放再次模糊已渲染的图像。
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    HRESULT com=CoInitializeEx(nullptr,COINIT_MULTITHREADED);try{
    if(FAILED(com))throw std::runtime_error("COM initialization failed");
    const auto startup=LoadStartupOptions(argc,argv);
    const auto& assets=startup.assets;const auto& output=startup.output;std::filesystem::create_directories(output);
    unsigned verifyFrames=startup.verificationFrames;
    auto rig=Load((assets/"animation.glb").string());auto scene=BuildDemoScene(rig,assets,startup.presentation);
    DxrRenderer renderer(rig,std::move(scene),{startup.width,startup.height,verifyFrames!=0,true,false},startup.shaders,startup.energy);
    // 声明顺序确保input先解除窗口子类化，再由renderer销毁交换链和窗口。
    WindowInput input(static_cast<HWND>(renderer.NativeWindow()));FreeCamera camera;CharacterController controller;FixedClock clock;
    if(startup.presentation)camera.ResetPresentation();
    AnimationPlayer animation(rig,rig.ClipIndex("Idle_Loop"));bool paused=false;unsigned rendered=0;
    std::ofstream csv(output/"frames.csv");csv<<"frame,tick,state,x,y,paused,samples,milliseconds\n";
    if(!csv)throw std::runtime_error("Cannot write frame log: "+(output/"frames.csv").u8string());
    auto previous=std::chrono::steady_clock::now();
    while(renderer.PumpWindow()){
        if(verifyFrames){
            HWND window=static_cast<HWND>(renderer.NativeWindow());
            auto press=[&](WPARAM key){SendMessageW(window,WM_SETFOCUS,0,0);SendMessageW(window,WM_KEYDOWN,key,0);SendMessageW(window,WM_KEYUP,key,0);};
            if(rendered==3||rendered==9)press(VK_SPACE);
            if(rendered==6)press('N');if(rendered==22)press('R');
            if(rendered==12){if(!SetWindowPos(window,nullptr,0,0,641,359,SWP_NOMOVE|SWP_NOZORDER|SWP_NOACTIVATE))throw std::runtime_error("window resize test failed");renderer.PumpWindow();}
            if(rendered==15){auto before=renderer.Stats().frameNumber;ShowWindow(window,SW_MINIMIZE);renderer.PumpWindow();if(!renderer.Suspended())throw std::runtime_error("minimize not observed");
                if(renderer.Stats().frameNumber!=before)throw std::runtime_error("minimized frame submitted");ShowWindow(window,SW_RESTORE);renderer.PumpWindow();if(renderer.Suspended())throw std::runtime_error("restore failed");}
            if(rendered==18){SendMessageW(window,WM_SETFOCUS,0,0);SendMessageW(window,WM_KEYDOWN,'W',0);}
            if(rendered==20)SendMessageW(window,WM_KILLFOCUS,0,0);
        }
        auto now=std::chrono::steady_clock::now();double elapsed=std::chrono::duration<double>(now-previous).count();previous=now;
        auto actions=MapActions(input.Consume());if(actions.app.exit)break;
        if(actions.app.togglePause)paused=!paused;
        if(renderer.Suspended()){MsgWaitForMultipleObjectsEx(0,nullptr,16,QS_ALLINPUT,MWMO_INPUTAVAILABLE);continue;}
        renderer.ApplyWindowResize();elapsed=verifyFrames?1.0/30:std::min(elapsed,.25);
        camera.Update(actions.camera,elapsed);
        auto step=[&](uint64_t){controller.Step(startup.presentation?PresentationIntent(controller.State(),controller.Config().step):DemoIntent(controller.State(),controller.Config().step));AdvanceLocomotion(animation,rig,controller.State(),controller.Config().step);};
        if(!paused)clock.Advance(elapsed,step);else if(actions.app.singleStep)step(controller.State().tick);
        auto frame=ExtractFrame(rig,animation.Current(),controller.State(),camera);frame.spp=paused?startup.pausedSpp:startup.movingSpp;frame.maxScatters=startup.maxScatters;frame.temporal=!paused;frame.resetHistory=actions.camera.reset;
        frame.skyEnabled=startup.presentation;frame.smoothNormals=startup.presentation;frame.skyIntensity=startup.skyIntensity;
        renderer.Render(frame);const auto& state=controller.State();const auto& stats=renderer.Stats();
        csv<<rendered<<','<<state.tick<<','<<MotionName(state.motion)<<','<<state.position.x<<','<<state.position.y<<','<<paused<<','<<stats.accumulatedSamples<<','<<stats.frameMilliseconds<<'\n';
        if(verifyFrames&&++rendered>=verifyFrames)break;if(!verifyFrames)++rendered;
    }
    if(renderer.DebugErrors())throw std::runtime_error("renderer validation error");
    std::cout<<"Demo closed normally; frames="<<rendered<<'\n';
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';ReportStartupError(e.what(),argc==1);if(SUCCEEDED(com))CoUninitialize();return 1;}CoUninitialize();}
