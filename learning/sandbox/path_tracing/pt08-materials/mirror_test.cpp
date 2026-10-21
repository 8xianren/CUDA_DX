#include "ray_buffer_dispatch.h"
#include <cmath>
#include <cstring>
#include <fstream>
#include <iostream>
#include <iomanip>
#include <cstddef>
// StructuredBuffer按字段顺序布局；用整行16B减少跨语言错位风险，不能拿CBV的256B对齐代替stride。
struct Config {uint32_t width=64,height=64,mirrorID=0,lampID=0;float slope[4]{};float R[4]{},Le[4]{};};
struct Record {float point[4],reflected[4],beta[4],L[4],wrong[4];uint32_t diagnostics[4];};
static_assert(sizeof(Config)==64&&sizeof(Record)==96&&offsetof(Record,diagnostics)==80);
void Require(bool ok,const char* what){if(!ok)throw std::runtime_error(what);}
int main(int argc,char** argv){
    if(argc!=4){std::cerr<<"mirror_test mirror.gltf mirror.dxil output-dir\n";return 2;}
    HRESULT com=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    try{
        Check(com,"COM");auto cpu=LoadCpuScene(argv[1]);Config base;
        // 显式名称覆盖仅用于此fixture；不把roughness=0自动解释为本课的常量R镜面。
        for(uint32_t i=0;i<cpu.materialAssets.materials.size();++i){auto& m=cpu.materialAssets.materials[i];
            if(m.name=="Mirror"){base.mirrorID=i+1;for(int k=0;k<3;++k)base.R[k]=m.baseColor[k];}
            if(m.name=="Lamp"){base.lampID=i+1;for(int k=0;k<3;++k)base.Le[k]=m.emissive[k];}}
        Require(base.mirrorID&&base.lampID,"fixture materials missing");
        std::filesystem::path out=argv[3];std::filesystem::create_directories(out);
        std::ofstream csv(out/"summary.csv");Require(bool(csv),"cannot open summary");
        csv<<"case,paths,lamp_hits,trace_rays,nee_rays,hit_r,hit_g,hit_b,wrong_hit_r,max_error\n"<<std::setprecision(12);
        // 共享后端拥有设备与队列；gpu/BLAS/frame在最后一次同步读回结束前一直存活。
        UploadContext c;auto gpu=UploadScene(c,cpu);auto blases=BuildMeshBlases(c,gpu);c.SubmitWait();
        gpu.staging.clear();for(auto& b:blases)b.scratch.Reset();auto frame=BuildInstanceFrame(c,cpu,gpu,blases,false);
        uint64_t totalRays=0;double maxError=0;
        const char* names[]{"normal","oblique","miss","black","white"};
        for(int test=0;test<5;++test){Config cfg=base;
            if(test==1){cfg.slope[0]=.2f;cfg.slope[1]=-.1f;}
            if(test==2){cfg.slope[0]=1.2f;cfg.slope[1]=.2f;}
            if(test>=3)for(int k=0;k<3;++k)cfg.R[k]=test==3?0.f:1.f;
            // 宿主限制输入；float非有限数或R超出反射率范围不能送入shader后期待PDF补救。
            for(int k=0;k<3;++k)Require(std::isfinite(cfg.R[k])&&cfg.R[k]>=0&&cfg.R[k]<=1&&std::isfinite(cfg.Le[k])&&cfg.Le[k]>=0,"invalid material");
            auto bytes=DispatchRayBuffer(c,frame,&cfg,sizeof(cfg),cfg.width,cfg.height,size_t(cfg.width)*cfg.height*sizeof(Record),argv[2]);
            std::vector<Record> records(size_t(cfg.width)*cfg.height);Require(bytes.size()==records.size()*sizeof(Record),"readback size");
            std::memcpy(records.data(),bytes.data(),bytes.size());
            uint64_t hits=0,rays=0;double sum[3]{},wrong=0,caseError=0;
            auto checkNear=[&](double got,double expected){double e=std::abs(got-expected);Require(std::isfinite(got)&&e<3e-5,"CPU/GPU mismatch");caseError=std::max(caseError,e);};
            const double sx=cfg.slope[0],sy=cfg.slope[1],len=std::sqrt(1+sx*sx+sy*sy);
            for(uint32_t y=0;y<cfg.height;++y)for(uint32_t x=0;x<cfg.width;++x){const auto& r=records[size_t(y)*cfg.width+x];
                // CPU独立双精度解析：下降1米后反射，再上升2米；水平总位移=3*slope。
                const double ox=((x+.5)/cfg.width*2-1)*1.6,oy=((y+.5)/cfg.height*2-1)*1.6;
                const bool hit=std::abs(ox+3*sx)<1&&std::abs(oy+3*sy)<1;
                Require(r.diagnostics[0]==cfg.mirrorID&&r.diagnostics[1]==(hit?cfg.lampID:0),"hit identity");
                Require(r.diagnostics[2]==2&&r.diagnostics[3]==0,"ray count / unexpected NEE");rays+=r.diagnostics[2];hits+=hit;
                checkNear(r.point[0],ox+sx);checkNear(r.point[1],oy+sy);checkNear(r.point[2],0);checkNear(r.point[3],len);
                checkNear(r.reflected[0],sx/len);checkNear(r.reflected[1],sy/len);checkNear(r.reflected[2],1/len);checkNear(r.reflected[3],1);
                checkNear(r.beta[3],1);checkNear(r.L[3],hit?1:0);
                // 面积4，距离2*len，光源余弦1/len，因此连续pL=len^3；它不与离散mass=1可比。
                double pLight=len*len*len,wrongWeight=1/(1+pLight*pLight);
                checkNear(r.wrong[3],hit?pLight:0);
                for(int k=0;k<3;++k){double exact=hit?double(cfg.R[k])*cfg.Le[k]:0;
                    checkNear(r.beta[k],cfg.R[k]);checkNear(r.L[k],exact);checkNear(r.wrong[k],exact*wrongWeight);sum[k]+=r.L[k];}
                wrong+=r.wrong[0];
            }
            Require(test==2?hits==0:hits>0,"fixture coverage");
            if(test==0)Require(wrong<sum[0]*.51&&wrong>sum[0]*.49,"negative control should halve normal mirror");
            csv<<names[test]<<','<<records.size()<<','<<hits<<','<<rays<<",0";
            for(double v:sum)csv<<','<<(hits?v/hits:0);csv<<','<<(hits?wrong/hits:0)<<','<<caseError<<'\n';
            std::cout<<names[test]<<" paths="<<records.size()<<" hits="<<hits<<" rays="<<rays<<" max_error="<<caseError<<'\n';
            totalRays+=rays;maxError=std::max(maxError,caseError);
        }
        csv.flush();Require(bool(csv),"summary write failed");Require(c.CheckDebug()==0,"D3D validation");
        std::cout<<std::setprecision(12)<<"Mirror PASS TraceRay="<<totalRays<<" max_error="<<maxError<<'\n';
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';if(SUCCEEDED(com))CoUninitialize();return 1;}
    CoUninitialize();return 0;
}
