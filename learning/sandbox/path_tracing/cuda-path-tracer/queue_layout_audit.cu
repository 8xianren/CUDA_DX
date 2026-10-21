#include "wavefront.cuh"
#include "path_checks.h"
#include <cstddef>
#include <numeric>
using namespace cuda_pt;

// 本程序是诊断执行：每层同步、读回真实队列，不能用它测Wavefront性能。
// 不另写积分器或压缩kernel，继续调用已经验证过的同一组Wavefront阶段。
// 输出uint32 stateId序列供CPU推导地址；地址模型不冒充硬件访存计数。
static_assert(std::is_standard_layout_v<PathState<float>>);
static_assert(sizeof(PathState<float>)==88 && sizeof(ShadowTask<float>)==48);
static_assert(offsetof(PathState<float>,ray)==0 && offsetof(ShadowTask<float>,ray)==0);
static_assert(offsetof(PathRay<float>,origin)==0 && offsetof(PVec<float>,x)==0);

void CaptureQueue(const std::filesystem::path& out,std::ofstream& manifest,const char* kind,
                  unsigned depth,unsigned count,const uint32_t* queue,WaveStorage& storage,
                  const RenderConfig& cfg){
    // 前置：调用者已成功同步生产者stream。只读有效前缀，不读未初始化的尾部。
    // cudaMemcpy(dst,src,bytes,kind)：dst为宿主vector，src为device队列，
    // bytes=count*4，方向DeviceToHost；同步返回后vector可读取，device所有权不变。
    Require(count<=storage.view.capacity,"snapshot queue count exceeds capacity");
    std::vector<uint32_t> ids(count);if(count)CheckCuda(cudaMemcpy(ids.data(),queue,count*sizeof(uint32_t),cudaMemcpyDeviceToHost),"snapshot queue prefix");
    std::vector<unsigned char> seen(storage.view.capacity,0);
    for(auto id:ids){Require(id<storage.view.capacity&&!seen[id],"snapshot invalid/duplicate stateId");seen[id]=1;}
    // 不仅检查count，还检查每项确实是本层有效任务；空队列自然不访问任何状态。
    if(std::string(kind)=="ray"){
        auto states=storage.states.Download();
        for(auto id:ids){const auto& p=states[id];Require(p.alive&&p.depth==depth,"ray queue points to wrong depth/dead path");
            Require(p.pixel==id/cfg.spp&&p.sample==cfg.sampleOffset+id%cfg.spp,"stable sample identity");}
    }else{
        auto tasks=storage.shadows.Download();for(auto id:ids)Require(tasks[id].valid,"shadow queue points to invalid task");
    }
    std::string file=std::string(kind)+"-"+std::to_string(depth)+".u32";
    std::ofstream binary(out/file,std::ios::binary);if(count)binary.write(reinterpret_cast<const char*>(ids.data()),count*sizeof(uint32_t));Require(bool(binary),"snapshot write");
    // 本机Windows x64是小端；每个记录恰为4B，长度由manifest验证。
    manifest<<kind<<','<<depth<<','<<count<<','<<storage.view.capacity<<','
            <<(std::string(kind)=="ray"?sizeof(PathState<float>):sizeof(ShadowTask<float>))<<",0,"<<file<<'\n';
}

int main(int argc,char** argv){
    if(argc!=5){std::cerr<<"queue_layout_audit gallery.meshbin output gallery|empty full|quick\n";return 2;}
    try{
        bool quick=std::string(argv[4])=="quick";Require(quick||std::string(argv[4])=="full","mode");
        bool empty=std::string(argv[3])=="empty";Require(empty||std::string(argv[3])=="gallery","scene");
        CheckCuda(cudaSetDevice(0),"device");cudaDeviceProp prop{};CheckCuda(cudaGetDeviceProperties(&prop,0),"properties");Require(prop.major==12&&prop.minor==0,"sm_120 required");
        Scene scene=empty?Scene{}:LoadScene(argv[1]);RenderConfig cfg;cfg.width=192;cfg.height=96;cfg.spp=32;cfg.maxScatter=6;
        cfg.tanHalfFov=.31529879f;Camera(cfg,{0,3.8f,15},{0,1.7f,0});
        if(quick||empty){cfg.width=13;cfg.height=9;cfg.spp=4;cfg.maxScatter=4;}
        ValidateConfig(cfg);uint64_t n64=uint64_t(cfg.width)*cfg.height*cfg.spp;Require(n64<=4194304,"diagnostic capacity guard");unsigned n=unsigned(n64);
        auto tree=BuildBvh(scene);ValidateBvh(scene,tree);auto lights=BuildPathLights(scene);DeviceScene gpu(scene,tree,lights);
        WaveStorage storage(n);auto w=storage.view;DeviceBuffer<PixelResult> output(cfg.width*cfg.height);CudaStream stream;
        std::filesystem::path out=argv[2];std::filesystem::create_directories(out);
        std::ofstream manifest(out/"queues.csv");manifest<<"kind,depth,count,capacity,aos_stride,field_offset,file\n";
        // cudaMalloc分配基址对齐；只记录模32值验证地址模型假设，不把实际虚拟地址写入讲义。
        Require(reinterpret_cast<uintptr_t>(w.states)%32==0&&reinterpret_cast<uintptr_t>(w.shadows)%32==0,"aligned array bases");
        constexpr unsigned threads=128;unsigned groups=(n+threads-1)/threads;
        CheckCuda(cudaMemsetAsync(w.counts,0,sizeof(WaveCounts),stream.value),"counts reset");
        WaveGenerate<<<groups,threads,0,stream.value>>>(w,cfg,false);CheckCuda(cudaGetLastError(),"generate");
        uint64_t observedRays=0,observedShadows=0;
        for(unsigned d=0;d<=cfg.maxScatter;++d){
            // 诊断快照打断CPU/GPU流水，只保证语义等价；不宣称复现基准中的跨warp入队顺序。
            CheckCuda(cudaStreamSynchronize(stream.value),"ray producer completed");auto counts=storage.counts.Download()[0];Require(counts.errors==0,"queue errors");
            CaptureQueue(out,manifest,"ray",d,counts.rays[d],(d&1)?w.second:w.first,storage,cfg);observedRays+=counts.rays[d];
            WaveIntersect<<<groups,threads,0,stream.value>>>(gpu.view,w,d);CheckCuda(cudaGetLastError(),"intersect");
            WaveShade<<<groups,threads,0,stream.value>>>(gpu.view,cfg,w,d);CheckCuda(cudaGetLastError(),"shade");
            CheckCuda(cudaStreamSynchronize(stream.value),"shade completed");counts=storage.counts.Download()[0];Require(counts.errors==0,"shade queue errors");
            CaptureQueue(out,manifest,"shadow",d,counts.shadows[d],w.shadowQueue,storage,cfg);observedShadows+=counts.shadows[d];
            WaveShadow<<<groups,threads,0,stream.value>>>(gpu.view,w,d);CheckCuda(cudaGetLastError(),"shadow");
        }
        WaveResolve<<<(cfg.width*cfg.height+threads-1)/threads,threads,0,stream.value>>>(w,cfg,output.pointer);CheckCuda(cudaGetLastError(),"resolve");
        CheckCuda(cudaStreamSynchronize(stream.value),"diagnostic render completed");auto actual=output.Download();auto counts=storage.counts.Download()[0];auto total=Sum(actual);
        Require(counts.errors==0&&counts.rays[cfg.maxScatter+1]==0,"final count/errors");
        Require(total.rays==observedRays&&total.shadows==observedShadows,"snapshot count accounting");
        for(unsigned d=0;d<17;++d)Require(total.active[d]==counts.rays[d],"per-depth count accounting");
        auto reference=RenderGpu(gpu,cfg,128,1);Require(Compare(actual,reference.pixels)==0,"snapshot execution must preserve exact output");
        double cpuError=-1;if(quick){auto cpu=RenderCpu(scene,tree,lights,cfg);cpuError=Compare(actual,cpu);Require(cpuError<2e-4,"snapshot CPU reference");}
        WriteImage(out/"snapshot",actual,cfg);
        std::ofstream check(out/"checks.txt");check<<std::setprecision(12)<<"max_mega_difference=0\nmax_cpu_difference="<<cpuError<<"\npath_rays="<<total.rays<<"\nshadow_rays="<<total.shadows<<"\nbase_alignment_mod32=0\n";
        Require(manifest&&check,"audit report");std::cout<<"QUEUE LAYOUT AUDIT PASS scene="<<argv[3]<<" mode="<<argv[4]<<" rays="<<total.rays<<" shadows="<<total.shadows<<" CPU="<<cpuError<<'\n';return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
