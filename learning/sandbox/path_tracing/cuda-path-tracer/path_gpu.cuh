#pragma once
#include "cuda_support.h"
#include "path_host.h"
namespace cuda_pt {
__global__ void Megakernel(PathView scene,RenderConfig config,PixelResult* output){
    uint32_t pixel=blockIdx.x*blockDim.x+threadIdx.x;if(pixel>=config.width*config.height)return;
    PixelResult result{};result.radiance=FV(IntegratePixel<float>(scene,config,pixel,DeviceTrace{scene},result.stats));output[pixel]=result;
}
struct DeviceScene {
    DeviceBuffer<Triangle> triangles;DeviceBuffer<Material> materials;DeviceBuffer<Node> nodes;
    DeviceBuffer<uint32_t> order;DeviceBuffer<PathLight> lights;PathView view;
    DeviceScene(const Scene& s,const Bvh& b,const std::vector<PathLight>& l):triangles(s.triangles),materials(s.materials),nodes(b.nodes),order(b.order),lights(l){
        view={triangles.pointer,materials.pointer,nodes.pointer,order.pointer,lights.pointer,uint32_t(triangles.count),uint32_t(nodes.count),uint32_t(lights.count)};
        // pageable HtoD返回不保证最终DMA完成；接下来的nonblocking stream需要显式上传完成边界。
        CheckCuda(cudaDeviceSynchronize(),"path scene uploads complete");
    }
};
struct Rendered {std::vector<PixelResult> pixels;float milliseconds=0;};
inline Rendered RenderGpu(const DeviceScene& scene,const RenderConfig& cfg,unsigned threads=128,unsigned repeats=3){
    ValidateConfig(cfg);Require((threads==64||threads==128||threads==256)&&repeats>0,"kernel block/repeat policy");
    DeviceBuffer<PixelResult> output(size_t(cfg.width)*cfg.height);CudaStream stream;CudaEvents events;
    auto launch=[&]{Megakernel<<<(cfg.width*cfg.height+threads-1)/threads,threads,0,stream.value>>>(scene.view,cfg,output.pointer);CheckCuda(cudaGetLastError(),"Megakernel launch");};
    launch();CheckCuda(cudaStreamSynchronize(stream.value),"Megakernel warmup");std::vector<float> times;
    for(unsigned i=0;i<repeats;++i){CheckCuda(cudaEventRecord(events.begin,stream.value),"Megakernel begin");launch();CheckCuda(cudaEventRecord(events.end,stream.value),"Megakernel end");
        CheckCuda(cudaEventSynchronize(events.end),"Megakernel complete");float ms=0;CheckCuda(cudaEventElapsedTime(&ms,events.begin,events.end),"Megakernel ms");times.push_back(ms);}
    std::sort(times.begin(),times.end());return {output.Download(),times[times.size()/2]};
}
}
