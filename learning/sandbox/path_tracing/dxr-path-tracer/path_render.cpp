#include "pbr_resources.h"
#include "energy_lut.h"
#include "path_config.h"
#include "../pt08-materials/ggx_math.h"
#include <cstring>
#include <fstream>
#include <iostream>
#include <iomanip>
#include "path_scene.h"
int main(int argc,char** argv){if(argc!=13){std::cerr<<"path_render scene.gltf path.dxil energy-lut.bin out width height spp maxScatters mode seed rr lightScale\n";return 2;}
    HRESULT com=CoInitializeEx(nullptr,COINIT_MULTITHREADED);try{Check(com,"COM");PathConfig cfg;
        cfg.width=std::stoul(argv[5]);cfg.height=std::stoul(argv[6]);cfg.spp=std::stoul(argv[7]);cfg.maxScatters=std::stoul(argv[8]);cfg.mode=std::stoul(argv[9]);cfg.seed=std::stoul(argv[10]);cfg.flags=std::stoul(argv[11]);cfg.lightScale=std::stof(argv[12]);
        Require(cfg.width>0&&cfg.width<=4096&&cfg.height>0&&cfg.height<=4096&&cfg.spp>0&&cfg.spp<=16384&&cfg.maxScatters<=32&&cfg.mode<=2&&cfg.flags<=1&&std::isfinite(cfg.lightScale)&&cfg.lightScale>=0,"render parameter range");
        V eye=Vector(cfg.eye);SetPathCamera(cfg,eye,{0,1.7,0});
        auto cpu=LoadCpuScene(argv[1]);auto triangles=WorldTriangles(cpu);
        auto lights=MakePathLights(cpu,triangles,cfg);double totalArea=cfg.totalArea;
        auto iors=TeachingIors(cpu);
        auto table=pbr_energy::Load(argv[3]);UploadContext context;auto gpu=UploadScene(context,cpu);auto blases=BuildMeshBlases(context,gpu);
        context.SubmitWait();gpu.staging.clear();for(auto& b:blases)b.scratch.Reset();
        auto frame=BuildInstanceFrame(context,cpu,gpu,blases,false);auto bindings=PreparePbrBindings(context,cpu,gpu,&iors);
        bindings.energy=InstanceUpload(context,table.data.data(),table.data.size()*sizeof(float));
        auto configuration=PackPathConfig(cfg,lights);
        // 将高spp拆成最多32spp的短提交，避免一个巨大Dispatch长时间独占交互式Windows GPU。
        // 本节只在CPU合并线性一阶/二阶矩；PT.10再实现持久GPU历史与显示。不能平均tone-mapped颜色。
        const uint32_t totalSpp=cfg.spp,baseSeed=cfg.seed;std::vector<PathPixel> pixels(size_t(cfg.width)*cfg.height);
        for(uint32_t done=0,batch=0;done<totalSpp;++batch){cfg.spp=std::min(32u,totalSpp-done);cfg.seed=baseSeed+batch*6151u;memcpy(configuration.data(),&cfg,sizeof(cfg));
            auto raw=DispatchMaterialBuffer(context,bindings,gpu,frame,configuration.data(),configuration.size(),cfg.width,cfg.height,pixels.size()*sizeof(PathPixel),argv[2]);
            std::vector<PathPixel> block(pixels.size());memcpy(block.data(),raw.data(),raw.size());
            for(size_t i=0;i<pixels.size();++i){auto& target=pixels[i];auto& source=block[i];
                if(done==0)target=source;else{for(unsigned k=0;k<4;++k){target.radiance[k]=float((double(target.radiance[k])*done+double(source.radiance[k])*cfg.spp)/(done+cfg.spp));target.events[k]+=source.events[k];target.errors[k]+=source.errors[k];target.ends[k]+=source.ends[k];}}}
            done+=cfg.spp;std::cout<<"samples="<<done<<'/'<<totalSpp<<'\n'<<std::flush;
        }cfg.spp=totalSpp;cfg.seed=baseSeed;
        V average{};double varianceSum=0,maxValue=0,maxPositionError=0,maxNormalError=0,maxPrimaryRadianceError=0;uint64_t events[4]{},errors[4]{},ends[4]{};
        for(auto& p:pixels){V rgb=Vector(p.radiance);Require(ggx::Finite(rgb)&&rgb.x>=0&&rgb.y>=0&&rgb.z>=0,"invalid HDR output");average=average+rgb;maxValue=std::max({maxValue,rgb.x,rgb.y,rgb.z});
            double y=ggx::Dot(rgb,{.2126,.7152,.0722});varianceSum+=std::max(0.,double(p.radiance[3])-y*y)/std::max(1u,cfg.spp-1);
            for(unsigned k=0;k<4;++k){events[k]+=p.events[k];errors[k]+=p.errors[k];ends[k]+=p.ends[k];}}
        average=average*(1./pixels.size());double meanSE=std::sqrt(varianceSum)/pixels.size();
        // 64条主射线：检查实际实例身份/位置/几何法线。第一样本G-buffer不会被后续路径覆盖。
        unsigned primaryAudits=0;
        for(unsigned a=0;a<64;++a){uint32_t pixel=uint32_t((uint64_t(a)*15485863+137)%pixels.size()),x=pixel%cfg.width,y=pixel/cfg.width;
            double sx=((x+Random(pixel,0,cfg.seed,0,0))/cfg.width*2-1)*(double(cfg.width)/cfg.height)*cfg.tanHalfFovY;
            double sy=(1-(y+Random(pixel,0,cfg.seed,0,1))/cfg.height*2)*cfg.tanHalfFovY;
            V direction=ggx::Normalize(Vector(cfg.forward)+Vector(cfg.right)*sx+Vector(cfg.up)*sy);auto hit=Intersect(triangles,eye,direction);auto& p=pixels[pixel];
            Require((hit.triangle!=nullptr)==(p.position[3]>0),"CPU/GPU primary hit agreement");
            if(hit.triangle){Require(uint32_t(p.position[3])==hit.triangle->instance+1,"CPU/GPU primary instance");
                V position=eye+direction*hit.distance,delta=position-Vector(p.position);double e=std::sqrt(ggx::Dot(delta,delta));maxPositionError=std::max(maxPositionError,e);Require(e<.003,"CPU/GPU primary position");
                V dn=hit.triangle->normal-Vector(p.normal);e=std::sqrt(ggx::Dot(dn,dn));maxNormalError=std::max(maxNormalError,e);Require(e<.003,"CPU/GPU geometric normal");}
            if(cfg.maxScatters==0){V reference{};
                // K=0无需材质积分，可独立逐样本求“主射线看到的发光或环境”，验证发光收取顺序。
                for(uint32_t sample=0;sample<cfg.spp;++sample){uint32_t batchSeed=baseSeed+(sample/32)*6151u,localSample=sample%32;
                    double px=((x+Random(pixel,localSample,batchSeed,0,0))/cfg.width*2-1)*(double(cfg.width)/cfg.height)*cfg.tanHalfFovY;
                    double py=(1-(y+Random(pixel,localSample,batchSeed,0,1))/cfg.height*2)*cfg.tanHalfFovY;
                    V d=ggx::Normalize(Vector(cfg.forward)+Vector(cfg.right)*px+Vector(cfg.up)*py);auto h=Intersect(triangles,eye,d);
                    if(!h.triangle)reference=reference+Vector(cfg.environment)*cfg.environmentIntensity;
                    else if(ggx::Dot(h.triangle->normal,d)<0)reference=reference+Vector(cpu.materialAssets.materials[h.triangle->material].emissive.data())*cfg.lightScale;
                }reference=reference*(1./cfg.spp);V difference=reference-Vector(p.radiance);double e=std::max({std::abs(difference.x),std::abs(difference.y),std::abs(difference.z)});
                maxPrimaryRadianceError=std::max(maxPrimaryRadianceError,e);Require(e<5e-5,"CPU/GPU K0 emission");
            }
            ++primaryAudits;
        }
        Require(errors[0]==0&&errors[1]==0,"medium/sampling or finite-value errors");Require(context.CheckDebug()==0,"D3D debug errors");
        std::filesystem::path out=argv[4];std::filesystem::create_directories(out);
        std::ofstream pfm(out/"radiance.pfm",std::ios::binary);pfm<<"PF\n"<<cfg.width<<' '<<cfg.height<<"\n-1.0\n";
        // PFM负scale标识little-endian，图像按底行到顶行保存；HDR线性值不做曝光/色调映射/截断。
        for(int y=int(cfg.height)-1;y>=0;--y)for(unsigned x=0;x<cfg.width;++x)pfm.write(reinterpret_cast<const char*>(pixels[size_t(y)*cfg.width+x].radiance),12);
        std::ofstream binary(out/"pixels.bin",std::ios::binary);binary.write(reinterpret_cast<const char*>(pixels.data()),pixels.size()*sizeof(PathPixel));
        std::ofstream summary(out/"summary.json");summary<<std::setprecision(12)<<"{\n\"width\":"<<cfg.width<<",\"height\":"<<cfg.height<<",\"spp\":"<<cfg.spp<<",\"max_scatters\":"<<cfg.maxScatters<<",\"mode\":"<<cfg.mode<<",\"seed\":"<<cfg.seed<<",\"rr\":"<<cfg.flags
            <<",\"light_triangles\":"<<lights.size()<<",\"light_area\":"<<totalArea<<",\"triangles\":"<<triangles.size()<<",\"mean_rgb\":["<<average.x<<','<<average.y<<','<<average.z<<"],\"mean_luminance_se\":"<<meanSE<<",\"max_radiance\":"<<maxValue
            <<",\"rays\":"<<events[0]<<",\"shadow_rays\":"<<events[1]<<",\"scatters\":"<<events[2]<<",\"nulls\":"<<events[3]<<",\"invalid\":"<<errors[0]<<",\"nonfinite\":"<<errors[1]<<",\"delta\":"<<errors[2]<<",\"transmissions\":"<<errors[3]
            <<",\"rr_killed\":"<<ends[0]<<",\"depth_caps\":"<<ends[1]<<",\"backfaces\":"<<ends[2]<<",\"emissive_hits\":"<<ends[3]<<",\"primary_audits\":"<<primaryAudits<<",\"max_primary_position_error\":"<<maxPositionError<<",\"max_primary_normal_error\":"<<maxNormalError<<",\"max_K0_radiance_error\":"<<maxPrimaryRadianceError<<"\n}\n";
        Require(pfm&&binary&&summary,"render output write");std::cout<<"PATH PASS rays="<<events[0]<<" mean="<<average.x<<','<<average.y<<','<<average.z<<" SE_Y="<<meanSE<<" delta="<<errors[2]<<" transmission="<<errors[3]<<" invalid="<<errors[0]<<" nonfinite="<<errors[1]<<'\n';
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';if(SUCCEEDED(com))CoUninitialize();return 1;}CoUninitialize();return 0;
}
