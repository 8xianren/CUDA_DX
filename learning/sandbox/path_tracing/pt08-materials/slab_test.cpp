#include "ray_buffer_dispatch.h"
#include "slab_reference.h"
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
using namespace slab;

int main(int argc,char** argv){
    if(argc!=4){std::cerr<<"slab_test slab.gltf slab.dxil output-directory\n";return 2;}
    HRESULT com=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    try{
        Check(com,"COM");auto cpu=LoadCpuScene(argv[1]);Config base;
        for(uint32_t i=0;i<cpu.materialAssets.materials.size();++i){auto& m=cpu.materialAssets.materials[i];
            if(m.name=="Top")base.topID=i+1;if(m.name=="Bottom")base.bottomID=i+1;
            if(m.name=="UpperLamp"){base.upperID=i+1;for(int k=0;k<3;++k)base.upperLe[k]=m.emissive[k];}
            if(m.name=="LowerLamp"){base.lowerID=i+1;for(int k=0;k<3;++k)base.lowerLe[k]=m.emissive[k];}}
        Require(base.topID&&base.bottomID&&base.upperID&&base.lowerID,"fixture material missing");
        std::filesystem::path out=argv[3];std::filesystem::create_directories(out);
        std::ofstream csv(out/"summary.csv"),trace(out/"steps.csv");Require(bool(csv)&&bool(trace),"output open");
        csv<<std::setprecision(12)<<"case,mode,K,paths,upper,lower,capped,max_scatter,rays,F,upper_coefficient,lower_coefficient,tail,r_mean,r_SE,r_target,g_mean,g_SE,g_target,b_mean,b_SE,b_target,max_field_error\n";
        trace<<std::setprecision(12)<<"case,mode,path,depth,hit,event,inside_before,inside_after,x,z,dx,dz,beta,etaScale,weight,q2,u,pr,F,mass\n";
        // c拥有设备/队列/Fence；GPU网格、BLAS、TLAS贯穿全部Dispatch。
        // Upload的临时staging和BLAS scratch只在首次SubmitWait确认完成后释放。
        UploadContext c;auto gpu=UploadScene(c,cpu);auto blases=BuildMeshBlases(c,gpu);
        c.SubmitWait();gpu.staging.clear();for(auto& b:blases)b.scratch.Reset();
        auto frame=BuildInstanceFrame(c,cpu,gpu,blases,false);
        // 负对照：显式关闭起点偏移。错误路径在shader中被拒绝，不参与正确渲染的统计。
        // 是否出现自相交依赖硬件/驱动；本机要求复现，不能把这一计数当跨设备固定常数。
        Config bad=base;bad.parameters[0]=float(std::sqrt(3.));bad.disableOffset=1;
        auto badBytes=DispatchRayBuffer(c,frame,&bad,sizeof(bad),bad.width,bad.height,size_t(bad.width)*bad.height*sizeof(Record),argv[2]);
        std::vector<Record> badRecords(size_t(bad.width)*bad.height);std::memcpy(badRecords.data(),badBytes.data(),badBytes.size());
        uint64_t badCount=0,badRays=0;for(auto& r:badRecords){badCount+=r.status[0]>=400&&r.status[0]<500;badRays+=r.status[2];}
        std::ofstream badLog(out/"negative-control.txt");
        badLog<<"disableOffset=1 paths="<<badRecords.size()<<" medium_rejections="<<badCount<<" TraceRay="<<badRays<<'\n';
        badLog.flush();Require(bool(badLog),"negative control log");Require(badCount>0,"self-intersection negative control not reproduced");
        std::cout<<"self-intersection negative control rejected="<<badCount<<" / "<<badRecords.size()<<'\n';
        struct Case {const char* name;double degrees;uint32_t K,inside;float ior;};
        Case cases[]{{"normal_K1",0,1,0,1.5f},{"normal_K2",0,2,0,1.5f},
            {"normal_K8",0,8,0,1.5f},{"air60_K8",60,8,0,1.5f},
            {"air80_K16",80,16,0,1.5f},{"inside30_K8",30,8,1,1.5f},
            {"inside_TIR45",45,16,1,1.5f},{"equal_IOR",60,8,0,1}};
        uint64_t totalPaths=0,totalRays=0;double maximum=0;
        for(auto test:cases)for(uint32_t mode=0;mode<2;++mode){
            Config cfg=base;cfg.parameters[0]=float(std::tan(test.degrees*3.14159265358979323846/180));
            cfg.parameters[1]=test.inside?-.5f:1;cfg.parameters[3]=test.ior;
            cfg.startInside=test.inside;cfg.maxScatter=test.K;cfg.mode=mode;
            Require(cfg.maxScatter>=1&&cfg.maxScatter<=16&&cfg.mode<=1&&cfg.parameters[3]>0,"invalid configuration");
            auto target=Analytic(cfg);Moment moments[3];uint64_t ends[5]{},rays=0;uint32_t deepest=0;double maxError=0;
            // 8个独立seed、每次4096条路径；输出buffer由函数复制回CPU拥有的vector。
            // 任何HRESULT、输出文件失败、逐字段或统计验收失败均抛异常，main退出1。
            for(uint32_t seed=0;seed<8;++seed){cfg.seed=seed;
                auto bytes=DispatchRayBuffer(c,frame,&cfg,sizeof(cfg),cfg.width,cfg.height,
                    size_t(cfg.width)*cfg.height*sizeof(Record),argv[2]);
                std::vector<Record> records(size_t(cfg.width)*cfg.height);
                Require(bytes.size()==records.size()*sizeof(Record),"readback size");
                std::memcpy(records.data(),bytes.data(),bytes.size());
                uint32_t recordedLong=0;
                for(uint32_t index=0;index<records.size();++index){const auto& r=records[index];
                    maxError=std::max(maxError,Audit(cfg,index,r));
                    Require(r.status[0]>=1&&r.status[0]<=3,"GPU path error");
                    ++ends[r.status[0]];rays+=r.status[2];deepest=std::max(deepest,r.status[1]);
                    for(int k=0;k<3;++k)moments[k].Add(r.radiance[k]); // 包括截断的零贡献，绝不丢弃样本。
                    bool log=seed==0&&(index<4||(r.status[1]>=4&&recordedLong++<4));
                    if(log)for(uint32_t depth=0;depth<r.status[1];++depth){auto& s=r.steps[depth];
                        trace<<test.name<<','<<mode<<','<<index<<','<<depth<<','<<s.ids[0]<<','<<s.ids[1]<<','<<s.ids[2]<<','<<s.ids[3]
                            <<','<<s.position[0]<<','<<s.position[2]<<','<<s.direction[0]<<','<<s.direction[2];
                        for(float v:s.state)trace<<','<<v;for(float v:s.probability)trace<<','<<v;trace<<'\n';}
                }
            }
            uint64_t paths=uint64_t(cfg.width)*cfg.height*8;
            // 独立检验截断频率：这里用抽样pr；解析辐亮度用物理F，二者在半半策略中不同。
            double pr=target.F<=0?0:(target.F>=1?1:(mode==1?.5:target.F));
            double capProbability=test.inside?std::pow(pr,int(test.K)):(1-pr)*std::pow(pr,int(test.K)-1);
            Require(std::abs(double(ends[3])/paths-capProbability)<6*std::sqrt(capProbability*(1-capProbability)/paths)+2e-6,"cap frequency");
            if(test.degrees==45&&test.inside)Require(ends[3]==paths&&deepest==test.K,"TIR must stay inside");
            if(test.ior==1)Require(ends[2]==paths&&deepest==2,"matched IOR must transmit twice");
            if(test.degrees==0&&test.K==8&&mode==1)Require(deepest>=6,"internal reflection coverage");
            csv<<test.name<<','<<mode<<','<<test.K<<','<<paths<<','<<ends[1]<<','<<ends[2]<<','<<ends[3]<<','<<deepest<<','<<rays
                <<','<<target.F<<','<<target.upper<<','<<target.lower<<','<<target.tail;
            for(int k=0;k<3;++k){Require(std::abs(moments[k].mean-target.rgb[k])<6*moments[k].SE()+3e-6,"slab mean vs analytic");
                csv<<','<<moments[k].mean<<','<<moments[k].SE()<<','<<target.rgb[k];}
            csv<<','<<maxError<<'\n';
            std::cout<<test.name<<" mode="<<mode<<" red="<<moments[0].mean<<" expected="<<target.rgb[0]
                <<" capped="<<ends[3]<<" depth="<<deepest<<" max_error="<<maxError<<'\n';
            totalPaths+=paths;totalRays+=rays;maximum=std::max(maximum,maxError);
        }
        csv.flush();trace.flush();Require(bool(csv)&&bool(trace),"output write");Require(c.CheckDebug()==0,"D3D validation");
        std::cout<<std::setprecision(12)<<"Slab PASS paths="<<totalPaths<<" TraceRay="<<totalRays<<" max_error="<<maximum<<'\n';
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';if(SUCCEEDED(com))CoUninitialize();return 1;}
    CoUninitialize();return 0;
}
