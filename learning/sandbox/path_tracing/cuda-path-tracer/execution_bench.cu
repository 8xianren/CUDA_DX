#include "wavefront.cuh"
#include "sample_megakernel.cuh"
#include "path_checks.h"
#include <cuda_profiler_api.h>
#include <chrono>
using namespace cuda_pt;
// Attributes只查询编译资源和理论驻留上限，不执行kernel、不采样硬件计数器。
// numBlocks是宿主输出；blockSize=128，dynamicSMemSize=0。除以设备最大线程数
// 得到理论occupancy；不能把这个值当成实际active warp比例或有用线程比例。
template<class F> void Attributes(std::ofstream& out,const char* name,F kernel,const cudaDeviceProp& device){
    cudaFuncAttributes a{};int blocks=0;CheckCuda(cudaFuncGetAttributes(&a,kernel),"bench attributes");
    CheckCuda(cudaOccupancyMaxActiveBlocksPerMultiprocessor(&blocks,kernel,128,0),"theoretical block occupancy");
    out<<name<<','<<a.numRegs<<','<<a.localSizeBytes<<','<<a.sharedSizeBytes<<','<<blocks<<','<<double(blocks*128)/device.maxThreadsPerMultiProcessor<<'\n';
}
int main(int argc,char** argv){
    if(argc!=6){std::cerr<<"execution_bench gallery.meshbin output cornell|gallery|empty bench|quick|profile all|pixel|sample|wave\n";return 2;}
    try{
        std::string sceneName=argv[3],mode=argv[4],backend=argv[5];Require(mode=="bench"||mode=="quick"||mode=="profile","mode");
        Require(backend=="all"||backend=="pixel"||backend=="sample"||backend=="wave","backend");Require(mode!="profile"||backend!="all","single profile backend");
        std::filesystem::path out=argv[2];std::filesystem::create_directories(out);CheckCuda(cudaSetDevice(0),"device");cudaDeviceProp prop{};CheckCuda(cudaGetDeviceProperties(&prop,0),"properties");Require(prop.major==12&&prop.minor==0,"sm_120 required");
        Scene scene;RenderConfig cfg;Camera(cfg,{0,2,8},{0,1.8f,-.3f});cfg.tanHalfFov=.36f;
        if(sceneName=="cornell"){scene=Cornell();cfg.width=144;cfg.height=96;cfg.spp=128;cfg.maxScatter=8;}
        else if(sceneName=="gallery"){scene=LoadScene(argv[1]);cfg.width=192;cfg.height=96;cfg.spp=32;cfg.maxScatter=6;cfg.tanHalfFov=.31529879f;Camera(cfg,{0,3.8f,15},{0,1.7f,0});}
        else if(sceneName=="empty"){cfg.width=7;cfg.height=5;cfg.spp=3;cfg.maxScatter=4;}
        else Require(false,"scene name");
        if(mode=="quick"){cfg.width=13;cfg.height=9;cfg.spp=4;cfg.maxScatter=4;}
        ValidateConfig(cfg);uint64_t n64=uint64_t(cfg.width)*cfg.height*cfg.spp;Require(n64<=4194304,"benchmark path capacity");unsigned n=unsigned(n64),pixels=cfg.width*cfg.height;
        auto tree=BuildBvh(scene);ValidateBvh(scene,tree);auto lights=BuildPathLights(scene);DeviceScene gpu(scene,tree,lights);
        // 所有分配与上传在计时/采集之前完成；三后端复用同一stream与输出，工作区内容每次由kernel覆盖。
        // 三份工作区同时驻留：这是同进程控制实验，不是每后端单独显存峰值。
        // DeviceScene上传已完成；enqueue只借用指针。所有正常路径都在读回/销毁前
        // 检查stream/event完成；GetLastError检查启动，同步检查异步执行错误。
        DeviceBuffer<PixelResult> samples(n),output(pixels);WaveStorage wave(n);CudaStream stream;CudaEvents events;
        auto enqueue=[&](unsigned which,unsigned threads=128){if(which==0){Megakernel<<<(pixels+threads-1)/threads,threads,0,stream.value>>>(gpu.view,cfg,output.pointer);CheckCuda(cudaGetLastError(),"pixel mega");}
            else if(which==1)EnqueueSampleMega(gpu.view,cfg,samples.pointer,output.pointer,stream.value,threads);
            else EnqueueWavefront(gpu.view,cfg,wave.view,output.pointer,stream.value,threads);};
        const char* names[]{"pixel","sample","wave"};
        std::ofstream checks(out/"checks.csv");checks<<"backend,max_rgb_difference,path_rays,shadow_rays\n";
        enqueue(0);CheckCuda(cudaStreamSynchronize(stream.value),"reference complete");auto reference=output.Download();auto totals=Sum(reference);
        for(unsigned k=0;k<3;++k){enqueue(k);CheckCuda(cudaStreamSynchronize(stream.value),"validation complete");auto value=output.Download();Sum(value);double error=Compare(value,reference);Require(error==0,"three backends must be bit-exact");
            checks<<names[k]<<','<<error<<','<<totals.rays<<','<<totals.shadows<<'\n';WriteImage(out/names[k],value,cfg);}
        // 新样本级控制组也验证非128 block；样本身份和归并顺序应保持，不把偶然队列顺序当成正确性前提。
        for(unsigned block:{64u,256u}){enqueue(1,block);CheckCuda(cudaStreamSynchronize(stream.value),"sample block check");Require(Compare(output.Download(),reference)==0,"sample block determinism");}
        if(mode=="quick"){auto cpu=RenderCpu(scene,tree,lights,cfg);double error=Compare(reference,cpu);Require(error<2e-4,"CPU reference");std::cout<<"CPU max error="<<error<<'\n';}
        std::ofstream attr(out/"attributes.csv");attr<<"kernel,registers,local_bytes,static_shared,theoretical_blocks_per_SM,theoretical_occupancy\n";
        Attributes(attr,"Megakernel",Megakernel,prop);Attributes(attr,"SampleMegakernel",SampleMegakernel,prop);Attributes(attr,"SampleResolve",SampleResolve,prop);
        Attributes(attr,"WaveGenerate",WaveGenerate,prop);Attributes(attr,"WaveIntersect",WaveIntersect,prop);Attributes(attr,"WaveShade",WaveShade,prop);Attributes(attr,"WaveShadow",WaveShadow,prop);Attributes(attr,"WaveResolve",WaveResolve,prop);
        std::ofstream meta(out/"metadata.txt");meta<<"GPU="<<prop.name<<"\nSMs="<<prop.multiProcessorCount<<"\nwidth="<<cfg.width<<"\nheight="<<cfg.height<<"\nspp="<<cfg.spp<<"\nK="<<cfg.maxScatter<<"\npaths="<<n<<"\nsample_workspace_bytes="<<size_t(n)*sizeof(PixelResult)<<"\nwave_workspace_bytes="<<wave.Bytes()<<"\npath_rays="<<totals.rays<<"\nshadow_rays="<<totals.shadows<<'\n';
        std::vector<unsigned> selected;for(unsigned k=0;k<3;++k)if(backend=="all"||backend==names[k])selected.push_back(k);
        for(unsigned r=0;r<3;++r)for(auto k:selected){enqueue(k);CheckCuda(cudaStreamSynchronize(stream.value),"warmup completed");}
        if(mode=="profile"){
            // 仅标记一次稳态提交：Nsight的采集范围不含场景构建、正确性对照、上传、预热或读回。
            // Start/Stop没有参数，也不负责等待GPU；必须先StreamSynchronize再Stop。
            // Start可能触发profiler初始化，其宿主耗时不得计入渲染性能。
            CheckCuda(cudaProfilerStart(),"profiler start");enqueue(selected[0]);CheckCuda(cudaStreamSynchronize(stream.value),"profile work complete");CheckCuda(cudaProfilerStop(),"profiler stop");
            Require(Compare(output.Download(),reference)==0,"profile output");
        }else{
            std::ofstream timing(out/"timings.csv");timing<<std::setprecision(12)<<"backend,round,gpu_ms,cpu_submit_wait_ms\n";
            // 轮换提交顺序，减轻固定先后顺序与频率/热状态的相关性；每后端9次独立事件区间。
            for(unsigned r=0;r<9;++r)for(unsigned j=0;j<selected.size();++j){unsigned k=selected[(j+r)%selected.size()];auto start=std::chrono::steady_clock::now();
                CheckCuda(cudaEventRecord(events.begin,stream.value),"bench begin");enqueue(k);CheckCuda(cudaEventRecord(events.end,stream.value),"bench end");CheckCuda(cudaEventSynchronize(events.end),"bench complete");
                double cpu=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();float ms;CheckCuda(cudaEventElapsedTime(&ms,events.begin,events.end),"bench event elapsed");timing<<names[k]<<','<<r<<','<<ms<<','<<cpu<<'\n';}
            Require(bool(timing),"timing output");
        }
        Require(checks&&attr&&meta,"report output");std::cout<<"EXECUTION "<<sceneName<<' '<<mode<<' '<<backend<<" PASS queries="<<totals.rays+totals.shadows<<'\n';return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
