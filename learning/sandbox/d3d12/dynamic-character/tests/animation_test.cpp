#include "animation/animation.h"
#include "assets/character_import.h"
#include "render/cuda/skin_gpu.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <cstring>
#include <cmath>
#include <algorithm>
#include <iomanip>
using namespace character;
static void Need(bool ok,const char* text){if(!ok)throw std::runtime_error(text);}
static float Error(const std::vector<Vertex>& a,const std::vector<Vertex>& b){
    Need(a.size()==b.size(),"vertex sizes");float error=0;
    for(size_t i=0;i<a.size();++i){for(unsigned k=0;k<3;++k){Need(std::isfinite(b[i].position[k])&&std::isfinite(b[i].normal[k]),"nonfinite skin");
        error=std::max(error,std::abs(a[i].position[k]-b[i].position[k]));error=std::max(error,std::abs(a[i].normal[k]-b[i].normal[k]));}
        Need(!memcmp(a[i].uv,b[i].uv,sizeof(a[i].uv))&&!memcmp(a[i].color,b[i].color,sizeof(a[i].color)),"UV/color changed");}
    return error;
}
int main(int argc,char** argv){
    cudaStream_t stream=nullptr;
    try{
        Need(argc==3,"animation_test animation.glb output");auto rig=Load(argv[1]);std::filesystem::create_directories(argv[2]);
        std::ofstream csv(std::filesystem::path(argv[2])/"skin.csv");csv<<"clip,time,mesh,vertices,max_error\n";
        CheckCuda(cudaStreamCreateWithFlags(&stream,cudaStreamNonBlocking),"create skin stream");
        float worst=0,bindError=0,loopError=0,blendError=0;unsigned checks=0;
        for(const auto& skin:rig.skins){
            const auto& mesh=rig.scene.meshes[skin.mesh];std::vector<GpuInfluence> influences(skin.influence.size());
            std::ofstream bindDump(std::filesystem::path(argv[2])/("bind-mesh-"+std::to_string(skin.mesh)+".csv"));bindDump<<std::setprecision(10);
            for(size_t vi=0;vi<mesh.vertices.size();++vi){const auto& v=mesh.vertices[vi];bindDump<<v.position[0]<<','<<v.position[1]<<','<<v.position[2];
                for(unsigned k=0;k<4;++k)bindDump<<','<<rig.scene.nodes[skin.joints[skin.influence[vi].joint[k]].node].name<<','<<skin.influence[vi].weight[k];bindDump<<'\n';}
            for(size_t i=0;i<influences.size();++i){std::copy_n(skin.influence[i].joint,4,influences[i].joint);std::copy_n(skin.influence[i].weight,4,influences[i].weight);}
            SkinDevice device(mesh.vertices.data(),influences.data(),unsigned(influences.size()),unsigned(skin.joints.size()));
            auto apply=[&](const std::vector<Pose>& poses){return SkinCpu(mesh,skin,Palette(skin,Worlds(rig,poses)));};
            bindError=std::max(bindError,Error(mesh.vertices,apply(rig.defaults)));
            for(const char* name:{"Idle_Loop","Walk_Loop","Sprint_Loop","Jump_Start","Jump_Loop","Jump_Land"}){
                auto clip=rig.ClipIndex(name);double duration=rig.clips[clip].duration;
                loopError=std::max(loopError,Error(apply(Sample(rig,clip,0)),apply(Sample(rig,clip,duration))));
                for(double fraction:{0.0,0.13,0.5,0.91,1.0}){
                    auto pose=Sample(rig,clip,duration*fraction,false);auto palette=Palette(skin,Worlds(rig,pose));
                    std::vector<SkinMatrix> gpuMatrices(palette.size());
                    for(size_t j=0;j<palette.size();++j){auto normal=Inverse(palette[j]);
                        for(unsigned r=0;r<4;++r)for(unsigned c=0;c<4;++c)gpuMatrices[j].position[r*4+c]=palette[j][r][c];
                        for(unsigned r=0;r<3;++r)for(unsigned c=0;c<3;++c)gpuMatrices[j].normal[r*4+c]=normal[c][r];}
                    device.Record(gpuMatrices.data(),stream);std::vector<Vertex> actual(mesh.vertices.size());
                    CheckCuda(cudaMemcpyAsync(actual.data(),device.output,actual.size()*sizeof(Vertex),cudaMemcpyDeviceToHost,stream),"read skin output");
                    CheckCuda(cudaStreamSynchronize(stream),"finish skin frame");
                    const float error=Error(SkinCpu(mesh,skin,palette),actual);worst=std::max(worst,error);++checks;
                    if(std::string(name)=="Walk_Loop"&&fraction==0.5){
                        auto world=Worlds(rig,pose);std::ofstream transforms(std::filesystem::path(argv[2])/"walk-world.csv");
                        transforms<<std::setprecision(10);
                        for(size_t ni=0;ni<world.size();++ni){transforms<<rig.scene.nodes[ni].name;for(unsigned r=0;r<4;++r)for(unsigned c=0;c<4;++c)transforms<<','<<world[ni][r][c];transforms<<'\n';}
                        std::ofstream raw(std::filesystem::path(argv[2])/("walk-mid-mesh-"+std::to_string(skin.mesh)+".csv"));
                        raw<<std::setprecision(10)<<"x,y,z,nx,ny,nz\n";
                        for(const auto& v:actual)raw<<v.position[0]<<','<<v.position[1]<<','<<v.position[2]<<','<<v.normal[0]<<','<<v.normal[1]<<','<<v.normal[2]<<'\n';
                    }
                    csv<<name<<','<<duration*fraction<<','<<skin.mesh<<','<<actual.size()<<','<<error<<'\n';
                }
            }
            auto a=Sample(rig,rig.ClipIndex("Walk_Loop"),.2),b=Sample(rig,rig.ClipIndex("Sprint_Loop"),.3);
            blendError=std::max({blendError,Error(apply(a),apply(Blend(a,b,0))),Error(apply(b),apply(Blend(a,b,1)))});
            auto mid=apply(Blend(a,b,.5f));Need(Error(apply(a),mid)>.001f,"blend midpoint must change pose");
        }
        bool invalidTime=false,invalidClip=false;
        try{Sample(rig,UINT32_MAX,0);}catch(...){invalidClip=true;}
        try{Sample(rig,0,NAN);}catch(...){invalidTime=true;}
        Need(invalidClip&&invalidTime,"bad sample input accepted");
        Need(worst<2e-5f&&bindError<2e-5f&&loopError<2e-5f&&blendError<2e-5f,"animation tolerance");
        std::ofstream report(std::filesystem::path(argv[2])/"summary.json");
        report<<"{\"pass\":true,\"gpu_checks\":"<<checks<<",\"gpu_max_error\":"<<worst<<",\"bind_error\":"<<bindError<<",\"loop_error\":"<<loopError<<",\"blend_endpoint_error\":"<<blendError<<"}\n";
        CheckCuda(cudaStreamDestroy(stream),"destroy skin stream");stream=nullptr;
        std::cout<<"PASS animation CUDA checks="<<checks<<" worst="<<worst<<" bind="<<bindError<<" loop="<<loopError<<" blend="<<blendError<<'\n';
    }catch(const std::exception& e){if(stream){cudaStreamSynchronize(stream);cudaStreamDestroy(stream);}std::cerr<<e.what()<<'\n';return 1;}
}
