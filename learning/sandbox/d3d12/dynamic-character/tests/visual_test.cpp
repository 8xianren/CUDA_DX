#include "assets/character_import.h"
#include "assets/demo_scene.h"
#include "app/extract_frame.h"
#include "app/locomotion_mapping.h"
#include "app/demo_behavior.h"
#include "render/dxr/renderer.h"
#include <objbase.h>
#include <fstream>
#include <iostream>
using namespace character;
static void Need(bool condition,const char* message){if(!condition)throw std::runtime_error(message);}
static void Save(const RenderImage& image,const std::filesystem::path& path,bool filtered=false){
    const auto& pixels=filtered?image.temporalColor:image.color;Need(!pixels.empty(),"empty visual capture");
    std::ofstream stream(path,std::ios::binary);stream<<"P6\n"<<image.width<<' '<<image.height<<"\n255\n";
    // 与窗口相同的曝光0、Reinhard和sRGB编码；保存真实渲染尺寸，不用缩略图冒充720p。
    for(const auto& pixel:pixels)for(unsigned c=0;c<3;++c){float value=std::max(0.f,pixel[c]);value/=1+value;
        value=value<=.0031308f?12.92f*value:1.055f*std::pow(value,1/2.4f)-.055f;stream.put(char(std::lround(std::clamp(value,0.f,1.f)*255)));}
    Need(bool(stream),"capture write failed");
}
int main(int argc,char** argv){auto com=CoInitializeEx(nullptr,COINIT_MULTITHREADED);try{
    Need(SUCCEEDED(com)&&argc==5,"visual_test assets shaders energy output");
    std::filesystem::path assets=argv[1],out=argv[4];std::filesystem::create_directories(out);
    auto rig=Load((assets/"animation.glb").string());
    // 独立保留旧默认画面作为对照，不改已有H1-H7的证据目录。
    {DxrRenderer renderer(rig,BuildDemoScene(rig,assets),{320,180,true,false,true},argv[2],argv[3]);
        CharacterController body;FreeCamera camera;AnimationPlayer player(rig,rig.ClipIndex("Idle_Loop"));
        auto frame=ExtractFrame(rig,player.Current(),body.State(),camera);frame.spp=1;frame.temporal=true;
        RenderImage image;for(unsigned i=0;i<8;++i){frame.sceneRevision=i;image=renderer.Render(frame);}
        Save(image,out/"before-320x180.ppm",true);Need(renderer.DebugErrors()==0,"baseline debug error");}
    auto scene=BuildDemoScene(rig,assets,true);CharacterController body;FreeCamera camera;camera.ResetPresentation();AnimationPlayer player(rig,rig.ClipIndex("Idle_Loop"));
    double linearError=0,black=0,smoothDifference=0;
    {DxrRenderer renderer(rig,scene,{160,90,true,false,true},argv[2],argv[3]);
        auto frame=ExtractFrame(rig,player.Current(),body.State(),camera);frame.spp=8;frame.resetHistory=true;frame.skyEnabled=true;frame.smoothNormals=true;
        auto one=renderer.Render(frame);frame.skyIntensity=2;auto two=renderer.Render(frame);frame.skyIntensity=0;auto zero=renderer.Render(frame);
        frame.skyIntensity=1;frame.smoothNormals=false;auto flat=renderer.Render(frame);
        for(size_t i=0;i<one.color.size();++i)for(unsigned c=0;c<3;++c){linearError=std::max(linearError,double(std::abs(two.color[i][c]-2*one.color[i][c])));black=std::max(black,double(zero.color[i][c]));smoothDifference+=std::abs(one.color[i][c]-flat.color[i][c]);}
        Need(linearError<1e-4&&black==0&&smoothDifference>0,"sky linearity/black/smooth normal checks");
        frame.smoothNormals=true;frame.temporal=true;frame.resetHistory=false;renderer.Render(frame);renderer.Render(frame);frame.skyIntensity=.5f;auto changed=renderer.Render(frame);
        for(const auto& pixel:changed.temporalColor)Need(pixel[3]==1,"sky edit kept stale temporal history");
        Need(renderer.DebugErrors()==0,"sky debug errors");}
    DxrRenderer renderer(rig,scene,{1280,720,true,false,true},argv[2],argv[3]);
    RenderImage image;RenderFrame frame;
    auto advance=[&]{body.Step(PresentationIntent(body.State(),body.Config().step));AdvanceLocomotion(player,rig,body.State(),body.Config().step);};
    // 清楚区分静态展示封面与运动验收：封面在Idle0.4秒，运动段预推进至3.8秒，
    // 穿过4秒的起跳时刻。不能把前1秒Idle误标为角色行走/跑步的动态画质证明。
    for(unsigned step=0;step<48;++step)advance();
    frame=ExtractFrame(rig,player.Current(),body.State(),camera);frame.spp=32;frame.maxScatters=6;frame.skyEnabled=frame.smoothNormals=true;frame.resetHistory=true;
    for(unsigned batch=0;batch<8;++batch){image=renderer.Render(frame);frame.resetHistory=false;}
    Save(image,out/"cover-720p-256spp.ppm");
    while(body.State().tick<456)advance();
    Vec3 initialPosition=body.State().position;bool sawRun=false,sawJump=false;
    // 真正连续跑步/起跳12帧，4spp；结果与同一最终姿势/相机的256spp参考比较。
    for(unsigned i=0;i<12;++i){for(unsigned step=0;step<4;++step){body.Step(PresentationIntent(body.State(),body.Config().step));AdvanceLocomotion(player,rig,body.State(),body.Config().step);}
        sawRun|=body.State().motion==Motion::Run;sawJump|=body.State().motion==Motion::Jump;
        frame=ExtractFrame(rig,player.Current(),body.State(),camera);frame.spp=4;frame.maxScatters=6;frame.skyEnabled=true;frame.smoothNormals=true;frame.temporal=true;image=renderer.Render(frame);}
    double displacement=std::sqrt((body.State().position-initialPosition).SquareLength());Need(sawRun&&sawJump&&displacement>.5,"motion capture did not exercise running and jumping");
    Save(image,out/"after-720p-4spp-raw.ppm");Save(image,out/"after-720p-temporal.ppm",true);
    auto raw=image.color,filtered=image.temporalColor;frame.temporal=false;frame.spp=32;frame.resetHistory=true;frame.sceneRevision+=10000;
    for(unsigned batch=0;batch<8;++batch){image=renderer.Render(frame);frame.resetHistory=false;}
    Save(image,out/"after-720p-256spp.ppm");double rawMse=0,filteredMse=0;
    for(size_t i=0;i<raw.size();++i)for(unsigned c=0;c<3;++c){double a=raw[i][c]-image.color[i][c],b=filtered[i][c]-image.color[i][c];rawMse+=a*a;filteredMse+=b*b;}
    rawMse/=raw.size()*3;filteredMse/=raw.size()*3;Need(image.samples==256,"reference sample count");Need(renderer.DebugErrors()==0,"720p debug errors");
    std::ofstream(out/"summary.json")<<"{\"pass\":true,\"width\":1280,\"height\":720,\"reference_spp\":256,\"moving_spp\":4,\"moving_frames\":12,\"run_and_jump\":true,\"motion_start_tick\":456,\"motion_end_tick\":"<<body.State().tick<<",\"displacement\":"<<displacement<<",\"sky_linearity_error\":"<<linearError<<",\"all_lights_off\":"<<black<<",\"smooth_difference_sum\":"<<smoothDifference<<",\"raw_mse\":"<<rawMse<<",\"temporal_mse\":"<<filteredMse<<",\"debug_errors\":0}\n";
    std::cout<<"PASS visual 720p, sky linearity="<<linearError<<" rawMSE="<<rawMse<<" temporalMSE="<<filteredMse<<'\n';
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';if(SUCCEEDED(com))CoUninitialize();return 1;}CoUninitialize();}
