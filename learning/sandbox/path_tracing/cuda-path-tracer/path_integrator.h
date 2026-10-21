#pragma once
#include "path_math.h"
namespace cuda_pt {
struct PathLight {uint32_t triangle=0;float area=0;};
struct PathView {
    const Triangle* triangles=nullptr;const Material* materials=nullptr;const Node* nodes=nullptr;
    const uint32_t* order=nullptr;const PathLight* lights=nullptr;
    uint32_t triangleCount=0,nodeCount=0,lightCount=0;
};
struct RenderConfig {
    uint32_t width=31,height=17,spp=8,sampleOffset=0,seed=17,maxScatter=4,nee=1,rr=1,rrStart=3;
    Vec3 eye{0,2,8},forward{0,0,-1},right{1,0,0},up{0,1,0};
    float tanHalfFov=.45f,epsilon=1e-4f;
};
// 每像素独占一个结果；诊断数是整数，不需要原子加。active[d]记录实际发出的第d层路径射线。
// 阴影射线单独统计，不混入反弹深度。哈希只记录离散决定，不混入float算术。
struct PathStats {
    uint32_t rays=0,shadows=0,vertices=0,rrKilled=0,errors=0,hash=0;
    uint32_t active[17]{};
};
struct PixelResult {Vec3 radiance;PathStats stats;};
static_assert(sizeof(PathLight)==8&&sizeof(PixelResult)==104);
PT_HD inline void MergePathStats(PathStats& pixel,const PathStats& sample,uint32_t sampleId){
    // 先按样本独立记录，再按sample顺序合并摘要：允许Wavefront同时执行多个样本。
    // 只改变诊断组织，不改变随机数、积分公式或RGB求和顺序。哈希并非完整轨迹日志。
    pixel.rays+=sample.rays;pixel.shadows+=sample.shadows;pixel.vertices+=sample.vertices;
    pixel.rrKilled+=sample.rrKilled;pixel.errors+=sample.errors;
    pixel.hash=PathHash(pixel.hash^sample.hash^PathHash(sampleId));
    for(unsigned i=0;i<17;++i)pixel.active[i]+=sample.active[i];
}
template<class T> struct PathRay {PVec<T> origin,direction;T tmin=0,tmax=1000;};
template<class T> struct PathHit {T t=0,u=0,v=0;uint32_t id=Invalid;};
template<class T> struct PathState {
    PathRay<T> ray;PVec<T> beta{1,1,1},radiance{},previousPosition{};T previousPdf=0;
    uint32_t pixel=0,sample=0,depth=0;bool alive=true;
};
template<class T> struct ShadowTask {PathRay<T> ray;PVec<T> contribution{};bool valid=false;};
template<class T> PT_HD inline PathState<T> StartPath(const RenderConfig& cfg,uint32_t pixel,uint32_t sample){
    PathState<T> p;p.pixel=pixel;p.sample=sample;
    T jx=T(PathRandom(pixel,sample,cfg.seed,0,0)),jy=T(PathRandom(pixel,sample,cfg.seed,0,1));
    T x=(T(2)*(T(pixel%cfg.width)+jx)/T(cfg.width)-T(1))*T(cfg.width)/T(cfg.height)*T(cfg.tanHalfFov);
    T y=(T(1)-T(2)*(T(pixel/cfg.width)+jy)/T(cfg.height))*T(cfg.tanHalfFov);
    p.ray.origin=PV<T>(cfg.eye);p.ray.direction=PNormalize(PV<T>(cfg.forward)+PV<T>(cfg.right)*x+PV<T>(cfg.up)*y);
    p.ray.tmin=T(cfg.epsilon);return p;
}
template<class T> PT_HD inline ShadowTask<T> ShadePath(const PathView& scene,const RenderConfig& cfg,PathState<T>& path,const PathHit<T>& hit,PathStats& stats){
    ShadowTask<T> shadow;stats.hash=PathHash(stats.hash^PathHash(hit.id+path.depth*31u));
    if(hit.id==Invalid){path.alive=false;return shadow;} // 黑色环境，无隐含的环境NEE分布。
    ++stats.vertices;const Triangle& triangle=scene.triangles[hit.id];const Material& material=scene.materials[triangle.material];
    auto a=PV<T>(triangle.a),b=PV<T>(triangle.b),c=PV<T>(triangle.c);
    auto geometric=PNormalize(PCross(b-a,c-a));auto point=a+(b-a)*hit.u+(c-a)*hit.v;
    auto normal=PDot(geometric,path.ray.direction)<0?geometric:geometric*T(-1);
    auto base=PV<T>(material.base),emission=PV<T>(material.emission);
    // 发光只向几何法线正面；Lambert散射双面。必须先加当前Le，再更新下一段的beta。
    if(MaxComponent(emission)>0&&PDot(geometric,path.ray.direction)<0){
        T weight=1;
        if(path.depth>0&&cfg.nee&&scene.lightCount){
            auto delta=point-path.previousPosition;T distance2=PDot(delta,delta);
            T cosine=PMax(T(0),PDot(geometric,PNormalize(delta)*T(-1)));
            T area=PSqrt(PDot(PCross(b-a,c-a),PCross(b-a,c-a)))*T(.5);
            T lightPdf=cosine>0?distance2/(T(scene.lightCount)*area*cosine):T(0);
            weight=PowerWeight(path.previousPdf,lightPdf);
        }
        path.radiance=path.radiance+path.beta*emission*weight;
    }
    // K定义为最多K次散射：d==K仍检查已到达表面的Le，随后停止；此处不再做新的NEE。
    if(path.depth>=cfg.maxScatter||MaxComponent(base)<=0){path.alive=false;return shadow;}
    if(cfg.nee&&scene.lightCount){
        T choose=T(PathRandom(path.pixel,path.sample,cfg.seed,path.depth,2));
        uint32_t lightIndex=uint32_t(choose*T(scene.lightCount));if(lightIndex>=scene.lightCount)lightIndex=scene.lightCount-1;
        const auto& light=scene.lights[lightIndex];const auto& lt=scene.triangles[light.triangle];
        T u=T(PathRandom(path.pixel,path.sample,cfg.seed,path.depth,3)),v=T(PathRandom(path.pixel,path.sample,cfg.seed,path.depth,4)),root=PSqrt(u);
        auto la=PV<T>(lt.a),lb=PV<T>(lt.b),lc=PV<T>(lt.c);
        auto target=la*(T(1)-root)+lb*(root*(T(1)-v))+lc*(root*v);
        auto delta=target-point;T distance2=PDot(delta,delta);auto wi=PNormalize(delta),ln=PNormalize(PCross(lb-la,lc-la));
        T surfaceCos=PMax(T(0),PDot(normal,wi)),lightCos=PMax(T(0),PDot(ln,wi*T(-1)));
        if(surfaceCos>0&&lightCos>0&&distance2>T(4)*T(cfg.epsilon)*T(cfg.epsilon)){
            // 均匀选灯三角形q=1/L；三角形内均匀面积密度1/A。转换为方向密度r²/(L*A*cosLight)。
            T pdf=distance2/(T(scene.lightCount)*T(light.area)*lightCos),bsdfPdf=surfaceCos/Pi<T>();
            shadow.contribution=path.beta*base*PV<T>(scene.materials[lt.material].emission)*(surfaceCos/(Pi<T>()*pdf)*PowerWeight(pdf,bsdfPdf));
            // PDF/几何项使用原表面点；可见性射线偏移后重新指向同一个灯点，两端留epsilon。
            // 这是当前米级场景的数值近似，不宣称适用于任意尺度的稳健偏移。
            shadow.ray.origin=point+normal*T(cfg.epsilon);auto offsetDelta=target-shadow.ray.origin;T distance=PSqrt(PDot(offsetDelta,offsetDelta));
            shadow.ray.direction=offsetDelta*(T(1)/distance);shadow.ray.tmin=T(cfg.epsilon);shadow.ray.tmax=distance-T(cfg.epsilon);
            shadow.valid=shadow.ray.tmax>=shadow.ray.tmin;
        }
    }
    auto direction=CosineDirection(normal,T(PathRandom(path.pixel,path.sample,cfg.seed,path.depth,5)),T(PathRandom(path.pixel,path.sample,cfg.seed,path.depth,6)));
    path.previousPdf=PMax(T(0),PDot(normal,direction))/Pi<T>();path.previousPosition=point;
    // 余弦采样p=cos/pi，Lambert f=rho/pi，故f*cos/p=rho；RGB逐分量乘，不能乘点积。
    path.beta=path.beta*base;
    if(cfg.rr&&path.depth+1>=cfg.rrStart){
        T survive=PMin(T(.95),PMax(T(.05),MaxComponent(path.beta)));
        bool live=T(PathRandom(path.pixel,path.sample,cfg.seed,path.depth,7))<survive;
        stats.hash=PathHash(stats.hash^(live?0x1234u:0x9876u));
        if(!live){++stats.rrKilled;path.alive=false;return shadow;}
        path.beta=path.beta*(T(1)/survive);
    }
    path.ray.origin=point+normal*T(cfg.epsilon);path.ray.direction=direction;path.ray.tmin=T(cfg.epsilon);path.ray.tmax=1000;++path.depth;
    return shadow;
}
struct DeviceTrace {
    PathView view;
    PT_HD PathHit<float> operator()(const PathRay<float>& ray,PathStats& stats) const{
        Ray r{FV(ray.origin),ray.tmin,FV(ray.direction),ray.tmax};auto result=TraceBvh(view.triangles,view.triangleCount,view.nodes,view.nodeCount,view.order,r);
        if(result.counts.error)++stats.errors;return {result.hit.t,result.hit.u,result.hit.v,result.hit.id};
    }
};
template<class T,class Trace> PT_HD inline PVec<T> IntegrateSample(const PathView& scene,const RenderConfig& cfg,uint32_t pixel,uint32_t sample,Trace trace,PathStats& stats){
    // 两种Megakernel共用完整的单样本循环，控制组只改变并行粒度，不复制另一套积分逻辑。
    auto path=StartPath<T>(cfg,pixel,sample);
        while(path.alive){++stats.rays;++stats.active[path.depth];auto hit=trace(path.ray,stats);auto shadow=ShadePath(scene,cfg,path,hit,stats);
            // 即使RR刚终止后续路径，当前顶点已产生的NEE仍必须执行，不能随alive==false丢弃。
            if(shadow.valid){++stats.shadows;auto obstruction=trace(shadow.ray,stats);bool visible=obstruction.id==Invalid;
                stats.hash=PathHash(stats.hash^(visible?0xabcd1234u:0x1234abcdu));if(visible)path.radiance=path.radiance+shadow.contribution;}
        }
    if(!PFinite(path.radiance))++stats.errors;return path.radiance;
}
template<class T,class Trace> PT_HD inline PVec<T> IntegratePixel(const PathView& scene,const RenderConfig& cfg,uint32_t pixel,Trace trace,PathStats& stats){
    PVec<T> sum{};uint32_t combinedHash=stats.hash;
    // 一个线程固定样本顺序求和。计数直接累计，只将32bit哈希按样本隔离。
    for(uint32_t s=0;s<cfg.spp;++s){stats.hash=0;
        sum=sum+IntegrateSample<T>(scene,cfg,pixel,cfg.sampleOffset+s,trace,stats);
        combinedHash=PathHash(combinedHash^stats.hash^PathHash(cfg.sampleOffset+s));
    }stats.hash=combinedHash;return sum*(T(1)/T(cfg.spp));
}
}
