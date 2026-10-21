#pragma once
#include "path_gpu.cuh"
namespace cuda_pt {
// 深度d读rayCounts[d]，着色写rayCounts[d+1]/shadowCounts[d]。所有计数一次清零，
// 同一stream内生产者kernel完成后消费者才读；原子预留只分配槽位，并不提前发布完成事件。
struct WaveCounts {uint32_t rays[18]{},shadows[17]{},errors=0;};
struct WaveView {
    PathState<float>* states;PathStats* stats;PathHit<float>* hits;ShadowTask<float>* shadows;
    uint32_t* first;uint32_t* second;uint32_t* shadowQueue;WaveCounts* counts;uint32_t capacity;
};
__device__ inline uint32_t ReserveQueue(bool selected,uint32_t* counter){
    // 当前参与子组通过ballot统一投票：每个非空子组只原子预留一次连续区间。
    // 独立线程调度可能把一个warp分成多个参与子组；正确性不依赖“恰好一次/完整32lane”。
    unsigned participating=__activemask(),chosen=__ballot_sync(participating,selected);
    if(chosen==0)return Invalid;
    unsigned lane=threadIdx.x&31,leader=__ffs(chosen)-1,base=0;
    if(lane==leader)base=atomicAdd(counter,__popc(chosen));
    base=__shfl_sync(participating,base,leader);
    unsigned earlier=chosen&((1u<<lane)-1u);
    return selected?base+__popc(earlier):Invalid;
}
__global__ void WaveGenerate(WaveView w,RenderConfig cfg,bool reverse){
    unsigned id=blockIdx.x*blockDim.x+threadIdx.x;if(id>=w.capacity)return;
    unsigned pixel=id/cfg.spp,sample=cfg.sampleOffset+id%cfg.spp;
    w.states[id]=StartPath<float>(cfg,pixel,sample);w.stats[id]={};
    // 队列顺序可变，但stateId=pixel*spp+localSample保持不变，随机身份从state里读取。
    w.first[id]=reverse?w.capacity-1-id:id;if(id==0)w.counts->rays[0]=w.capacity;
}
__global__ void WaveIntersect(PathView scene,WaveView w,unsigned depth){
    unsigned slot=blockIdx.x*blockDim.x+threadIdx.x;if(slot>=w.capacity||slot>=w.counts->rays[depth])return;
    auto queue=(depth&1)?w.second:w.first;unsigned id=queue[slot];
    if(id>=w.capacity){atomicAdd(&w.counts->errors,1u);return;}
    auto& stats=w.stats[id];auto& path=w.states[id];
    if(!path.alive||path.depth!=depth){++stats.errors;return;}
    ++stats.rays;++stats.active[depth];w.hits[slot]=DeviceTrace{scene}(path.ray,stats);
}
__global__ void WaveShade(PathView scene,RenderConfig cfg,WaveView w,unsigned depth){
    unsigned slot=blockIdx.x*blockDim.x+threadIdx.x;if(slot>=w.capacity||slot>=w.counts->rays[depth])return;
    auto current=(depth&1)?w.second:w.first;auto next=(depth&1)?w.first:w.second;unsigned id=current[slot];
    if(id>=w.capacity){atomicAdd(&w.counts->errors,1u);return;}
    auto path=w.states[id];auto stats=w.stats[id];auto shadow=ShadePath(scene,cfg,path,w.hits[slot],stats);
    w.states[id]=path;w.stats[id]=stats;
    // 一个输入最多生成一个继续路径和一个阴影任务，故两条队列各自capacity=N足够。
    // 两种有效谓词独立：RR终止后的shadow.valid仍可能为true，不能套用path.alive。
    unsigned raySlot=ReserveQueue(path.alive,&w.counts->rays[depth+1]);
    if(raySlot!=Invalid){if(raySlot>=w.capacity){atomicAdd(&w.counts->errors,1u);}else next[raySlot]=id;}
    unsigned shadowSlot=ReserveQueue(shadow.valid,&w.counts->shadows[depth]);
    if(shadowSlot!=Invalid){if(shadowSlot>=w.capacity){atomicAdd(&w.counts->errors,1u);}else{w.shadows[id]=shadow;w.shadowQueue[shadowSlot]=id;}}
}
__global__ void WaveShadow(PathView scene,WaveView w,unsigned depth){
    unsigned slot=blockIdx.x*blockDim.x+threadIdx.x;if(slot>=w.capacity||slot>=w.counts->shadows[depth])return;
    unsigned id=w.shadowQueue[slot];if(id>=w.capacity){atomicAdd(&w.counts->errors,1u);return;}
    auto shadow=w.shadows[id];auto& stats=w.stats[id];++stats.shadows;
    bool visible=DeviceTrace{scene}(shadow.ray,stats).id==Invalid;
    stats.hash=PathHash(stats.hash^(visible?0xabcd1234u:0x1234abcdu));
    if(visible)w.states[id].radiance=w.states[id].radiance+shadow.contribution;
}
__global__ void WaveResolve(WaveView w,RenderConfig cfg,PixelResult* output){
    unsigned pixel=blockIdx.x*blockDim.x+threadIdx.x;if(pixel>=cfg.width*cfg.height)return;
    PixelResult result{};PVec<float> sum{};
    // 一个线程固定按sample顺序归并，保持Megakernel的浮点加法顺序，无跨样本atomicAdd(float)。
    for(unsigned sample=0;sample<cfg.spp;++sample){unsigned id=pixel*cfg.spp+sample;auto& path=w.states[id];auto stats=w.stats[id];
        if(path.alive||!PFinite(path.radiance))++stats.errors;sum=sum+path.radiance;MergePathStats(result.stats,stats,cfg.sampleOffset+sample);}
    result.radiance=FV(sum*(1.f/cfg.spp));output[pixel]=result;
}
struct WaveStorage {
    DeviceBuffer<PathState<float>> states;DeviceBuffer<PathStats> stats;DeviceBuffer<PathHit<float>> hits;
    DeviceBuffer<ShadowTask<float>> shadows;DeviceBuffer<uint32_t> first,second,shadowQueue;
    DeviceBuffer<WaveCounts> counts;WaveView view;
    explicit WaveStorage(unsigned n):states(n),stats(n),hits(n),shadows(n),first(n),second(n),shadowQueue(n),counts(1){
        view={states.pointer,stats.pointer,hits.pointer,shadows.pointer,first.pointer,second.pointer,shadowQueue.pointer,counts.pointer,n};
    }
    size_t Bytes() const{return states.count*(sizeof(PathState<float>)+sizeof(PathStats)+sizeof(PathHit<float>)+sizeof(ShadowTask<float>)+3*sizeof(uint32_t))+sizeof(WaveCounts);}
};
struct WaveRendered {Rendered image;WaveCounts counts;size_t workspaceBytes=0;unsigned launches=0;};
inline void EnqueueWavefront(PathView scene,const RenderConfig& cfg,WaveView w,PixelResult* output,cudaStream_t stream,unsigned threads=128,bool reverse=false){
    // 只录入GPU工作，不分配/读回/等待；正确性验收、独立计时和Nsight共用同一个提交入口。
    unsigned groups=(w.capacity+threads-1)/threads;
    CheckCuda(cudaMemsetAsync(w.counts,0,sizeof(WaveCounts),stream),"wave reset counts");
    WaveGenerate<<<groups,threads,0,stream>>>(w,cfg,reverse);CheckCuda(cudaGetLastError(),"wave generate");
    for(unsigned depth=0;depth<=cfg.maxScatter;++depth){
        WaveIntersect<<<groups,threads,0,stream>>>(scene,w,depth);CheckCuda(cudaGetLastError(),"wave intersect");
        WaveShade<<<groups,threads,0,stream>>>(scene,cfg,w,depth);CheckCuda(cudaGetLastError(),"wave shade");
        WaveShadow<<<groups,threads,0,stream>>>(scene,w,depth);CheckCuda(cudaGetLastError(),"wave shadow");
    }
    WaveResolve<<<(cfg.width*cfg.height+threads-1)/threads,threads,0,stream>>>(w,cfg,output);CheckCuda(cudaGetLastError(),"wave resolve");
}
inline WaveRendered RenderWavefront(const DeviceScene& scene,const RenderConfig& cfg,unsigned threads=128,bool reverse=false,unsigned repeats=3){
    ValidateConfig(cfg);Require((threads==64||threads==128||threads==256)&&repeats>0,"wave block/repeats");
    uint64_t paths=uint64_t(cfg.width)*cfg.height*cfg.spp;Require(paths>0&&paths<=4194304,"wave capacity limited to 4M paths");
    WaveStorage storage{unsigned(paths)}; // 各个样本并行；workspace生命周期覆盖全部阶段及最终读回。
    DeviceBuffer<PixelResult> output(size_t(cfg.width)*cfg.height);CudaStream stream;CudaEvents events;
    auto enqueue=[&]{EnqueueWavefront(scene.view,cfg,storage.view,output.pointer,stream.value,threads,reverse);};
    // 基线不在深度间CPU读回计数：固定capacity网格+device count越界退出，空队列也会启动空工作kernel。
    // 这是明确的调度成本；后续Nsight比较会记录，不能把“数据压紧”说成“网格已经缩小”。
    enqueue();CheckCuda(cudaStreamSynchronize(stream.value),"wave warmup");std::vector<float> times;
    for(unsigned r=0;r<repeats;++r){CheckCuda(cudaEventRecord(events.begin,stream.value),"wave begin");enqueue();CheckCuda(cudaEventRecord(events.end,stream.value),"wave end");
        CheckCuda(cudaEventSynchronize(events.end),"wave completed");float ms;CheckCuda(cudaEventElapsedTime(&ms,events.begin,events.end),"wave elapsed");times.push_back(ms);}
    std::sort(times.begin(),times.end());WaveRendered result;result.image={output.Download(),times[times.size()/2]};result.counts=storage.counts.Download()[0];
    result.workspaceBytes=storage.Bytes();result.launches=2+3*(cfg.maxScatter+1);Require(result.counts.errors==0,"wave invalid queue/overflow");return result;
}
}
