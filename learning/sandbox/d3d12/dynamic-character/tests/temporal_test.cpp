#include "assets/character_import.h"
#include "assets/demo_scene.h"
#include "app/extract_frame.h"
#include "app/locomotion_mapping.h"
#include "render/dxr/renderer.h"
#include "path_scene.h"
#include <objbase.h>
#include <fstream>
#include <iostream>
using namespace character;
static void Need(bool ok,const char* message){if(!ok)throw std::runtime_error(message);}
static void Save(const std::vector<std::array<float,4>>& color,unsigned w,unsigned h,const std::filesystem::path& path){
    std::ofstream f(path,std::ios::binary);f<<"P6\n"<<w<<' '<<h<<"\n255\n";for(const auto& p:color)for(unsigned k=0;k<3;++k){float v=std::max(0.f,p[k]);v=v/(1+v);v=v<=.0031308f?12.92f*v:1.055f*std::pow(v,1/2.4f)-.055f;f.put(char(std::lround(std::clamp(v,0.f,1.f)*255)));}}
static CpuScene Posed(const Rig& rig,const CpuScene& base,const RenderFrame& frame){
    CpuScene scene=base;for(size_t i=0;i<rig.skins.size();++i){const auto& skin=rig.skins[i];scene.meshes[skin.mesh].vertices=SkinCpu(rig.scene.meshes[skin.mesh],skin,frame.palettes[i]);}
    for(size_t i=0;i<frame.rigWorlds.size();++i)scene.nodes[i].world.m=(frame.characterWorld*frame.rigWorlds[i]).values;return scene;
}
int main(int argc,char** argv){auto com=CoInitializeEx(nullptr,COINIT_MULTITHREADED);try{
    Need(SUCCEEDED(com)&&argc==5,"temporal_test assets shaders energy output");std::filesystem::path out=argv[4],assets=argv[1];std::filesystem::create_directories(out);
    auto rig=Load((assets/"animation.glb").string());auto base=BuildDemoScene(rig,assets);DxrRenderer renderer(rig,base,{160,90,true},argv[2],argv[3]);
    CharacterController body;FreeCamera camera;AnimationPlayer player(rig,rig.ClipIndex("Idle_Loop"));RenderImage image,previous;RenderFrame frame,oldFrame;
    std::vector<Triangle> oldTriangles;double positionError=0,projectionError=0;uint64_t accepted=0,rejected=0,geometryChecks=0,temporalChecks=0;
    for(unsigned f=0;f<16;++f){
        for(unsigned step=0;step<4;++step){CharacterIntent intent;intent.x=.3f;intent.run=true;intent.jumpPressed=body.State().tick==20;body.Step(intent);AdvanceLocomotion(player,rig,body.State(),body.Config().step);}
        if(f>=8){CameraIntent move;move.right=.2f;camera.Update(move,1.0/30);}
        frame=ExtractFrame(rig,player.Current(),body.State(),camera);frame.temporal=true;frame.spp=1;
        image=renderer.Render(frame);auto triangles=WorldTriangles(Posed(rig,base,frame));
        PathConfig cfg;cfg.width=image.width;cfg.height=image.height;cfg.tanHalfFovY=frame.tanHalfFov;SetPathCamera(cfg,{frame.eye.x,frame.eye.y,frame.eye.z},{frame.eye.x+frame.forward.x,frame.eye.y+frame.forward.y,frame.eye.z+frame.forward.z});
        // 独立CPU中心射线和double三角形求交，检查实际DXR运动输入；不从GPU位置反推当前命中。
        for(unsigned y=4;y<image.height;y+=9)for(unsigned x=4;x<image.width;x+=10){unsigned index=y*image.width+x;const auto& guide=image.motionGuides[index];
            double sx=((x+.5)/image.width*2-1)*(double(image.width)/image.height)*frame.tanHalfFov,sy=(1-(y+.5)/image.height*2)*frame.tanHalfFov;
            auto origin=::Vector(cfg.eye),direction=ggx::Normalize(::Vector(cfg.forward)+::Vector(cfg.right)*sx+::Vector(cfg.up)*sy);auto hit=Intersect(triangles,origin,direction);
            if(!hit.triangle){Need(guide[3]==0,"GPU hit where CPU misses");continue;}
            auto position=origin+direction*hit.distance;const auto& triangle=*hit.triangle;
            Need(unsigned(guide[3])==triangle.instance+1&&unsigned(guide[7])==triangle.primitive+1,"guide identity mismatch");
            positionError=std::max(positionError,std::sqrt(ggx::Dot(position-::Vector(guide.data()),position-::Vector(guide.data()))));++geometryChecks;
            if(f>0&&guide[11]>0){
                auto found=std::find_if(oldTriangles.begin(),oldTriangles.end(),[&](const Triangle& t){return t.instance==triangle.instance&&t.primitive==triangle.primitive;});Need(found!=oldTriangles.end(),"old triangle missing");
                auto e=triangle.b-triangle.a,g=triangle.c-triangle.a,d=position-triangle.a;double ee=ggx::Dot(e,e),eg=ggx::Dot(e,g),gg=ggx::Dot(g,g),de=ggx::Dot(d,e),dg=ggx::Dot(d,g),denominator=ee*gg-eg*eg;
                double u=(de*gg-dg*eg)/denominator,v=(dg*ee-de*eg)/denominator;auto oldPosition=found->a*(1-u-v)+found->b*u+found->c*v;
                PathConfig old;SetPathCamera(old,{oldFrame.eye.x,oldFrame.eye.y,oldFrame.eye.z},{oldFrame.eye.x+oldFrame.forward.x,oldFrame.eye.y+oldFrame.forward.y,oldFrame.eye.z+oldFrame.forward.z});auto delta=oldPosition-::Vector(old.eye);double depth=ggx::Dot(delta,::Vector(old.forward));
                double px=(ggx::Dot(delta,::Vector(old.right))/(depth*oldFrame.tanHalfFov*(double(image.width)/image.height))*.5+.5)*image.width;
                double py=(.5-ggx::Dot(delta,::Vector(old.up))/(depth*oldFrame.tanHalfFov)*.5)*image.height;
                projectionError=std::max({projectionError,std::abs(px-guide[8]),std::abs(py-guide[9])});
            }
        }
        // 数值不变量：拒绝像素必须与当前raw逐位相同；接受像素历史权重有上限，结果有限。
        for(size_t i=0;i<image.temporalColor.size();++i){const auto& t=image.temporalColor[i];Need(t[3]>=1&&t[3]<=8,"invalid temporal count");
            if(t[3]==1){++rejected;for(unsigned k=0;k<3;++k)Need(t[k]==image.color[i][k],"rejected history changed current result");}else ++accepted;
            for(unsigned k=0;k<3;++k)Need(std::isfinite(t[k])&&t[k]>=0,"invalid temporal color");++temporalChecks;}
        previous=image;oldFrame=frame;oldTriangles=std::move(triangles);
    }
    Need(positionError<1e-3&&projectionError<.01&&accepted>0&&rejected>0,"motion guide reference or reuse failure");
    Save(image.color,image.width,image.height,out/"raw.ppm");Save(image.temporalColor,image.width,image.height,out/"temporal.ppm");auto raw=image.color,filtered=image.temporalColor;
    // 固定最后一帧场景，用独立seed和256spp作为有限噪声参考，不称无噪声真值。
    frame.temporal=false;frame.sceneRevision+=100000;frame.spp=32;frame.resetHistory=true;RenderImage reference;
    for(unsigned batch=0;batch<8;++batch){reference=renderer.Render(frame);frame.resetHistory=false;}
    Save(reference.color,reference.width,reference.height,out/"reference-256spp.ppm");double rawMse=0,filteredMse=0;
    for(size_t i=0;i<raw.size();++i)for(unsigned k=0;k<3;++k){double a=raw[i][k]-reference.color[i][k],b=filtered[i][k]-reference.color[i][k];rawMse+=a*a;filteredMse+=b*b;}
    rawMse/=raw.size()*3;filteredMse/=raw.size()*3;
    frame.temporal=true;frame.spp=1;frame.lightScale=2;auto reset=renderer.Render(frame);
    for(const auto& p:reset.temporalColor)Need(p[3]==1,"light edit retained temporal history");
    frame.resetHistory=true;reset=renderer.Render(frame);for(const auto& p:reset.temporalColor)Need(p[3]==1,"camera cut retained temporal history");
    Need(renderer.DebugErrors()==0,"temporal debug errors");
    std::ofstream(out/"summary.json")<<"{\"pass\":true,\"geometry_checks\":"<<geometryChecks<<",\"temporal_pixel_checks\":"<<temporalChecks<<",\"position_error\":"<<positionError<<",\"projection_pixel_error\":"<<projectionError<<",\"accepted\":"<<accepted<<",\"rejected\":"<<rejected<<",\"raw_mse\":"<<rawMse<<",\"temporal_mse\":"<<filteredMse<<"}\n";
    std::cout<<"PASS H6 geometry="<<geometryChecks<<" position="<<positionError<<" projection="<<projectionError<<" accepted="<<accepted<<" rawMSE="<<rawMse<<" temporalMSE="<<filteredMse<<'\n';
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';if(SUCCEEDED(com))CoUninitialize();return 1;}CoUninitialize();}
