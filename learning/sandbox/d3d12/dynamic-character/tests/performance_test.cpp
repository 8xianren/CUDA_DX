#include "assets/character_import.h"
#include "assets/demo_scene.h"
#include "app/extract_frame.h"
#include "app/locomotion_mapping.h"
#include "app/demo_behavior.h"
#include "render/dxr/renderer.h"
#include <objbase.h>
#include <fstream>
#include <iostream>
#include <chrono>
using namespace character;
int main(int argc,char** argv){auto com=CoInitializeEx(nullptr,COINIT_MULTITHREADED);try{
    if(FAILED(com)||(argc!=5&&argc!=6))throw std::runtime_error("performance_test assets shaders energy output [presentation]");
    const bool presentation=argc==6&&std::string(argv[5])=="presentation";
    std::filesystem::path assets=argv[1],out=argv[4];std::filesystem::create_directories(out);auto rig=Load((assets/"animation.glb").string());auto scene=BuildDemoScene(rig,assets,presentation);
    std::ofstream csv(out/"performance.csv");csv<<"mode,width,height,spp,bounces,iteration,whole_frame_ms,renderer_wall_ms,cuda_palette_skin_ms,as_ms,path_accumulate_ms,motion_temporal_ms,display_ms,local_memory_bytes\n";
    for(unsigned width:(presentation?std::vector<unsigned>{1280,1920}:std::vector<unsigned>{320,640}))for(bool moving:{true,false}){
        DxrRenderer renderer(rig,scene,{width,width*9/16,false,false,false},argv[2],argv[3]);CharacterController body;FreeCamera camera;AnimationPlayer player(rig,rig.ClipIndex("Idle_Loop"));
        if(presentation)camera.ResetPresentation();
        auto advance=[&]{body.Step(presentation?PresentationIntent(body.State(),body.Config().step):DemoIntent(body.State(),body.Config().step));AdvanceLocomotion(player,rig,body.State(),body.Config().step);};
        // 所有配置从同一人物姿势附近开始；固定仿真序列、3次预热+12次测量，无验证层/窗口/Present。
        for(unsigned tick=0;tick<300;++tick)advance();
        for(unsigned iteration=0;iteration<15;++iteration){auto start=std::chrono::steady_clock::now();
            if(moving)for(unsigned step=0;step<4;++step)advance();
            auto frame=ExtractFrame(rig,player.Current(),body.State(),camera);frame.temporal=moving;frame.spp=presentation?(moving?4:16):(moving?1:8);frame.maxScatters=presentation?6:(moving?4:8);
            frame.skyEnabled=frame.smoothNormals=presentation;renderer.Render(frame);
            double whole=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();const auto& s=renderer.Stats();
            if(iteration>=3)csv<<(moving?"interactive":"stationary")<<','<<width<<','<<width*9/16<<','<<frame.spp<<','<<frame.maxScatters<<','<<iteration-3<<','<<whole<<','<<s.frameMilliseconds<<','<<s.cudaMilliseconds<<','<<s.asMilliseconds<<','<<s.pathMilliseconds<<','<<s.temporalMilliseconds<<','<<s.displayMilliseconds<<','<<s.localMemoryBytes<<'\n';
        }
    }
    std::cout<<"PASS measured four configurations, 12 samples each; validation disabled, no Present\n";
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';if(SUCCEEDED(com))CoUninitialize();return 1;}CoUninitialize();}
