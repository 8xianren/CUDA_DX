#pragma once
#include "dynamic_surface.h"
namespace restir_di {
enum class Reject : unsigned {Accepted,NoHistory,Outside,Invalid,Identity,Normal,Depth,Reset,Count};
inline const char* ReasonName(unsigned i){const char* names[]{"accepted","no-history","outside","invalid","identity","normal","depth","reset"};return names[i];}
inline Reject Compatible(const Surface& now,const Surface& old,double expectedOldDepth,double depthTolerance){
    if(!old.valid)return Reject::Invalid;
    if(now.identity!=old.identity)return Reject::Identity;
    if(Dot(now.normal,old.normal)<.95)return Reject::Normal;
    if(std::abs(expectedOldDepth-old.depth)>depthTolerance)return Reject::Depth;
    return Reject::Accepted;
}
struct DynamicReuse {
    CameraGrid previous;bool hasPrevious=false;
    std::vector<Surface> surfaces,oldSurfaces;
    std::vector<LightReservoir> fresh,temporal,spatial,history;
    std::vector<V3> output;
    std::vector<int> sourceIndex;
    std::vector<Reject> reasons;
    std::array<unsigned,unsigned(Reject::Count)> counts{};
    unsigned spatialRejected=0;
    // seed/frameNumber显式传入，使全局重置结果能和相同随机身份的fresh-only对照。
    // 这里只追踪静态世界点的相机运动；物体移动由深度/法线/身份保守拒绝，不伪称有对象motion vector。
    void Step(const Scene& scene,const CameraGrid& camera,const SurfaceConfig& geometry,uint64_t seed,uint64_t frameNumber,bool useTemporal=true,bool useSpatial=true){
        if(!camera.width||!camera.height||uint64_t(camera.width)*camera.height>1048576||camera.extentX<=0||camera.extentY<=0)
            throw std::invalid_argument("dynamic grid");
        size_t n=size_t(camera.width)*camera.height;
        // 灯ID/面积参数化变化用revision全清；遮挡板移动不清历史，因为目标从未含V且最终重查V。
        bool reset=hasPrevious&&(camera.cut||camera.width!=previous.width||camera.height!=previous.height||camera.lightRevision!=previous.lightRevision);
        fresh.assign(n,{});temporal.assign(n,{});spatial.assign(n,{});surfaces.resize(n);output.assign(n,{});sourceIndex.assign(n,-1);reasons.assign(n,Reject::Invalid);counts={};spatialRejected=0;
        for(unsigned id=0;id<n;++id){auto x=MakeSurface(camera,geometry,id);if(x.position.z>=.9||x.position.z<=-2)throw std::invalid_argument("receiver outside lesson geometry range");surfaces[id]=x;if(!x.valid)continue;
            mis::Rng rng(seed+frameNumber*0x9e3779b97f4a7c15ULL,uint64_t(id)*4);LightReservoir r;
            for(unsigned k=0;k<8;++k){auto y=Draw(scene,rng);auto e=EvaluateSurface(scene,x,y);r.Update(y,e.target,e.proposal,rng.Uniform());}fresh[id]=r;}
        for(unsigned id=0;id<n;++id){const auto& x=surfaces[id];if(!x.valid)continue;mis::Rng rng(seed+frameNumber*0x9e3779b97f4a7c15ULL,uint64_t(id)*4+1);LightReservoir r;
            r.Merge(fresh[id],fresh[id].selectedTarget,rng.Uniform());Reject reason=Reject::NoHistory;
            if(useTemporal&&hasPrevious){if(reset)reason=Reject::Reset;else{int src=Reproject(x.position,previous);sourceIndex[id]=src;
                if(src<0)reason=Reject::Outside;else{reason=Compatible(x,oldSurfaces[src],previous.z-x.position.z,.05);
                    if(reason==Reject::Accepted){const auto& h=history[src];r.Merge(h,h.valid?EvaluateSurface(scene,x,h.sample).target:0,rng.Uniform());}}}}
            reasons[id]=reason;++counts[unsigned(reason)];temporal[id]=r;}
        for(unsigned id=0;id<n;++id){const auto& x=surfaces[id];if(!x.valid)continue;mis::Rng rng(seed+frameNumber*0x9e3779b97f4a7c15ULL,uint64_t(id)*4+2);LightReservoir r;
            if(useSpatial){int px=int(id%camera.width),py=int(id/camera.width);constexpr int dx[]{0,-1,1,0,0},dy[]{0,0,0,-1,1};
                for(unsigned j=0;j<5;++j){int nx=px+dx[j],ny=py+dy[j];if(nx<0||ny<0||nx>=int(camera.width)||ny>=int(camera.height))continue;unsigned src=ny*camera.width+nx;
                    if(Compatible(x,surfaces[src],x.depth,.15)!=Reject::Accepted){++spatialRejected;continue;}const auto& h=temporal[src];r.Merge(h,h.valid?EvaluateSurface(scene,x,h.sample).target:0,rng.Uniform());}
            }else r=temporal[id];spatial[id]=r;
            // 可见性只影响当前输出，不将阴影结果烘入reservoir评分/有效性，保留下一帧支持域。
            output[id]=r.valid&&VisibleSurface(scene,x,r.sample)?EvaluateSurface(scene,x,r.sample).unshadowed*r.Normalization():V3{};
        }
        history=temporal;oldSurfaces=surfaces;previous=camera;hasPrevious=true;
    }
};
}
