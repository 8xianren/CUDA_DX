#include "gpu_path_reference.h"
#include <fstream>
#include <iostream>
#include <iomanip>
#include <cstring>
using path_reference::Check;
int main(int argc,char** argv){
    if(argc!=4){std::cerr<<"gpu_path_test box.gltf shader.dxil output-dir\n";return 2;}
    HRESULT com=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    try{
        ::Check(com,"COM");PathConfig cfg;auto cpu=LoadCpuScene(argv[1]);bool found=false;
        for(auto& m:cpu.materialAssets.materials)if(m.name=="Cavity"){found=true;for(int c=0;c<3;++c){cfg.rho[c]=m.baseColor[c];cfg.emission[c]=m.emissive[c];}}
        Check(found&&cpu.meshes.size()==6&&cpu.instances.size()==6,"unexpected box fixture");
        std::filesystem::path dir=argv[3];std::filesystem::create_directories(dir);
        std::ofstream metrics(dir/"seed_metrics.csv"),trace(dir/"path0.csv"),depths(dir/"depths.csv");
        Check(bool(metrics)&&bool(trace)&&bool(depths),"output files");
        metrics<<"mode,seed,r,g,b\n"<<std::setprecision(12);
        trace<<"mode,depth,x,y,z,beta_r,emission_weight,previous_pdf,nee_r,nee_weight,total_r,rays\n"<<std::setprecision(12);
        depths<<"mode,depth,paths,mean_beta_r,mean_beta_g,mean_beta_b\n"<<std::setprecision(12);
        UploadContext c;auto gpu=UploadScene(c,cpu);auto blases=BuildMeshBlases(c,gpu);c.SubmitWait();
        gpu.staging.clear();for(auto& b:blases)b.scratch.Reset();auto frame=BuildInstanceFrame(c,cpu,gpu,blases,false);
        const char* names[]{"bsdf","mis","wrong_add"};constexpr int seeds=8;path_reference::Audit audit;
        throughput::RGB rho{cfg.rho[0],cfg.rho[1],cfg.rho[2]},le{cfg.emission[0],cfg.emission[1],cfg.emission[2]};
        auto exact=throughput::Analytic(rho,le,cfg.maxScatters);double misMean=0,wrongMean=0;
        for(uint32_t mode=0;mode<3;++mode){cfg.mode=mode;double mean[3]{},m2[3]{};std::vector<throughput::RGB> betaSums(cfg.maxScatters+1);
            for(uint32_t seed=0;seed<seeds;++seed){cfg.seed=seed;auto result=Run(c,frame,cfg,argv[2]);path_reference::Validate(cfg,result,audit);
                double sum[3]{};for(uint32_t p=0;p<cfg.paths;++p){for(int channel=0;channel<3;++channel)sum[channel]+=result[size_t(p)*(cfg.maxScatters+1)+cfg.maxScatters].radiance[channel];
                    for(uint32_t d=0;d<=cfg.maxScatters;++d)for(int channel=0;channel<3;++channel)betaSums[d][channel]+=result[size_t(p)*(cfg.maxScatters+1)+d].beta[channel];}
                metrics<<names[mode]<<','<<seed;for(int channel=0;channel<3;++channel){double v=sum[channel]/cfg.paths;metrics<<','<<v;double delta=v-mean[channel];mean[channel]+=delta/(seed+1);m2[channel]+=delta*(v-mean[channel]);}metrics<<'\n';
                if(seed==0)for(uint32_t d=0;d<=cfg.maxScatters;++d){auto& r=result[d];trace<<names[mode]<<','<<d<<','<<r.position[0]<<','<<r.position[1]<<','<<r.position[2]<<','<<r.beta[0]<<','<<r.beta[3]<<','<<r.radiance[3]<<','<<r.direct[0]<<','<<r.direct[3]<<','<<r.radiance[0]<<','<<r.diagnostics[1]<<'\n';}
            }
            for(uint32_t d=0;d<=cfg.maxScatters;++d){depths<<names[mode]<<','<<d<<','<<seeds*cfg.paths;for(double v:betaSums[d])depths<<','<<v/(seeds*cfg.paths);depths<<'\n';}
            for(int channel=0;channel<3;++channel){double se=std::sqrt(m2[channel]/(seeds-1)/seeds),expected=mode==2?2*exact[channel]-le[channel]:exact[channel];
                std::cout<<std::setprecision(12)<<names[mode]<<" channel="<<channel<<" mean="<<mean[channel]<<" SE="<<se<<" expected="<<expected<<'\n';
                Check(std::abs(mean[channel]-expected)<6*se+2e-6,"GPU mean regression");}
            if(mode==1)misMean=mean[0];if(mode==2)wrongMean=mean[0];
        }
        Check(wrongMean-misMean>.1,"double-counting negative control failed");
        // K0仍收取直接可见发光；K1检查边界；rho0仍发光；Le0全黑。
        cfg.mode=1;cfg.seed=0;cfg.paths=256;
        for(uint32_t k:{0u,1u}){cfg.maxScatters=k;auto result=Run(c,frame,cfg,argv[2]);path_reference::Validate(cfg,result,audit);}
        cfg.maxScatters=8;for(float& value:cfg.rho)value=0;
        auto blackReflector=Run(c,frame,cfg,argv[2]);path_reference::Validate(cfg,blackReflector,audit);
        for(auto& r:blackReflector)for(int channel=0;channel<3;++channel)Check(r.radiance[channel]==cfg.emission[channel],"rho0 emission lost");
        for(int channel=0;channel<3;++channel){cfg.rho[channel]=float(rho[channel]);cfg.emission[channel]=0;}
        auto noLight=Run(c,frame,cfg,argv[2]);path_reference::Validate(cfg,noLight,audit);
        for(auto& r:noLight)for(int channel=0;channel<3;++channel)Check(r.radiance[channel]==0,"zero emission not black");
        std::cout<<"vertices="<<audit.vertices<<" TraceRay_calls="<<audit.rays<<" max_equation_error="<<audit.maxValueError
            <<" max_t_error="<<audit.maxPositionError<<" K0_K1_rho0_Le0=PASS\n";
        Check(c.CheckDebug()==0,"debug validation");std::cout<<"GPU PATH PASS\n";
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';if(SUCCEEDED(com))CoUninitialize();return 1;}
    CoUninitialize();return 0;
}
