#include "wavefront.cuh"
#include "path_checks.h"
using namespace cuda_pt;
__global__ void CompactFixture(uint32_t* output,uint32_t* count,uint32_t* errors,unsigned size,unsigned capacity,unsigned mode){
    unsigned i=blockIdx.x*blockDim.x+threadIdx.x;if(i>=size)return;
    bool chosen=mode==0?false:mode==1?true:mode==2?(i%2==0):(i%37==5);
    auto slot=ReserveQueue(chosen,count);if(slot==Invalid)return;
    if(slot>=capacity){atomicAdd(errors,1u);return;}output[slot]=i;
}
void VerifyCompaction(){
    // 解析整数测试不涉及渲染：保证无洞、无重复、无丢失；跨warp顺序不要求稳定。
    unsigned cases=0;for(unsigned size:{1u,31u,32u,33u,129u})for(unsigned mode=0;mode<4;++mode){
        DeviceBuffer<uint32_t> output(size),counter(1),errors(1);CheckCuda(cudaMemset(counter.pointer,0,4),"fixture count reset");CheckCuda(cudaMemset(errors.pointer,0,4),"fixture errors reset");
        CompactFixture<<<(size+63)/64,64>>>(output.pointer,counter.pointer,errors.pointer,size,size,mode);CheckCuda(cudaGetLastError(),"compact fixture launch");CheckCuda(cudaDeviceSynchronize(),"compact fixture completed");
        std::vector<unsigned> expected;for(unsigned i=0;i<size;++i)if(mode==1||(mode==2&&i%2==0)||(mode==3&&i%37==5))expected.push_back(i);
        auto actual=output.Download();unsigned count=counter.Download()[0];Require(count==expected.size()&&errors.Download()[0]==0,"compaction count/errors");actual.resize(count);std::sort(actual.begin(),actual.end());Require(actual==expected,"compaction exact selected set");++cases;
    }
    DeviceBuffer<uint32_t> output(1),counter(1),errors(1);CheckCuda(cudaMemset(counter.pointer,0,4),"overflow count");CheckCuda(cudaMemset(errors.pointer,0,4),"overflow errors");
    CompactFixture<<<3,64>>>(output.pointer,counter.pointer,errors.pointer,129,1,1);CheckCuda(cudaGetLastError(),"overflow fixture launch");CheckCuda(cudaDeviceSynchronize(),"overflow fixture completed");
    Require(counter.Download()[0]==129&&errors.Download()[0]==128,"overflow must report instead of writing past capacity");
    std::cout<<"COMPACTION "<<cases<<" exact set cases + guarded overflow PASS\n";
}
void ValidateWaveCounts(const WaveRendered& w,const RenderConfig& c){
    auto sum=Sum(w.image.pixels);Require(w.counts.rays[0]==uint64_t(c.width)*c.height*c.spp,"wave initial count");uint64_t shadows=0;
    for(unsigned depth=0;depth<17;++depth){Require(w.counts.rays[depth]==sum.active[depth],"queue count vs per-path depth");shadows+=w.counts.shadows[depth];
        Require(w.counts.rays[depth+1]<=w.counts.rays[depth]&&w.counts.shadows[depth]<=w.counts.rays[depth],"queue capacity/count monotonic");}
    Require(shadows==sum.shadows&&w.counts.rays[c.maxScatter+1]==0,"shadow accounting / final queue must be empty");
}
struct PairResult {Rendered mega;WaveRendered wave;};
PairResult VerifyPair(const std::string& name,const Scene& scene,const RenderConfig& cfg,bool cpu,std::ofstream& csv,std::ofstream& queueCsv,const std::filesystem::path& out){
    auto b=BuildBvh(scene);ValidateBvh(scene,b);auto l=BuildPathLights(scene);DeviceScene gpu(scene,b,l);
    auto mega=RenderGpu(gpu,cfg);auto wave=RenderWavefront(gpu,cfg);ValidateWaveCounts(wave,cfg);
    double difference=Compare(wave.image.pixels,mega.pixels);Require(difference<2e-4,"Wavefront/Megakernel image mismatch");
    double cpuError=-1;if(cpu){auto reference=RenderCpu(scene,b,l,cfg);Sum(reference);cpuError=Compare(wave.image.pixels,reference);Require(cpuError<2e-4,"Wavefront/CPU double mismatch");}
    auto sum=Sum(wave.image.pixels);csv<<name<<','<<cfg.width<<','<<cfg.height<<','<<cfg.spp<<','<<cfg.maxScatter<<','<<cfg.nee<<','<<cfg.rr<<','<<mega.milliseconds<<','<<wave.image.milliseconds<<','<<wave.workspaceBytes<<','<<wave.launches<<','<<sum.rays<<','<<sum.shadows<<','<<difference<<','<<cpuError<<'\n';csv.flush();
    for(unsigned d=0;d<=cfg.maxScatter;++d)queueCsv<<name<<','<<d<<','<<wave.counts.rays[d]<<','<<wave.counts.shadows[d]<<','<<wave.counts.rays[d+1]<<'\n';queueCsv.flush();
    WriteImage(out/(name+"-mega"),mega.pixels,cfg);WriteImage(out/(name+"-wave"),wave.image.pixels,cfg);
    std::cout<<name<<" PASS mega/wave ms="<<mega.milliseconds<<'/'<<wave.image.milliseconds<<" error="<<difference<<" CPU="<<cpuError<<" queries="<<sum.rays+sum.shadows<<" launches="<<wave.launches<<" workspace="<<wave.workspaceBytes<<'\n'<<std::flush;
    return {std::move(mega),std::move(wave)};
}
template<class F> void WriteAttributes(std::ofstream& out,const char* name,F kernel){cudaFuncAttributes a{};CheckCuda(cudaFuncGetAttributes(&a,kernel),"wave attributes");out<<name<<','<<a.numRegs<<','<<a.localSizeBytes<<','<<a.sharedSizeBytes<<'\n';}
int main(int argc,char** argv){
    if(argc!=4){std::cerr<<"wavefront_verify gallery.meshbin output full|quick\n";return 2;}
    try{
        bool quick=std::string(argv[3])=="quick";Require(quick||std::string(argv[3])=="full","mode");std::filesystem::path out=argv[2];std::filesystem::create_directories(out);
        CheckCuda(cudaSetDevice(0),"device");cudaDeviceProp prop{};CheckCuda(cudaGetDeviceProperties(&prop,0),"device properties");Require(prop.major==12&&prop.minor==0,"sm_120 expected");
        std::ofstream csv(out/"wavefront.csv"),queues(out/"queues.csv"),attributes(out/"attributes.csv");csv<<std::setprecision(12)<<"case,width,height,spp,K,NEE,RR,mega_ms,wave_ms,workspace_bytes,wave_launches,path_rays,shadow_rays,max_mega_difference,max_cpu_error\n";
        queues<<"case,depth,current_rays,shadows,next_rays\n";attributes<<"kernel,registers,local_bytes,static_shared\n";
        WriteAttributes(attributes,"Megakernel",Megakernel);WriteAttributes(attributes,"WaveGenerate",WaveGenerate);WriteAttributes(attributes,"WaveIntersect",WaveIntersect);WriteAttributes(attributes,"WaveShade",WaveShade);WriteAttributes(attributes,"WaveShadow",WaveShadow);WriteAttributes(attributes,"WaveResolve",WaveResolve);
        VerifyCompaction();Scene room=Cornell();RenderConfig cfg;Camera(cfg,{0,2,8},{0,1.8f,-.3f});cfg.tanHalfFov=.36f;
        if(quick){cfg.width=13;cfg.height=9;cfg.spp=4;}
        for(unsigned mode=0;mode<5;++mode){auto c=cfg;c.maxScatter=mode==0?0:mode==1?1:4;c.nee=mode!=4;c.rr=mode==3;
            VerifyPair(mode==0?"K0":mode==1?"K1":mode==2?"K4-MIS":mode==3?"K4-RR":"K4-BSDF",room,c,true,csv,queues,out);}
        auto b=BuildBvh(room);auto l=BuildPathLights(room);DeviceScene gpu(room,b,l);auto normal=RenderWavefront(gpu,cfg);
        for(unsigned block:{64u,128u,256u}){auto changed=RenderWavefront(gpu,cfg,block,true);ValidateWaveCounts(changed,cfg);Require(Compare(changed.image.pixels,normal.image.pixels)==0,"reverse input / block / nondeterministic queue order must preserve output");}
        std::cout<<"REORDER initial reverse + blocks64/128/256 bit-exact RGB PASS\n";
        auto one=cfg;one.width=one.height=one.spp=1;one.maxScatter=16;one.rr=0;VerifyPair("single-K16",room,one,true,csv,queues,out);
        auto tail=cfg;tail.width=7;tail.height=5;tail.spp=3;tail.sampleOffset=19;tail.seed=29;VerifyPair("odd-offset",room,tail,true,csv,queues,out);
        Scene empty;VerifyPair("empty-scene",empty,tail,true,csv,queues,out);
        auto emission=EmissionAnchor();auto e=tail;Camera(e,{0,0,4},{0,0,0});auto anchor=VerifyPair("emission",emission,e,true,csv,queues,out);
        for(auto& p:anchor.wave.image.pixels)Require(p.radiance.x==3&&p.radiance.y==2&&p.radiance.z==1,"wave analytic emitter");
        auto first=cfg,second=cfg;first.spp=cfg.spp/2;second.spp=cfg.spp-first.spp;second.sampleOffset=first.spp;
        auto a=RenderWavefront(gpu,first),c=RenderWavefront(gpu,second);auto combined=a.image.pixels;for(size_t i=0;i<combined.size();++i)combined[i].radiance=(a.image.pixels[i].radiance*float(first.spp)+c.image.pixels[i].radiance*float(second.spp))*(1.f/cfg.spp);
        double split=Compare(combined,normal.image.pixels,false);Require(split<2e-6,"wave continuous sampleOffset split");std::cout<<"SPLIT samples PASS error="<<split<<'\n';
        unsigned rejected=0;try{auto tooLarge=cfg;tooLarge.width=tooLarge.height=2048;tooLarge.spp=2;RenderWavefront(gpu,tooLarge);}catch(...){++rejected;}
        Require(rejected==1,"wave capacity guard before allocation");
        if(!quick){auto large=cfg;large.width=144;large.height=96;large.spp=128;large.maxScatter=8;VerifyPair("cornell",room,large,false,csv,queues,out);
            auto gallery=LoadScene(argv[1]);large.width=192;large.height=96;large.spp=32;large.maxScatter=6;large.tanHalfFov=.31529879f;Camera(large,{0,3.8f,15},{0,1.7f,0});VerifyPair("gallery",gallery,large,false,csv,queues,out);}
        Require(csv&&queues&&attributes,"report output");std::cout<<"WAVEFRONT VERIFY PASS\n";return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
