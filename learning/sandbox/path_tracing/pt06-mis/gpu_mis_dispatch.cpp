#include "gpu_mis.h"
#include "ray_buffer_dispatch.h"
#include <cstring>
#include <stdexcept>
std::vector<MisPixel> DispatchMis(UploadContext& c,const InstanceFrame& frame,const MisConfig& cfg,const std::filesystem::path& dxil){
    // 固定实验的支持域：相机在receiver与blocker之间，向-Z看；拒绝改变了几何假设的参数。
    if(!cfg.width||!cfg.height||cfg.width>1024||cfg.height>1024||!cfg.rounds||cfg.rounds>4096||
       !(cfg.halfLight>0)||!(cfg.halfView>0)||!(cfg.cameraZ>0&&cfg.cameraZ<1)||!(cfg.rho>=0&&cfg.rho<=1)||!(cfg.le>=0))
        throw std::runtime_error("unsupported MIS fixture config");
    auto bytes=DispatchRayBuffer(c,frame,&cfg,sizeof(cfg),cfg.width,cfg.height,
        size_t(cfg.width)*cfg.height*sizeof(MisPixel),dxil);
    std::vector<MisPixel> pixels(size_t(cfg.width)*cfg.height);
    std::memcpy(pixels.data(),bytes.data(),bytes.size());return pixels;
}
