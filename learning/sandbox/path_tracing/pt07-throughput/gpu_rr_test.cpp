#include "gpu_path_reference.h"
#include <fstream>
#include <iostream>
#include <iomanip>
using path_reference::Check;
// Welford计算重复实验均值的标准误；不把单路径方差和seed均值方差混用。
struct Moments {uint64_t n=0;double mean=0,m2=0;
    void Add(double x){double delta=x-mean;mean+=delta/++n;m2+=delta*(x-mean);}
    double SE()const{return n>1?std::sqrt(std::max(0.,m2)/(n-1)/n):0;}};
struct DepthStats {uint64_t reached=0;double beta[3]{};};
int main(int argc,char** argv){
    if(argc!=4){std::cerr<<"gpu_rr_test box.gltf path.dxil output-dir\n";return 2;}
    HRESULT com=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    try{
        ::Check(com,"COM");PathConfig cfg;cfg.maxScatters=16;cfg.mode=1; // 保持上一课的MIS估计器，单独比较终止策略。
        auto cpu=LoadCpuScene(argv[1]);bool found=false;
        for(auto& m:cpu.materialAssets.materials)if(m.name=="Cavity"){found=true;for(int k=0;k<3;++k){cfg.rho[k]=m.baseColor[k];cfg.emission[k]=m.emissive[k];}}
        Check(found,"fixture material missing");std::filesystem::path out=argv[3];std::filesystem::create_directories(out);
        std::ofstream metrics(out/"seed_metrics.csv"),depthFile(out/"depths.csv"),trace(out/"decisions.csv"),summary(out/"summary.csv");
        Check(bool(metrics)&&bool(depthFile)&&bool(trace)&&bool(summary),"output files");
        metrics<<"mode,seed,r,g,b,mean_scatters,mean_rays\n"<<std::setprecision(12);
        depthFile<<"mode,depth,reached,initial_paths,survival_fraction,beta_all_r,beta_alive_r,beta_all_g,beta_alive_g,beta_all_b,beta_alive_b\n"<<std::setprecision(12);
        trace<<"mode,path,depth,alive,beta_r,survival,u,attempted,continue,total_r\n"<<std::setprecision(12);
        summary<<"mode,channel,mean,SE,finite_reference,mean_scatters,mean_rays\n"<<std::setprecision(12);
        UploadContext c;auto gpu=UploadScene(c,cpu);auto blases=BuildMeshBlases(c,gpu);c.SubmitWait();
        gpu.staging.clear();for(auto& b:blases)b.scratch.Reset();auto frame=BuildInstanceFrame(c,cpu,gpu,blases,false);
        constexpr int seeds=16;const char* names[]{"off","compensated","wrong_no_compensation"};
        double seedValues[3][seeds][3]{};Moments means[3][3],scatters[3],rayCounts[3];path_reference::Audit audit;
        throughput::RGB rho{cfg.rho[0],cfg.rho[1],cfg.rho[2]},le{cfg.emission[0],cfg.emission[1],cfg.emission[2]};
        auto exact=throughput::Analytic(rho,le,cfg.maxScatters);
        for(uint32_t mode=0;mode<3;++mode){cfg.rrMode=mode;std::vector<DepthStats> depths(cfg.maxScatters+1);
            for(uint32_t seed=0;seed<seeds;++seed){cfg.seed=seed;auto records=Run(c,frame,cfg,argv[2]);path_reference::Validate(cfg,records,audit);
                double sum[3]{};uint64_t reached=0,rays=0;
                for(uint32_t p=0;p<cfg.paths;++p){
                    for(uint32_t d=0;d<=cfg.maxScatters;++d){const auto& r=records[size_t(p)*(cfg.maxScatters+1)+d];
                        bool alive=r.diagnostics[0]!=0;rays+=r.diagnostics[1];reached+=alive;depths[d].reached+=alive;
                        for(int k=0;k<3;++k)depths[d].beta[k]+=r.beta[k];
                        if(seed==0&&p<4)trace<<names[mode]<<','<<p<<','<<d<<','<<alive<<','<<r.beta[0]<<','<<r.roulette[0]<<','<<r.roulette[1]<<','<<r.roulette[2]<<','<<r.roulette[3]<<','<<r.radiance[0]<<'\n';
                    }
                    // 早停后的尾槽保存最终L，因此所有初始路径都计入平均；绝不能只平均幸存路径。
                    const auto& last=records[size_t(p)*(cfg.maxScatters+1)+cfg.maxScatters];for(int k=0;k<3;++k)sum[k]+=last.radiance[k];
                }
                metrics<<names[mode]<<','<<seed;for(int k=0;k<3;++k){double v=sum[k]/cfg.paths;seedValues[mode][seed][k]=v;means[mode][k].Add(v);metrics<<','<<v;}
                double depthMean=double(reached)/cfg.paths-1,rayMean=double(rays)/cfg.paths;
                scatters[mode].Add(depthMean);rayCounts[mode].Add(rayMean);metrics<<','<<depthMean<<','<<rayMean<<'\n';
            }
            for(uint32_t d=0;d<=cfg.maxScatters;++d){auto& s=depths[d];uint64_t initial=uint64_t(seeds)*cfg.paths;
                depthFile<<names[mode]<<','<<d<<','<<s.reached<<','<<initial<<','<<double(s.reached)/initial;
                for(double value:s.beta)depthFile<<','<<value/initial<<','<<(s.reached?value/s.reached:0);depthFile<<'\n';
                if(d==0||d==3||d==8||d==16)std::cout<<names[mode]<<" depth="<<d<<" reached="<<s.reached<<" beta_all_r="<<s.beta[0]/initial<<" beta_alive_r="<<(s.reached?s.beta[0]/s.reached:0)<<'\n';
            }
            for(int k=0;k<3;++k){auto& s=means[mode][k];summary<<names[mode]<<','<<k<<','<<s.mean<<','<<s.SE()<<','<<exact[k]<<','<<scatters[mode].mean<<','<<rayCounts[mode].mean<<'\n';
                std::cout<<std::setprecision(12)<<names[mode]<<" channel="<<k<<" mean="<<s.mean<<" SE="<<s.SE()<<" finite_reference="<<exact[k]<<'\n';
                if(mode!=2)Check(std::abs(s.mean-exact[k])<6*s.SE()+2e-6,"RR mean vs finite reference");}
            std::cout<<names[mode]<<" mean_scatters="<<scatters[mode].mean<<" mean_TraceRay="<<rayCounts[mode].mean<<'\n';
        }
        for(int k=0;k<3;++k){Moments differences;for(int s=0;s<seeds;++s)differences.Add(seedValues[1][s][k]-seedValues[0][s][k]);
            std::cout<<"paired channel="<<k<<" compensated_minus_off="<<differences.mean<<" paired_SE="<<differences.SE()<<'\n';
            Check(std::abs(differences.mean)<4*differences.SE()+2e-6,"paired RR mean changed");}
        Check(means[0][0].mean-means[2][0].mean>.02,"missing compensation did not dim");
        Check(scatters[1].mean<scatters[0].mean*.5,"RR did not reduce average scatter count");
        // s=1必须退化为不终止、不放大，独立RR流应使路径几何和L逐值保持一致。
        PathConfig edge=cfg;edge.paths=256;edge.maxScatters=4;edge.seed=123;edge.rrMode=0;
        auto baseline=Run(c,frame,edge,argv[2]);path_reference::Validate(edge,baseline,audit);
        edge.rrMode=1;edge.rrStart=1;edge.rrMin=edge.rrMax=1;
        auto always=Run(c,frame,edge,argv[2]);path_reference::Validate(edge,always,audit);
        for(size_t i=0;i<baseline.size();++i)for(int k=0;k<3;++k)Check(baseline[i].radiance[k]==always[i].radiance[k]&&baseline[i].beta[k]==always[i].beta[k],"survival1 changed result");
        // 检查概率上下限与beta全零：不依赖统计均值，逐次CPU决策和递推都要匹配。
        edge.rrMin=.05f;edge.rrMax=.95f;
        for(float value:{.001f,.99f,0.f}){for(float& r:edge.rho)r=value;auto records=Run(c,frame,edge,argv[2]);path_reference::Validate(edge,records,audit);
            double wanted=value==0?0:(value<.05f?edge.rrMin:edge.rrMax);
            for(uint32_t p=0;p<edge.paths;++p)Check(std::abs(records[size_t(p)*(edge.maxScatters+1)].roulette[0]-wanted)<1e-6,"RR clamp/s0 failure");}
        std::cout<<"audit_vertices="<<audit.vertices<<" TraceRay_calls="<<audit.rays<<" max_equation_error="<<audit.maxValueError<<" max_t_error="<<audit.maxPositionError<<" s1_floor_cap_zero=PASS\n";
        Check(c.CheckDebug()==0,"debug validation");std::cout<<"GPU RR PASS\n";
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';if(SUCCEEDED(com))CoUninitialize();return 1;}
    CoUninitialize();return 0;
}
