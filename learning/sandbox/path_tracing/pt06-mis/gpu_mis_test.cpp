#include "gpu_reference.h"
#include <fstream>
#include <iomanip>
#include <iostream>
#include <stdexcept>
namespace {
void Require(bool ok,const char* message){if(!ok)throw std::runtime_error(message);}
const char* names[]={"bsdf","nee","balance","power"};
void Save(const std::filesystem::path& dir,const MisConfig& c,const std::vector<MisPixel>& image){
    std::ofstream f(dir/"seed0.csv");f<<"x,y,bsdf,nee,balance,power,primary,light_hits,bsdf_hits\n"<<std::setprecision(10);
    for(size_t p=0;p<image.size();++p){f<<p%c.width<<','<<p/c.width;
        for(float v:image[p].estimates)f<<','<<v;for(int k=0;k<3;++k)f<<','<<image[p].diagnostics[k];f<<'\n';}
}
}
int main(int argc,char** argv){
    if(argc!=5){std::cerr<<"gpu_mis_test scene.gltf integrator.dxil results-dir halfLight\n";return 2;}
    HRESULT com=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    try {
        Check(com,"COM");MisConfig cfg;cfg.halfLight=std::stof(argv[4]);
        auto scene=LoadCpuScene(argv[1]);bool receiver=false,emitter=false;
        for(uint32_t i=0;i<scene.materialAssets.materials.size();++i){auto& m=scene.materialAssets.materials[i];
            if(m.name=="Receiver"){receiver=true;cfg.receiver=i;cfg.rho=m.baseColor[0];}
            if(m.name=="Emitter"){emitter=true;cfg.emitter=i;cfg.le=m.emissive[0];}}
        Require(receiver&&emitter,"fixture materials missing");
        std::filesystem::path dir=argv[3];std::filesystem::create_directories(dir);
        UploadContext context;auto gpu=UploadScene(context,scene);auto blases=BuildMeshBlases(context,gpu);
        context.SubmitWait();gpu.staging.clear();for(auto& b:blases)b.scratch.Reset();
        auto frame=BuildInstanceFrame(context,scene,gpu,blases,false);
        constexpr int seeds=16;size_t count=size_t(cfg.width)*cfg.height;
        std::vector<double> reference(count);double refMean=0,quadratureChange=0;
        std::ofstream refFile(dir/"reference.csv");refFile<<"x,y,linear_radiance\n"<<std::setprecision(12);
        for(uint32_t p=0;p<count;++p){auto xy=gpu_reference::Camera(cfg,p);
            if(gpu_reference::Receiver(xy)){
                reference[p]=mis::Reference(xy[0],xy[1],cfg.halfLight,cfg.rho,cfg.le,512);
                double coarse=mis::Reference(xy[0],xy[1],cfg.halfLight,cfg.rho,cfg.le,256);
                quadratureChange=std::max(quadratureChange,std::abs(reference[p]-coarse));}
            refMean+=reference[p]/count;refFile<<p%cfg.width<<','<<p/cfg.width<<','<<reference[p]<<'\n';}
        double sumMean[4]{},sumMean2[4]{},mse[4]{},maxError=0;uint64_t mismatches=0,rays=0;
        std::vector<MisPixel> baseline;
        auto verify=[&](const MisConfig& config,const std::vector<MisPixel>& image){
            for(uint32_t p=0;p<count;++p){auto ref=gpu_reference::Evaluate(config,p);
                for(int k=0;k<3;++k)mismatches+=image[p].diagnostics[k]!=ref.diagnostics[k];
                for(int k=0;k<4;++k){double error=std::abs(double(image[p].estimates[k])-ref.estimates[k]);
                    Require(std::isfinite(image[p].estimates[k]),"nonfinite output");maxError=std::max(maxError,error);
                    Require(error<2e-5*(1+std::abs(ref.estimates[k])),"CPU/GPU estimator mismatch");}
                rays+=1+(image[p].diagnostics[0]==config.receiver+1?uint64_t(config.rounds)*4:0);}
        };
        std::ofstream metrics(dir/"metrics.csv");metrics<<"seed,mode,mean,mse\n"<<std::setprecision(12);
        for(int seed=0;seed<seeds;++seed){cfg.seed=seed;auto image=DispatchMis(context,frame,cfg,argv[2]);verify(cfg,image);
            if(seed==0){Save(dir,cfg,image);baseline=image;}
            for(int k=0;k<4;++k){double mean=0,error=0;for(size_t p=0;p<count;++p){double v=image[p].estimates[k];mean+=v/count;error+=(v-reference[p])*(v-reference[p])/count;}
                sumMean[k]+=mean;sumMean2[k]+=mean*mean;mse[k]+=error/seeds;metrics<<seed<<','<<names[k]<<','<<mean<<','<<error<<'\n';}
        }
        // 相同seed的尺度不变量：Le翻倍→每个估计器翻倍；rho=0→严格黑；pan改变主射线覆盖。
        cfg.seed=0;float originalLe=cfg.le;cfg.le*=2;auto doubled=DispatchMis(context,frame,cfg,argv[2]);verify(cfg,doubled);
        for(size_t p=0;p<count;++p)for(int k=0;k<4;++k)Require(doubled[p].estimates[k]==2*baseline[p].estimates[k],"Le scaling");
        cfg.le=originalLe;cfg.rho=0;auto black=DispatchMis(context,frame,cfg,argv[2]);verify(cfg,black);
        for(auto& p:black)for(float v:p.estimates)Require(v==0,"black material");
        cfg.rho=scene.materialAssets.materials[cfg.receiver].baseColor[0];cfg.panX=.2f;cfg.panY=-.1f;
        auto moved=DispatchMis(context,frame,cfg,argv[2]);verify(cfg,moved);
        unsigned coverageChanges=0;for(size_t p=0;p<count;++p)coverageChanges+=moved[p].diagnostics[0]!=baseline[p].diagnostics[0];
        Require(coverageChanges>0,"camera coverage unchanged");
        std::cout<<std::setprecision(10)<<"reference_mean="<<refMean<<" quadrature_256_512_max_change="<<quadratureChange<<'\n';
        for(int k=0;k<4;++k){double mean=sumMean[k]/seeds,variance=std::max(0.,(sumMean2[k]-seeds*mean*mean)/(seeds-1));
            double se=std::sqrt(variance/seeds);std::cout<<names[k]<<" mean="<<mean<<" mean_SE="<<se<<" MSE="<<mse[k]<<'\n';
            // 宽松统计回归阈值，不把两级求积差说成严格误差界，也不作为无偏性的证明。
            Require(std::abs(mean-refMean)<6*se+2*quadratureChange+1e-6,"mean regression");}
        std::cout<<"rays="<<rays<<" diagnostics_mismatch="<<mismatches<<" max_CPU_GPU_error="<<maxError
                 <<" camera_coverage_changes="<<coverageChanges<<" scaling_black=PASS\n";
        Require(mismatches==0,"hit diagnostic mismatch");Require(context.CheckDebug()==0,"debug validation failed");
        std::cout<<"GPU MIS PASS\n";
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';if(SUCCEEDED(com))CoUninitialize();return 1;}
    CoUninitialize();return 0;
}
