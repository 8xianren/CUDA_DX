#include "path_history.h"
#include "energy_lut.h"
#include <fstream>
#include <iostream>
#include <iomanip>
#include <limits>

// 本验收沿用真正的glTF/DXR积分器，不用常量颜色代替渲染输入。独立同步接口输出一整批，
// 与GPU持久历史的不同分批方式比较，可同时检验样本编号、加权、计数、首样本特征和重置。
using HistoryImage=std::vector<PathHistoryPixel>;
void CheckImage(const HistoryImage& image,UINT count,UINT generation){
    for(const auto& p:image){
        Require(p.count==count&&p.generation==generation,"GPU history metadata mismatch");
        Require(p.value.errors[0]==0&&p.value.errors[1]==0,"GPU path/state errors");
        for(float v:p.value.radiance)Require(std::isfinite(v)&&v>=0,"nonfinite/negative history");
    }
}
double Compare(const HistoryImage& accumulated,const std::vector<PathPixel>& whole){
    Require(accumulated.size()==whole.size(),"comparison extent");double maximum=0;
    for(size_t i=0;i<whole.size();++i){
        const auto& a=accumulated[i].value;const auto& b=whole[i];
        // radiance包括RGB均值和亮度平方均值。允许不同浮点加法次序，不能要求逐字节相同。
        for(unsigned k=0;k<4;++k){double e=std::abs(double(a.radiance[k])-b.radiance[k])/(1+std::abs(b.radiance[k]));maximum=std::max(maximum,e);}
        Require(memcmp(a.albedo,b.albedo,16)==0&&memcmp(a.normal,b.normal,16)==0&&memcmp(a.position,b.position,16)==0,"first primary feature changed");
        Require(memcmp(a.events,b.events,16)==0&&memcmp(a.errors,b.errors,16)==0&&memcmp(a.ends,b.ends,16)==0,"path counters changed with partition");
    }
    Require(maximum<2e-5,"GPU accumulation vs whole batch tolerance");return maximum;
}
double ImageDifference(const HistoryImage& a,const std::vector<PathPixel>& b){
    Require(a.size()==b.size(),"difference extent");double sum=0;
    for(size_t i=0;i<a.size();++i)for(unsigned k=0;k<3;++k){double d=a[i].value.radiance[k]-b[i].radiance[k];sum+=d*d;}
    return sum/(3*a.size());
}
void Save(const std::filesystem::path& folder,const std::string& name,const PathConfig& cfg,const HistoryImage& pixels){
    std::ofstream f(folder/(name+".pfm"),std::ios::binary);f<<"PF\n"<<cfg.width<<' '<<cfg.height<<"\n-1.0\n";
    for(int y=int(cfg.height)-1;y>=0;--y)for(UINT x=0;x<cfg.width;++x)
        f.write(reinterpret_cast<const char*>(pixels[size_t(y)*cfg.width+x].value.radiance),12);
    Require(bool(f),"PFM write failed");
}
int main(int argc,char** argv){
    if(argc!=6){std::cerr<<"path_history_test scene.gltf path.dxil accumulate.dxil energy.bin out\n";return 2;}
    HRESULT com=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    try{
        Check(com,"COM");std::filesystem::path out=argv[5];std::filesystem::create_directories(out);
        std::ofstream report(out/"history.csv");report<<std::setprecision(12)<<"case,count,generation,normalized_error,old_vs_new_mse,fence_submissions\n";
        auto cpu=LoadCpuScene(argv[1]);UploadContext c;auto gpu=UploadScene(c,cpu);auto blases=BuildMeshBlases(c,gpu);
        c.SubmitWait();gpu.staging.clear();for(auto& b:blases)b.scratch.Reset();
        auto frame=BuildInstanceFrame(c,cpu,gpu,blases,false);auto iors=TeachingIors(cpu);
        auto bindings=PreparePbrBindings(c,cpu,gpu,&iors);auto table=pbr_energy::Load(argv[4]);
        bindings.energy=InstanceUpload(c,table.data.data(),table.data.size()*sizeof(float));
        PathConfig cfg;cfg.width=96;cfg.height=48;cfg.flags=1;SetPathCamera(cfg,Vector(cfg.eye),{0,1.7,0});
        auto lights=MakePathLights(cpu,WorldTriangles(cpu),cfg);uint64_t sceneRevision=0,materialRevision=0;
        PathHistory history(c,argv[2],argv[3]);
        auto whole=[&](UINT samples){
            PathConfig q=cfg;q.spp=samples;q.sampleOffset=0;auto configuration=PackPathConfig(q,lights);
            auto raw=DispatchMaterialBuffer(c,bindings,gpu,frame,configuration.data(),configuration.size(),q.width,q.height,
                size_t(q.width)*q.height*sizeof(PathPixel),argv[2]);
            std::vector<PathPixel> pixels(size_t(q.width)*q.height);memcpy(pixels.data(),raw.data(),raw.size());return pixels;
        };
        auto record=[&](UINT samples,bool reset=false){cfg.spp=samples;return history.Record(bindings,gpu,frame,cfg,lights,sceneRevision,materialRevision,reset);};

        // 2+5+6不是等长批次；三批之间不提交、不等Fence、不读回。只在末尾验收一次。
        auto before=c.submitted;Require(record(2),"initial reset missing");Require(!record(5)&&!record(6),"batch size must not invalidate history");
        Require(c.submitted==before,"record unexpectedly submitted/waited");
        auto image=history.Readback();CheckImage(image,13,1);
        Require(c.submitted==before+1,"three batches must share one submit");
        auto reference=whole(13);double error=Compare(image,reference);
        report<<"partition_2_5_6,13,1,"<<error<<",0,1\n";
        std::cout<<"partition 2+5+6 PASS error="<<error<<" one submission\n";
        // 实际改变目标后，旧缓冲必须等同于全新历史。强制比较“改变前”图像确保测试不是空改动。
        auto checkReset=[&](const char* name,bool sameExtent){
            const auto old=image;UINT oldGeneration=history.Generation();
            Require(record(3),"target edit failed to reset");Require(!record(10),"unchanged target unexpectedly reset");
            image=history.Readback();CheckImage(image,13,oldGeneration+1);auto fresh=whole(13);
            const double e=Compare(image,fresh),difference=sameExtent?ImageDifference(old,fresh):0;
            if(sameExtent)Require(difference>1e-6,"reset test did not change actual rendered image");
            report<<name<<",13,"<<history.Generation()<<','<<e<<','<<difference<<",1\n";
            Save(out,name,cfg,image);std::cout<<name<<" PASS error="<<e<<" target difference="<<difference<<'\n';
        };
        SetPathCamera(cfg,{1.2,3.8,15},{1.2,1.7,0});checkReset("camera",true);
        cfg.width=95;cfg.height=49;checkReset("resize",false);
        bool changed=false;for(auto& m:cpu.materialAssets.materials)if(m.name=="floor"){m.baseColor={.05f,.8f,.12f,1};changed=true;}
        Require(changed,"floor fixture missing");auto energy=bindings.energy;
        // 前次whole()已等待Fence，所以替换旧材质表/sampler不会释放GPU仍在读取的资源。
        bindings=PreparePbrBindings(c,cpu,gpu,&iors);bindings.energy=energy;++materialRevision;checkReset("material",true);
        changed=false;for(auto& n:cpu.nodes)if(n.name=="row1_r0.2"){n.local.m[3]+=.8f;n.local.m[7]+=.4f;changed=true;}
        Require(changed,"sphere fixture missing");UpdateWorldMatrices(cpu);
        frame=BuildInstanceFrame(c,cpu,gpu,blases,false);lights=MakePathLights(cpu,WorldTriangles(cpu),cfg);
        ++sceneRevision;checkReset("scene",true);
        cfg.lightScale=3;checkReset("light",true);
        cfg.seed=91;checkReset("seed",true);

        // 向旧GPU历史注入NaN和错误计数。正确重置分支完全覆盖，old*0+new会失败。
        std::vector<PathHistoryPixel> poison(image.size());
        for(auto& p:poison){for(float& v:p.value.radiance)v=std::numeric_limits<float>::quiet_NaN();p.value.errors[0]=999;p.count=999;p.generation=999;}
        auto poisonUpload=InstanceUpload(c,poison.data(),poison.size()*sizeof(PathHistoryPixel));
        Transition(c,history.Resource(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_COPY_DEST);
        c.list->CopyBufferRegion(history.Resource(),0,poisonUpload.Get(),0,poison.size()*sizeof(PathHistoryPixel));
        Transition(c,history.Resource(),D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        UINT previousGeneration=history.Generation();Require(record(13,true),"manual reset missing");
        image=history.Readback();CheckImage(image,13,previousGeneration+1);reference=whole(13);error=Compare(image,reference);
        report<<"poison_reset,13,"<<history.Generation()<<','<<error<<",0,1\n";
        std::cout<<"NaN poisoned history reset PASS error="<<error<<'\n';

        // Resize不能释放尚未提交的旧资源。拒绝后原命令仍可正常Flush，不把异常当成功提交。
        Require(!record(1),"continuation reset");auto wrong=cfg;wrong.width++;
        bool rejected=false;try{history.Record(bindings,gpu,frame,wrong,lights,sceneRevision,materialRevision);}catch(const std::runtime_error&){rejected=true;}
        Require(rejected,"pending resize must be rejected");history.Flush();
        image=history.Readback();CheckImage(image,14,history.Generation());
        std::cout<<"pending resize rejection PASS\n";

        // 收敛使用原始场景、新独立随机seed的1024spp参考；不会使用Tone Mapping后的PNG计算MSE。
        cpu=LoadCpuScene(argv[1]);frame=BuildInstanceFrame(c,cpu,gpu,blases,false);
        bindings=PreparePbrBindings(c,cpu,gpu,&iors);bindings.energy=energy;
        cfg=PathConfig{};cfg.width=128;cfg.height=64;cfg.seed=0;SetPathCamera(cfg,Vector(cfg.eye),{0,1.7,0});
        lights=MakePathLights(cpu,WorldTriangles(cpu),cfg);++sceneRevision;++materialRevision;
        std::ofstream convergence(out/"convergence.csv");convergence<<"spp,rays,delta,transmission,count_min,count_max\n";
        auto extend=[&](UINT target){
            // 每128spp提交并等待一次以限制命令组长度；历史始终留在GPU，Flush不复制图像到CPU。
            unsigned pending=0;
            while(history.Count()<target){UINT n=std::min(32u,target-history.Count());record(n);pending+=n;if(pending>=128){history.Flush();pending=0;}}
        };
        Require(record(1),"convergence initial reset");
        for(UINT samples:{1u,4u,16u,64u,256u}){
            extend(samples);image=history.Readback();CheckImage(image,samples,history.Generation());
            Save(out,"spp"+std::to_string(samples),cfg,image);uint64_t rays=0,delta=0,transmission=0;
            for(const auto& p:image){rays+=p.value.events[0];delta+=p.value.errors[2];transmission+=p.value.errors[3];}
            convergence<<samples<<','<<rays<<','<<delta<<','<<transmission<<','<<samples<<','<<samples<<'\n';
            std::cout<<"convergence spp="<<samples<<" rays="<<rays<<'\n'<<std::flush;
        }
        cfg.seed=73;Require(record(1),"independent reference seed reset");extend(1024);
        image=history.Readback();CheckImage(image,1024,history.Generation());Save(out,"reference1024",cfg,image);
        Require(c.CheckDebug()==0,"D3D validation error");Require(report&&convergence,"report write failed");
        std::cout<<"GPU HISTORY PASS: partition, camera, resize, material, scene, light, seed, poison, pending resize, convergence outputs\n";
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';if(SUCCEEDED(com))CoUninitialize();return 1;}
    CoUninitialize();return 0;
}
