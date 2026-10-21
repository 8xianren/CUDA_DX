#pragma once
#include "path_gpu.cuh"
namespace cuda_pt {
// 控制组只改变“哪些样本分给独立线程”，完整路径仍在一个kernel内执行。
// samples由宿主DeviceBuffer拥有，容量至少W*H*SPP；每个元素104B（RGB+诊断计数）。
// 线程只写自己的id，无浮点atomic；随机数仍由pixel、sample和维度确定，不由调度顺序确定。
__global__ void SampleMegakernel(PathView scene,RenderConfig cfg,PixelResult* samples){
    unsigned id=blockIdx.x*blockDim.x+threadIdx.x,paths=cfg.width*cfg.height*cfg.spp;if(id>=paths)return;
    unsigned pixel=id/cfg.spp,sample=cfg.sampleOffset+id%cfg.spp;PixelResult result{};
    result.radiance=FV(IntegrateSample<float>(scene,cfg,pixel,sample,DeviceTrace{scene},result.stats));samples[id]=result;
}
__global__ void SampleResolve(const PixelResult* samples,RenderConfig cfg,PixelResult* output){
    unsigned pixel=blockIdx.x*blockDim.x+threadIdx.x;if(pixel>=cfg.width*cfg.height)return;
    PVec<float> sum{};PixelResult result{};
    // 保持同样的sample加法顺序和诊断摘要。独立样本并行不需要浮点原子加。
    for(unsigned s=0;s<cfg.spp;++s){const auto& entry=samples[pixel*cfg.spp+s];sum=sum+PV<float>(entry.radiance);MergePathStats(result.stats,entry.stats,cfg.sampleOffset+s);}
    result.radiance=FV(sum*(1.f/cfg.spp));output[pixel]=result;
}
inline void EnqueueSampleMega(PathView scene,const RenderConfig& cfg,PixelResult* samples,PixelResult* output,cudaStream_t stream,unsigned threads){
    // 前置：cfg和乘积容量由宿主验证，threads是合法block大小，输出至少W*H项。
    // 同一stream保证完整路径写完后Resolve才读取；函数仅提交，宿主不能立即释放/读回。
    // GetLastError报告启动错误，异步执行错误由调用者随后同步stream/event检查。
    SampleMegakernel<<<(cfg.width*cfg.height*cfg.spp+threads-1)/threads,threads,0,stream>>>(scene,cfg,samples);CheckCuda(cudaGetLastError(),"sample mega launch");
    SampleResolve<<<(cfg.width*cfg.height+threads-1)/threads,threads,0,stream>>>(samples,cfg,output);CheckCuda(cudaGetLastError(),"sample resolve launch");
}
}
