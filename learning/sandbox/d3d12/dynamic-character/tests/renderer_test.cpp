#include "assets/character_import.h"
#include "assets/demo_scene.h"
#include "app/extract_frame.h"
#include "app/locomotion_mapping.h"
#include "render/dxr/renderer.h"
#include <windows.h>
#include <objbase.h>
#include <fstream>
#include <iostream>
#include <algorithm>
using namespace character;
static void Need(bool ok,const char* text){if(!ok)throw std::runtime_error(text);}
static void Save(const RenderImage& image,const std::filesystem::path& file){
    std::ofstream f(file,std::ios::binary);f<<"P6\n"<<image.width<<' '<<image.height<<"\n255\n";
    for(const auto& pixel:image.color)for(unsigned k=0;k<3;++k){float v=std::max(0.f,pixel[k]);v=v/(1+v);v=v<=.0031308f?12.92f*v:1.055f*std::pow(v,1/2.4f)-.055f;f.put(char(std::lround(std::clamp(v,0.f,1.f)*255)));}
}
int main(int argc,char** argv){HRESULT com=CoInitializeEx(nullptr,COINIT_MULTITHREADED);try{
    Need(SUCCEEDED(com),"COM initialization");Need(argc==5,"renderer_test assets shader-directory energy.bin output");
    std::filesystem::path assets=argv[1],out=argv[4];std::filesystem::create_directories(out);
    auto rig=Load((assets/"animation.glb").string());auto scene=BuildDemoScene(rig,assets);
    DxrRenderer renderer(rig,scene,{160,90,true},argv[2],argv[3]);FreeCamera camera;CharacterController controller;AnimationPlayer player(rig,rig.ClipIndex("Idle_Loop"));
    double maxDifference=0;unsigned frameCount=0;float brightest=0;
    for(unsigned tick:{0u,60u,130u}){
        while(controller.State().tick<tick){CharacterIntent intent;intent.x=.3f;intent.run=true;intent.jumpPressed=controller.State().tick==40;
            controller.Step(intent);AdvanceLocomotion(player,rig,controller.State(),controller.Config().step);}
        auto frame=ExtractFrame(rig,player.Current(),controller.State(),camera);frame.spp=4;frame.resetHistory=true;
        auto update=renderer.Render(frame,false);auto rebuild=renderer.Render(frame,true);frameCount+=2;
        Need(update.color.size()==rebuild.color.size(),"image dimensions");
        for(size_t i=0;i<update.color.size();++i)for(unsigned k=0;k<3;++k){Need(std::isfinite(update.color[i][k])&&update.color[i][k]>=0,"invalid pixel");
            maxDifference=std::max(maxDifference,double(std::abs(update.color[i][k]-rebuild.color[i][k])));brightest=std::max(brightest,update.color[i][k]);}
        Save(update,out/("pose-"+std::to_string(tick)+".ppm"));
    }
    Need(maxDifference<1e-4&&brightest>0,"BLAS update/rebuild or lighting");
    auto frame=ExtractFrame(rig,player.Current(),controller.State(),camera);frame.spp=2;frame.resetHistory=true;
    frame.lightScale=1;auto one=renderer.Render(frame);frame.lightScale=2;auto two=renderer.Render(frame);frame.lightScale=0;auto black=renderer.Render(frame);frameCount+=3;
    double linearError=0,blackMax=0;
    for(size_t i=0;i<one.color.size();++i)for(unsigned k=0;k<3;++k){linearError=std::max(linearError,double(std::abs(two.color[i][k]-2*one.color[i][k])));blackMax=std::max(blackMax,double(black.color[i][k]));}
    Need(linearError<1e-4&&blackMax==0,"light linearity/black environment");
    frame.lightScale=1;frame.resetHistory=false;auto fresh=renderer.Render(frame);auto accumulated=renderer.Render(frame);frameCount+=2;
    Need(accumulated.samples==fresh.samples+frame.spp&&accumulated.generation==fresh.generation,"static accumulation");
    frame.exposure=2;auto exposure=renderer.Render(frame);++frameCount;Need(exposure.generation==accumulated.generation,"exposure reset history");
    unsigned errors=renderer.DebugErrors();Need(errors==0,"debug layer errors");
    std::ofstream(out/"summary.json")<<"{\"pass\":true,\"frames\":"<<frameCount<<",\"update_rebuild_max_error\":"<<maxDifference<<",\"light_linearity_error\":"<<linearError<<",\"all_lights_off_max\":"<<blackMax<<",\"debug_errors\":"<<errors<<"}\n";
    std::cout<<"PASS renderer frames="<<frameCount<<" update/rebuild="<<maxDifference<<" light linearity="<<linearError<<" black="<<blackMax<<'\n';
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';if(SUCCEEDED(com))CoUninitialize();return 1;}CoUninitialize();}
