#include "gpu_path_reference.h"
#include <cstring>
using path_reference::Check;
std::vector<PathRecord> Run(UploadContext& c,const InstanceFrame& frame,const PathConfig& cfg,const std::filesystem::path& shader){
    Check(cfg.paths>0&&cfg.paths<=65536&&cfg.maxScatters<=32&&cfg.mode<=2,"invalid path dispatch config");
    for(int i=0;i<3;++i)Check(cfg.rho[i]>=0&&cfg.rho[i]<1&&cfg.emission[i]>=0,"invalid path material");
    Check(cfg.rrMode<=2&&cfg.rrStart>=1&&cfg.rrStart<=33&&cfg.rrMin>0&&cfg.rrMin<=cfg.rrMax&&cfg.rrMax<=1,"invalid RR config");
    size_t count=size_t(cfg.paths)*(cfg.maxScatters+1);
    auto data=DispatchRayBuffer(c,frame,&cfg,sizeof(cfg),cfg.paths,1,count*sizeof(PathRecord),shader);
    std::vector<PathRecord> result(count);std::memcpy(result.data(),data.data(),data.size());return result;
}
