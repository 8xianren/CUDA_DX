#include "volume_math.cuh"
#include <algorithm>
#include <stdexcept>

namespace neural::volume {
float AnalyticDensity(float3 p) { return detail::Density(p); }
Field MakeSphereField(int n) {
    if(n<8 || n>1024) throw std::invalid_argument("volume resolution must be 8..1024");
    Field f; f.resolution=n; f.density.resize(size_t(n)*n*n);
    for(int z=0;z<n;++z) for(int y=0;y<n;++y) for(int x=0;x<n;++x)
        f.density[(size_t(z)*n+y)*n+x]=AnalyticDensity({-1+2*(x+.5f)/n,-1+2*(y+.5f)/n,-1+2*(z+.5f)/n});
    return f;
}
namespace {
// CUDA 纹理中 texel 0 的中心坐标为 0.5。世界p转为u=(p+1)/2后，
// 插值网格坐标q=u*N-.5；CPU浮点三线性是参考，硬件插值权重有限精度会有微小差异。
float Sample(const Field& f,float3 p) {
    const int n=f.resolution;
    float q[3]={(p.x+1)*.5f*n-.5f,(p.y+1)*.5f*n-.5f,(p.z+1)*.5f*n-.5f};
    int lo[3]; float t[3];
    for(int a=0;a<3;++a) {lo[a]=int(floorf(q[a]));t[a]=q[a]-lo[a];}
    float value=0;
    for(int z=0;z<2;++z) for(int y=0;y<2;++y) for(int x=0;x<2;++x) {
        const int ix=std::clamp(lo[0]+x,0,n-1), iy=std::clamp(lo[1]+y,0,n-1), iz=std::clamp(lo[2]+z,0,n-1);
        const float w=(x?t[0]:1-t[0])*(y?t[1]:1-t[1])*(z?t[2]:1-t[2]);
        value+=w*f.density[(size_t(iz)*n+iy)*n+ix];
    }
    return value;
}
}
std::vector<float4> RenderCpu(const Field* field,const Camera& c,const RenderOptions& o,std::vector<PixelStats>* stats,
                              const float* meshRayDistance) {
    if(o.width<=0 || o.height<=0 || !(o.step>0) || !std::isfinite(o.step)) throw std::invalid_argument("invalid render dimensions/step");
    if(field && field->density.size()!=size_t(field->resolution)*field->resolution*field->resolution) throw std::invalid_argument("invalid field layout");
    std::vector<float4> pixels(size_t(o.width)*o.height);
    if(stats) stats->assign(pixels.size(),{});
    for(int y=0;y<o.height;++y) for(int x=0;x<o.width;++x) {
        const size_t index=size_t(y)*o.width+x;
        const float3 d=detail::Direction(c,o,x,y);
        float begin,end,T=1; float3 color{}; PixelStats s{};
        if(detail::Box(c.origin,d,begin,end)) {
            // CPU指针由调用者拥有，长度为width*height；值是世界射线距离，绝非NDC/viewZ。
            // 在积分前缩短区间，与CUDA路径独立地执行不透明遮挡，供跨API端到端oracle使用。
            if(meshRayDistance) end=fminf(end,fmaxf(0,meshRayDistance[index]));
            s.hit=end>begin;
            // int k 重建采样位置，避免连续 t+=dt 的累计漂移；跳空路径同样使用该格点。
            for(unsigned k=0;;++k) {
                const float t=begin+k*o.step;
                if(t>=end) break;
                const float dt=fminf(o.step,end-t);
                const float fraction=o.jitter?detail::Jitter(unsigned(index),o.seed):.5f;
                const float3 p=detail::Add(c.origin,detail::Mul(d,t+fraction*dt));
                detail::Accumulate(field?Sample(*field,p):AnalyticDensity(p),dt,detail::Color(p),T,color);
                ++s.samples;
                if(T<o.termination) {s.terminated=1;break;}
            }
        }
        pixels[index]={color.x,color.y,color.z,1-T};
        if(stats) (*stats)[index]=s;
    }
    return pixels;
}
} // namespace neural::volume
