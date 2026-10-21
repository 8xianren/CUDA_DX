#include "path_gpu.cuh"
#include "path_checks.h"
#include <iostream>
using namespace cuda_pt;
void Report(const char* name,const RenderConfig& cfg,const Rendered& image,std::ofstream& csv,double error){auto t=Sum(image.pixels);
    Require(t.active[0]==uint64_t(cfg.width)*cfg.height*cfg.spp,"primary sample count");uint64_t sum=0;for(unsigned d=0;d<17;++d){sum+=t.active[d];if(d>cfg.maxScatter)Require(t.active[d]==0,"depth limit");if(d)Require(t.active[d]<=t.active[d-1],"active paths monotonic");}Require(sum==t.rays,"per-depth accounting");
    csv<<name<<','<<cfg.width<<','<<cfg.height<<','<<cfg.spp<<','<<cfg.maxScatter<<','<<cfg.nee<<','<<cfg.rr<<','<<image.milliseconds<<','<<t.rays<<','<<t.shadows<<','<<t.vertices<<','<<t.rrKilled<<','<<error<<','<<t.mean;
    for(auto count:t.active)csv<<','<<count;csv<<'\n';csv.flush();std::cout<<name<<" PASS rays="<<t.rays<<" shadows="<<t.shadows<<" RRkills="<<t.rrKilled<<" maxError="<<error<<" GPU_ms="<<image.milliseconds<<" mean="<<t.mean<<'\n'<<std::flush;
}
void VerifyCurrentNeeSurvivesRr(){
    Scene s;s.materials={{{.1f,.1f,.1f},0,{},0},{{0,0,0},0,{2,2,2},0}};
    Quad(s,{-2,-2,0},{2,-2,0},{2,2,0},{-2,2,0},0);Quad(s,{-1,-1,2},{-1,1,2},{1,1,2},{1,-1,2},1);
    auto b=BuildBvh(s);auto l=BuildPathLights(s);auto view=HostView(s,b,l);RenderConfig cfg;cfg.rrStart=1;
    PathState<double> path;path.ray={{0,0,1},{0,0,-1},.0001,1000};
    // 选择一个明确会RR终止的固定离散样本，检验“终止未来”不能删除已生成的直接光任务。
    while(PathRandom(0,path.sample,cfg.seed,0,7)<.1f)++path.sample;
    PathStats stats;auto hit=DoubleTrace{view}(path.ray,stats);auto shadow=ShadePath(view,cfg,path,hit,stats);
    Require(!path.alive&&stats.rrKilled==1&&shadow.valid&&shadow.contribution.x>0,"RR must preserve current NEE task");
    Require(DoubleTrace{view}(shadow.ray,stats).id==Invalid,"RR anchor light must be visible");std::cout<<"RR current-NEE anchor PASS contribution="<<shadow.contribution.x<<'\n';
}
int main(int argc,char** argv){
    if(argc!=4){std::cerr<<"path_verify gallery.meshbin output full|quick\n";return 2;}
    try{
        bool quick=std::string(argv[3])=="quick";Require(quick||std::string(argv[3])=="full","mode");std::filesystem::path out=argv[2];std::filesystem::create_directories(out);
        CheckCuda(cudaSetDevice(0),"device");cudaDeviceProp device{};CheckCuda(cudaGetDeviceProperties(&device,0),"device properties");Require(device.major==12&&device.minor==0,"sm_120 expected");
        cudaFuncAttributes attr{};CheckCuda(cudaFuncGetAttributes(&attr,Megakernel),"Megakernel attributes");
        std::cout<<"GPU="<<device.name<<" registers="<<attr.numRegs<<" local="<<attr.localSizeBytes<<" shared="<<attr.sharedSizeBytes<<'\n';
        std::ofstream csv(out/"paths.csv");csv<<std::setprecision(12)<<"case,width,height,spp,K,NEE,RR,gpu_ms,path_rays,shadow_rays,vertices,rr_killed,max_normalized_error,mean_rgb";for(unsigned d=0;d<17;++d)csv<<",active_"<<d;csv<<'\n';
        auto scene=Cornell();SaveScene(out/"cornell.meshbin",scene);auto tree=BuildBvh(scene);ValidateBvh(scene,tree);auto lights=BuildPathLights(scene);DeviceScene gpu(scene,tree,lights);
        RenderConfig cfg;Camera(cfg,{0,2,8},{0,1.8f,-.3f});cfg.tanHalfFov=.36f;if(quick){cfg.width=13;cfg.height=9;cfg.spp=4;}
        VerifyCurrentNeeSurvivesRr();
        // 数值一致性验证覆盖有限K、MIS开关和RR；CPU float输入/double代数/独立几何，严格检查离散路径决定。
        std::vector<PixelResult> direct,multi;
        for(unsigned mode=0;mode<5;++mode){auto c=cfg;c.maxScatter=mode==0?0:mode==1?1:4;c.rr=mode==3;c.nee=mode!=4;
            auto result=RenderGpu(gpu,c);auto cpu=RenderCpu(scene,tree,lights,c);Sum(cpu);double error=Compare(result.pixels,cpu);Require(error<2e-4,"double CPU/GPU linear image tolerance");
            std::string name=mode==0?"K0-emission":mode==1?"K1-direct":mode==2?"K4-MIS":mode==3?"K4-RR":"K4-BSDF-only";Report(name.c_str(),c,result,csv,error);WriteImage(out/name,result.pixels,c);WriteImage(out/(name+"-cpu"),cpu,c);
            if(mode==1)direct=result.pixels;if(mode==2)multi=result.pixels;
        }
        Require(Sum(multi).mean>Sum(direct).mean,"additional indirect light must contribute");
        auto whole=RenderGpu(gpu,cfg);auto again=RenderGpu(gpu,cfg,64);Require(Compare(whole.pixels,again.pixels)==0,"block size must not change pixel paths");auto wide=RenderGpu(gpu,cfg,256);Require(Compare(whole.pixels,wide.pixels)==0,"256 block determinism");
        std::cout<<"BLOCK determinism 64/128/256 PASS (identical RGB and discrete path hashes)\n";
        auto a=cfg,b=cfg;a.spp=cfg.spp/2;b.spp=cfg.spp-a.spp;b.sampleOffset=a.spp;auto first=RenderGpu(gpu,a),second=RenderGpu(gpu,b);auto combined=first.pixels;
        for(size_t i=0;i<combined.size();++i)combined[i].radiance=(first.pixels[i].radiance*float(a.spp)+second.pixels[i].radiance*float(b.spp))*(1.f/cfg.spp);
        double batching=Compare(combined,whole.pixels,false);Require(batching<2e-6,"sampleOffset split accumulation");Report("split-samples",cfg,whole,csv,batching);
        auto anchor=EmissionAnchor();auto ab=BuildBvh(anchor);auto al=BuildPathLights(anchor);DeviceScene ag(anchor,ab,al);auto ac=cfg;Camera(ac,{0,0,4},{0,0,0});ac.maxScatter=0;
        auto emission=RenderGpu(ag,ac);for(auto& p:emission.pixels)Require(p.radiance.x==3&&p.radiance.y==2&&p.radiance.z==1,"direct emission analytic");Report("emission-analytic",ac,emission,csv,0);
        for(auto& m:anchor.materials)m.emission={};auto blackLights=BuildPathLights(anchor);DeviceScene bg(anchor,ab,blackLights);auto black=RenderGpu(bg,ac);Require(Sum(black.pixels).mean==0,"black exact");Report("black",ac,black,csv,0);
        unsigned rejected=0;auto bad=cfg;bad.maxScatter=17;try{ValidateConfig(bad);}catch(...){++rejected;}bad=cfg;bad.spp=0;try{ValidateConfig(bad);}catch(...){++rejected;}Require(rejected==2,"bad render configs");
        // 大图仅GPU出图；CPU参考验收由上述小图承担，不能把gallery声称逐路径CPU验证通过。
        if(!quick){auto display=cfg;display.width=144;display.height=96;display.spp=128;display.maxScatter=8;auto image=RenderGpu(gpu,display);WriteImage(out/"cornell",image.pixels,display);Report("cornell-view",display,image,csv,-1);
            auto gallery=LoadScene(argv[1]);auto gb=BuildBvh(gallery);ValidateBvh(gallery,gb);auto gl=BuildPathLights(gallery);DeviceScene gg(gallery,gb,gl);
            display.width=192;display.height=96;display.spp=32;display.maxScatter=6;display.tanHalfFov=.31529879f;Camera(display,{0,3.8f,15},{0,1.7f,0});auto rendered=RenderGpu(gg,display);WriteImage(out/"gallery-lambert",rendered.pixels,display);Report("gallery-lambert",display,rendered,csv,-1);
        }
        std::ofstream meta(out/"metadata.txt");meta<<"registers="<<attr.numRegs<<"\nlocal_bytes="<<attr.localSizeBytes<<"\nshared_bytes="<<attr.sharedSizeBytes<<"\npixel_stride="<<sizeof(PixelResult)<<"\nfloat_path_state_bytes="<<sizeof(PathState<float>)<<"\nscene_triangles="<<scene.triangles.size()<<"\nlight_triangles="<<lights.size()<<"\nrejected="<<rejected<<'\n';Require(csv&&meta,"report write");
        std::cout<<"MEGAKERNEL VERIFY PASS\n";return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
