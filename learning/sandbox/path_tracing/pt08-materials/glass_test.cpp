#include "ray_buffer_dispatch.h"
#include "dielectric_math.h"
#include <cstring>
#include <fstream>
#include <iostream>
#include <iomanip>
#include <cstddef>
struct Config {uint32_t width=64,height=64,glassID=0,upperID=0,lowerID=0,seed=0,mode=0,pad=0;float parameters[4]{0,1,1,1.5f},upperLe[4]{},lowerLe[4]{};};
struct Record {float position[4],outgoing[4],beta[4],random[4],endpoint[4],L[4],wrong[4];uint32_t diagnostics[4];};
static_assert(sizeof(Config)==80&&offsetof(Config,parameters)==32&&sizeof(Record)==128&&offsetof(Record,diagnostics)==112);
void Require(bool v,const char* message){if(!v)throw std::runtime_error(message);}
struct Moment {uint64_t n=0;double mean=0,m2=0;void Add(double x){double d=x-mean;mean+=d/++n;m2+=d*(x-mean);}double SE()const{return n>1?std::sqrt(m2/(n-1)/n):0;}};
double Random(uint32_t index,uint32_t seed){uint32_t x=(index+1)*747796405u+seed*2891336453u+0x9e3779b9u;x=(x^(x>>16))*0x21f0aaadu;x=(x^(x>>15))*0x735a2d97u;x^=x>>15;return ((x>>9)+.5)/8388608.;}
int main(int argc,char** argv){if(argc!=4){std::cerr<<"glass_test glass.gltf glass.dxil output-directory\n";return 2;}
    HRESULT com=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    try {Check(com,"COM");auto cpu=LoadCpuScene(argv[1]);Config base;
        for(uint32_t i=0;i<cpu.materialAssets.materials.size();++i){auto& m=cpu.materialAssets.materials[i];
            if(m.name=="Glass")base.glassID=i+1;
            if(m.name=="UpperLamp"){base.upperID=i+1;for(int k=0;k<3;++k)base.upperLe[k]=m.emissive[k];}
            if(m.name=="LowerLamp"){base.lowerID=i+1;for(int k=0;k<3;++k)base.lowerLe[k]=m.emissive[k];}}
        Require(base.glassID&&base.upperID&&base.lowerID,"fixture materials missing");
        std::filesystem::path out=argv[3];std::filesystem::create_directories(out);
        std::ofstream csv(out/"summary.csv"),trace(out/"paths.csv");Require(bool(csv)&&bool(trace),"output open");
        csv<<"case,mode,paths,reflected,transmitted,missed,F,r_mean,r_SE,r_expected,g_mean,g_SE,g_expected,b_mean,b_SE,b_expected,wrong_no_eta_r,max_error\n"<<std::setprecision(12);
        trace<<"case,mode,seed,path,event,F,u,mass,weight,etaScale,hit_ID,Lr,Lg,Lb\n"<<std::setprecision(12);
        // 同步后端复用设备、上传、BLAS/TLAS和SBT实现；资源活到所有读回Fence结束。
        UploadContext c;auto gpu=UploadScene(c,cpu);auto blases=BuildMeshBlases(c,gpu);c.SubmitWait();gpu.staging.clear();for(auto& b:blases)b.scratch.Reset();auto frame=BuildInstanceFrame(c,cpu,gpu,blases,false);
        struct Case {const char* name;double degrees;float side,ior;};
        Case cases[]{{"air_normal",0,1,1.5f},{"air_60",60,1,1.5f},{"air_80_reflection_miss",80,1,1.5f},{"glass_30",30,-1,1.5f},{"glass_TIR45",45,-1,1.5f},{"equal_IOR",60,1,1}};
        uint64_t total=0;double maxError=0;
        for(auto test:cases)for(uint32_t mode=0;mode<2;++mode){Config cfg=base;cfg.parameters[0]=float(std::tan(test.degrees*3.14159265358979323846/180));cfg.parameters[1]=test.side;cfg.parameters[3]=test.ior;cfg.mode=mode;
            Require(std::isfinite(cfg.parameters[0])&&std::abs(cfg.parameters[0])<6&&cfg.parameters[2]>0&&cfg.parameters[3]>0,"configuration domain");
            // double独立参考从斜率重建单位向量，再用Snell三角关系和解析平面求交；不调用HLSL采样函数。
            double slope=cfg.parameters[0],len=std::sqrt(1+slope*slope),ci=1/len,dx=slope/len;
            double ni=test.side>0?1:test.ior,nt=test.side>0?test.ior:1,q=ni/nt,q2=q*q;auto fresnel=dielectric::Evaluate(ci,ni,nt);Require(fresnel.valid,"reference Fresnel");
            double F=fresnel.F,pr=F<=0?0:(F>=1?1:(mode==1?.5:F));
            double directions[2][3]{{dx,0,test.side*ci},{q*dx,0,-test.side*fresnel.cosT}};
            Moment stats[3],wrong;uint64_t reflected=0,missed=0;double caseError=0;double target[3]{};
            auto checkNear=[&](double got,double expected){double error=std::abs(got-expected);Require(std::isfinite(got)&&error<3e-5,"CPU/GPU field mismatch");caseError=std::max(caseError,error);};
            // 解析目标对每个主射线网格中心都计入，包括所有miss；不只平均成功命中灯的路径。
            for(uint32_t y=0;y<cfg.height;++y)for(uint32_t x=0;x<cfg.width;++x){double px=(x+.5)/cfg.width-.5+slope,py=(y+.5)/cfg.height-.5;
                for(int branch=0;branch<2;++branch){double coefficient=branch==0?F:(1-F)*q2;if(coefficient==0)continue;auto d=directions[branch];double travel=2/std::abs(d[2]);
                    bool lamp=std::abs(px+travel*d[0])<8&&std::abs(py)<8;auto le=d[2]>0?cfg.upperLe:cfg.lowerLe;
                    for(int k=0;k<3;++k)target[k]+=lamp?coefficient*le[k]/(cfg.width*cfg.height):0;}}
            constexpr uint32_t seeds=8;
            for(uint32_t seed=0;seed<seeds;++seed){cfg.seed=seed;
                auto bytes=DispatchRayBuffer(c,frame,&cfg,sizeof(cfg),cfg.width,cfg.height,size_t(cfg.width)*cfg.height*sizeof(Record),argv[2]);
                std::vector<Record> records(size_t(cfg.width)*cfg.height);Require(bytes.size()==records.size()*sizeof(Record),"readback size");std::memcpy(records.data(),bytes.data(),bytes.size());
                for(uint32_t index=0;index<records.size();++index){auto& r=records[index];uint32_t x=index%cfg.width,y=index/cfg.width;
                    double px=(x+.5)/cfg.width-.5+slope,py=(y+.5)/cfg.height-.5,u=Random(index,seed);
                    checkNear(r.outgoing[3],F);checkNear(r.random[0],u);checkNear(r.random[1],pr);checkNear(r.random[2],ni);checkNear(r.random[3],nt);
                    // 先独立验证GPU概率，再以其实际float阈值核对分支，避免把阈值舍入误报成算法错误。
                    int branch=u<r.random[1]?0:1;bool reflect=branch==0;reflected+=reflect;
                    Require(r.diagnostics[0]==uint32_t(branch+1)&&r.diagnostics[1]==cfg.glassID&&r.diagnostics[3]==2,"event/first hit/ray count");
                    auto d=directions[branch];checkNear(r.position[0],px);checkNear(r.position[1],py);checkNear(r.position[2],0);checkNear(r.position[3],len);
                    for(int k=0;k<3;++k)checkNear(r.outgoing[k],d[k]);
                    double mass=reflect?r.random[1]:1-r.random[1];Require(mass>0,"zero event probability");
                    double weight=reflect?r.outgoing[3]/mass:(1-r.outgoing[3])*q2/mass;
                    checkNear(r.beta[0],weight);checkNear(r.beta[1],reflect?1:1/q2);checkNear(r.beta[2],q2);checkNear(r.beta[3],mass);
                    double travel=2/std::abs(d[2]),qx=px+travel*d[0];bool lamp=std::abs(qx)<8&&std::abs(py)<8;
                    uint32_t wanted=lamp?(d[2]>0?cfg.upperID:cfg.lowerID):0;Require(r.diagnostics[2]==wanted,"second DXR hit/miss");missed+=!lamp;
                    if(lamp){checkNear(r.endpoint[0],qx);checkNear(r.endpoint[1],py);checkNear(r.endpoint[2],d[2]>0?2:-2);checkNear(r.endpoint[3],travel);}
                    else for(float v:r.endpoint)checkNear(v,0);
                    auto le=d[2]>0?cfg.upperLe:cfg.lowerLe;checkNear(r.L[3],lamp?1:0);
                    for(int k=0;k<3;++k){double expected=lamp?weight*le[k]:0;checkNear(r.L[k],expected);checkNear(r.wrong[k],expected/(reflect?1:q2));stats[k].Add(r.L[k]);}
                    wrong.Add(r.wrong[0]);
                    if(seed==0&&index<16)trace<<test.name<<','<<mode<<','<<seed<<','<<index<<','<<r.diagnostics[0]<<','<<r.outgoing[3]<<','<<u<<','<<mass<<','<<r.beta[0]<<','<<r.beta[1]<<','<<wanted<<','<<r.L[0]<<','<<r.L[1]<<','<<r.L[2]<<'\n';
                }
            }
            uint64_t count=uint64_t(cfg.width)*cfg.height*seeds;
            Require(std::abs(double(reflected)/count-pr)<6*std::sqrt(pr*(1-pr)/count)+2e-6,"branch frequency");
            if(test.degrees==80)Require(missed==reflected&&missed>0,"reflection miss coverage");else Require(missed==0,"unexpected misses");
            if(F==1)Require(reflected==count,"TIR transmission");if(F==0)Require(reflected==0,"equal IOR reflection");
            csv<<test.name<<','<<mode<<','<<count<<','<<reflected<<','<<count-reflected<<','<<missed<<','<<F;
            for(int k=0;k<3;++k){Require(std::abs(stats[k].mean-target[k])<6*stats[k].SE()+2e-6,"mean vs analytic target");csv<<','<<stats[k].mean<<','<<stats[k].SE()<<','<<target[k];}
            csv<<','<<wrong.mean<<','<<caseError<<'\n';
            if(test.degrees==0)Require(wrong.mean-stats[0].mean>.09,"missing q2 negative control");
            std::cout<<test.name<<" mode="<<mode<<" reflected="<<reflected<<" miss="<<missed<<" red="<<stats[0].mean<<" expected="<<target[0]<<" max_error="<<caseError<<'\n';
            total+=count;maxError=std::max(maxError,caseError);
        }
        csv.flush();trace.flush();Require(bool(csv)&&bool(trace),"output write");Require(c.CheckDebug()==0,"D3D validation");
        std::cout<<std::setprecision(12)<<"Glass PASS paths="<<total<<" TraceRay="<<2*total<<" max_error="<<maxError<<'\n';
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';if(SUCCEEDED(com))CoUninitialize();return 1;}CoUninitialize();return 0;
}
