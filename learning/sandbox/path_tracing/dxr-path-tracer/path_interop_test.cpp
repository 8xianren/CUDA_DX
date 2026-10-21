#include "path_guide_validation.h"
#include "energy_lut.h"
#include <iomanip>
int main(int argc,char** argv){
    if(argc!=6){std::cerr<<"path_interop_test scene.gltf shader-directory energy.bin output full|quick\n";return 2;}
    HRESULT com=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    try{
        Check(com,"COM");const std::filesystem::path shaders=argv[2],out=argv[4];std::filesystem::create_directories(out);
        bool quick=std::string(argv[5])=="quick";Require(quick||std::string(argv[5])=="full","mode must be full/quick");
        std::ofstream report(out/"interop.csv");report<<std::setprecision(12)<<"case,width,height,spp,generation,ready,done,stamp,allocation_bytes,cuda_ms,rays,depth_error\n";
        auto cpu=LoadCpuScene(argv[1]);UploadContext c;auto gpu=UploadScene(c,cpu);auto blases=BuildMeshBlases(c,gpu);
        c.SubmitWait();gpu.staging.clear();for(auto& b:blases)b.scratch.Reset();
        auto frame=BuildInstanceFrame(c,cpu,gpu,blases,false);auto iors=TeachingIors(cpu);auto bindings=PreparePbrBindings(c,cpu,gpu,&iors);
        auto energy=pbr_energy::Load(argv[3]);bindings.energy=InstanceUpload(c,energy.data.data(),energy.data.size()*sizeof(float));
        PathConfig cfg;cfg.width=96;cfg.height=48;cfg.flags=3;SetPathCamera(cfg,Vector(cfg.eye),{0,1.7,0});
        auto lights=MakePathLights(cpu,WorldTriangles(cpu),cfg);PathHistory history(c,shaders/"path.dxil",shaders/"accumulate.dxil");
        auto record=[&](UINT samples,bool reset=false){cfg.spp=samples;history.Record(bindings,gpu,frame,cfg,lights,0,0,reset);};
        auto save=[&](const char* name,const InteropResult& result,bool copy){double error=ValidatePacket(result,copy);uint64_t rays=0;
            for(auto& p:result.source)rays+=p.value.events[0];
            report<<name<<','<<cfg.width<<','<<cfg.height<<','<<history.Count()<<','<<history.Generation()<<','<<result.ready<<','<<result.done<<','<<result.stamp<<','<<result.allocationBytes<<','<<result.consumerMilliseconds<<','<<rays<<','<<error<<'\n';report.flush();
            SavePacket(out,name,result,cfg.width,cfg.height);std::cout<<name<<" PASS samples="<<history.Count()<<" fence="<<result.ready<<"->"<<result.done<<" CUDA ms="<<result.consumerMilliseconds<<'\n'<<std::flush;};
        {
            PathInterop interop(c,cfg.width,cfg.height,shaders/"pack.dxil");
            record(2);record(5);record(6);auto partition=interop.Run(history);save("partition",partition,true);
            double cpuError=ValidateGuidesCpu(cpu,cfg,partition.source);
            std::cout<<"CPU 64x13 primary guides PASS normalized_error="<<cpuError<<'\n';
            // 独立一次13spp输出对照不等长批次；检查guide均值与首样本ID各自按自己的规则保留。
            PathConfig whole=cfg;whole.spp=13;whole.sampleOffset=0;auto bytes=PackPathConfig(whole,lights);
            auto raw=DispatchMaterialBuffer(c,bindings,gpu,frame,bytes.data(),bytes.size(),cfg.width,cfg.height,partition.source.size()*sizeof(PathPixel),shaders/"path.dxil");
            double maximum=0;for(size_t i=0;i<partition.source.size();++i){PathPixel p;memcpy(&p,raw.data()+i*sizeof(p),sizeof(p));auto& q=partition.source[i].value;
                for(unsigned k=0;k<4;++k){maximum=std::max({maximum,RelativeDifference(q.radiance[k],p.radiance[k]),RelativeDifference(q.albedo[k],p.albedo[k]),RelativeDifference(q.normal[k],p.normal[k])});}
                Require(memcmp(q.position,p.position,16)==0&&memcmp(q.events,p.events,48)==0,"partition counters/first position mismatch");}
            Require(maximum<2e-5,"guide partition tolerance");std::cout<<"guide partition normalized_error="<<maximum<<'\n';
            // flags只增加特征记录，不改变随机数或能量积分。对照关闭guides的同一组13样本。
            whole.flags=1;bytes=PackPathConfig(whole,lights);
            auto plain=DispatchMaterialBuffer(c,bindings,gpu,frame,bytes.data(),bytes.size(),cfg.width,cfg.height,partition.source.size()*sizeof(PathPixel),shaders/"path.dxil");
            for(size_t i=0;i<partition.source.size();++i)Require(memcmp(raw.data()+i*sizeof(PathPixel),plain.data()+i*sizeof(PathPixel),16)==0,"guide mode changed radiance");
            auto again=interop.Run(history);save("repeat",again,true);Require(memcmp(partition.source.data(),again.source.data(),again.source.size()*128)==0,"consumer modified history");
            SetPathCamera(cfg,{1,3.8,15},{1,1.7,0});record(3);auto camera=interop.Run(history);save("camera-reset",camera,true);
            Require(history.Generation()==2&&history.Count()==3,"camera reset metadata");
        } // 已完成末尾Fence，允许释放CUDA映射和D3D资源。
        cfg.width=95;cfg.height=49;record(7);
        {
            PathInterop odd(c,cfg.width,cfg.height,shaders/"pack.dxil");auto result=odd.Run(history);save("odd-resize",result,true);
            Require(history.Generation()==3&&history.Count()==7,"resize reset metadata");
        }
        cfg.width=192;cfg.height=96;SetPathCamera(cfg,{0,3.8,15},{0,1.7,0});record(32);
        {
            PathInterop interop(c,cfg.width,cfg.height,shaders/"pack.dxil");
            // 先构建/commit消费者，再提交生产者，不把库初始化的内部分配放在外部等待之后。
            auto guided=MakeOidnConsumer(interop.Device(),interop.Stream(),interop.Pointer(),cfg.width,cfg.height,true);
            auto colorOnly=MakeOidnConsumer(interop.Device(),interop.Stream(),interop.Pointer(),cfg.width,cfg.height,false);
            auto a=interop.Run(history,guided.get());save("oidn-guides",a,false);
            auto b=interop.Run(history,colorOnly.get());save("oidn-color-only",b,false);
            Require(memcmp(a.source.data(),b.source.data(),a.source.size()*128)==0,"OIDN changed physical history");
            double change=0;for(size_t i=0;i<a.source.size();++i)change+=std::abs(a.packet[4*a.source.size()+i].x-a.packet[i].x);
            Require(change>1e-3,"OIDN output unexpectedly identical to input");
            // 同实例重复执行，检查生命周期和持续递增的交接值；不将第一次初始化时间当稳态性能。
            auto repeat=interop.Run(history,guided.get());save("oidn-repeat",repeat,false);
            double difference=0;for(size_t i=0;i<a.source.size();++i)for(unsigned k=0;k<3;++k)
                difference=std::max(difference,RelativeDifference((&a.packet[4*a.source.size()+i].x)[k],(&repeat.packet[4*a.source.size()+i].x)[k]));
            Require(difference<1e-5,"OIDN repeat mismatch");std::cout<<"OIDN repeat normalized_error="<<difference<<'\n';
            if(!quick){
                // 参考改变seed，避免复用32spp的样本。分组提交避免Windows超时，不以降噪输出作真值。
                cfg.seed=73;for(unsigned batch=0;batch<32;++batch){record(32);if(batch%4==3)history.Flush();}
                auto reference=interop.Run(history);save("reference1024",reference,true);
            }
        } // 消费者先析构，再释放interop的底层指针；生产场景/AS寿命覆盖全部提交。
        Require(c.CheckDebug()==0,"D3D debug errors");std::cout<<"Debug=0 final Fence="<<c.submitted<<'/'<<c.fence->GetCompletedValue()<<" PASS\n";
        CoUninitialize();return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';if(SUCCEEDED(com))CoUninitialize();return 1;}
}
