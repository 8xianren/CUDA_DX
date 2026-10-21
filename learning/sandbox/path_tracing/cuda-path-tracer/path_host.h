#pragma once
#include "path_integrator.h"
#include "bvh_build.h"
#include <iomanip>
#include <array>
namespace cuda_pt {
inline std::vector<PathLight> BuildPathLights(const Scene& scene){
    ValidateScene(scene);std::vector<PathLight> lights;
    for(const auto& m:scene.materials){Require(m.base.x>=0&&m.base.y>=0&&m.base.z>=0&&m.base.x<=1&&m.base.y<=1&&m.base.z<=1,"Lambert reflectance must be [0,1]");
        Require(m.emission.x>=0&&m.emission.y>=0&&m.emission.z>=0,"nonnegative emission");}
    for(const auto& t:scene.triangles){auto cross=Cross(t.b-t.a,t.c-t.a);float area=.5f*sqrtf(Dot(cross,cross));auto e=scene.materials[t.material].emission;
        if(e.x+e.y+e.z>0&&area>0)lights.push_back({t.id,area});}
    return lights;
}
inline void ValidateConfig(const RenderConfig& c){
    Require(c.width&&c.height&&uint64_t(c.width)*c.height<=4194304&&c.spp&&c.spp<=65536,"image/spp limits");
    Require(c.maxScatter<=16&&c.rrStart>=1&&c.epsilon>0&&c.epsilon<.01f&&Finite(c.epsilon),"depth/epsilon limits");
    Require(c.sampleOffset<=UINT32_MAX-c.spp&&c.tanHalfFov>0&&c.tanHalfFov<10&&Finite(c.eye)&&Finite(c.forward)&&Finite(c.right)&&Finite(c.up),"camera/sample range");
    Require(fabsf(Dot(c.forward,c.forward)-1)<1e-4f&&fabsf(Dot(c.right,c.right)-1)<1e-4f&&fabsf(Dot(c.up,c.up)-1)<1e-4f,"camera unit axes");
    Require(fabsf(Dot(c.forward,c.right))<1e-4f&&fabsf(Dot(c.forward,c.up))<1e-4f&&fabsf(Dot(c.up,c.right))<1e-4f,"orthogonal camera axes");
}
inline void Camera(RenderConfig& c,Vec3 eye,Vec3 target){c.eye=eye;c.forward=Normalize(target-eye);c.right=Normalize(Cross(c.forward,{0,1,0}));c.up=Cross(c.right,c.forward);}
inline PathView HostView(const Scene& scene,const Bvh& b,const std::vector<PathLight>& lights){return {scene.triangles.data(),scene.materials.data(),b.nodes.data(),b.order.data(),lights.data(),uint32_t(scene.triangles.size()),uint32_t(b.nodes.size()),uint32_t(lights.size())};}
struct DoubleTrace {
    PathView view;
    PT_HD PathHit<double> operator()(const PathRay<double>& ray,PathStats&) const{
        // 独立求交：double射线不转回float，平面交点+Gram线性方程，而非GPU的Möller–Trumbore。
        PathHit<double> best;best.t=ray.tmax;
        for(uint32_t i=0;i<view.triangleCount;++i){const auto& t=view.triangles[i];auto a=PV<double>(t.a),e1=PV<double>(t.b)-a,e2=PV<double>(t.c)-a,n=PCross(e1,e2);
            double nd=PDot(n,ray.direction);if(nd==0)continue;double distance=PDot(n,a-ray.origin)/nd;if(distance<ray.tmin||distance>best.t)continue;
            auto q=ray.origin+ray.direction*distance-a;double aa=PDot(e1,e1),ab=PDot(e1,e2),bb=PDot(e2,e2),aq=PDot(e1,q),bq=PDot(e2,q),det=aa*bb-ab*ab;
            if(det<=0)continue;double u=(aq*bb-bq*ab)/det,v=(bq*aa-aq*ab)/det;if(u<0||v<0||u+v>1)continue;
            if(distance<best.t||t.id<best.id)best={distance,u,v,t.id};
        }return best;
    }
};
inline std::vector<PixelResult> RenderCpu(const Scene& scene,const Bvh& b,const std::vector<PathLight>& lights,const RenderConfig& cfg){
    ValidateConfig(cfg);auto view=HostView(scene,b,lights);std::vector<PixelResult> result(size_t(cfg.width)*cfg.height);
    for(uint32_t i=0;i<result.size();++i)result[i].radiance=FV(IntegratePixel<double>(view,cfg,i,DoubleTrace{view},result[i].stats));return result;
}
inline void Quad(Scene& scene,Vec3 a,Vec3 b,Vec3 c,Vec3 d,uint32_t material){
    for(auto vertices:{std::array<Vec3,3>{a,b,c},std::array<Vec3,3>{a,c,d}}){Triangle t;t.a=vertices[0];t.b=vertices[1];t.c=vertices[2];t.material=material;t.id=uint32_t(scene.triangles.size());scene.triangles.push_back(t);}
}
inline Scene Cornell(){
    // 本课自建几何只使用漫反射和朝下的矩形灯。盒中小箱提供遮挡和间接反弹，开口朝+z。
    Scene s;s.materials={{{.7f,.7f,.7f},0,{},0},{{.75f,.12f,.08f},0,{},0},{{.1f,.6f,.18f},0,{},0},{{0,0,0},0,{9,8,6},0}};
    Quad(s,{-3,0,-3},{3,0,-3},{3,0,3},{-3,0,3},0);Quad(s,{-3,4,-3},{3,4,-3},{3,4,3},{-3,4,3},0);
    Quad(s,{-3,0,-3},{3,0,-3},{3,4,-3},{-3,4,-3},0);Quad(s,{-3,0,3},{-3,0,-3},{-3,4,-3},{-3,4,3},1);
    Quad(s,{3,0,-3},{3,0,3},{3,4,3},{3,4,-3},2);Quad(s,{-1,3.9f,-1},{1,3.9f,-1},{1,3.9f,1},{-1,3.9f,1},3);
    float x0=-.9f,x1=.65f,y0=0,y1=1.5f,z0=-.9f,z1=.8f;
    Quad(s,{x0,y1,z0},{x1,y1,z0},{x1,y1,z1},{x0,y1,z1},0);Quad(s,{x0,y0,z0},{x1,y0,z0},{x1,y1,z0},{x0,y1,z0},0);
    Quad(s,{x1,y0,z1},{x0,y0,z1},{x0,y1,z1},{x1,y1,z1},0);Quad(s,{x0,y0,z1},{x0,y0,z0},{x0,y1,z0},{x0,y1,z1},0);
    Quad(s,{x1,y0,z0},{x1,y0,z1},{x1,y1,z1},{x1,y1,z0},0);return s;
}
inline Scene EmissionAnchor(){Scene s;s.materials.push_back({{0,0,0},0,{3,2,1},0});Quad(s,{-20,-20,0},{20,-20,0},{20,20,0},{-20,20,0},0);return s;}
inline void WriteImage(const std::filesystem::path& stem,const std::vector<PixelResult>& pixels,const RenderConfig& cfg){
    // HDR用PFM保留线性float；另写Reinhard+一次sRGB的PPM，只用于看图，不拿显示码值做积分验收。
    std::ofstream pfm(stem.string()+".pfm",std::ios::binary),ppm(stem.string()+".ppm",std::ios::binary);
    pfm<<"PF\n"<<cfg.width<<' '<<cfg.height<<"\n-1.0\n";ppm<<"P6\n"<<cfg.width<<' '<<cfg.height<<"\n255\n";
    for(int y=int(cfg.height)-1;y>=0;--y)for(unsigned x=0;x<cfg.width;++x){Vec3 v=pixels[size_t(y)*cfg.width+x].radiance;pfm.write(reinterpret_cast<const char*>(&v),12);}
    for(const auto& p:pixels)for(float v:{p.radiance.x,p.radiance.y,p.radiance.z}){float linear=std::max(0.f,v)/(1+std::max(0.f,v));float srgb=linear<=.0031308f?12.92f*linear:1.055f*powf(linear,1.f/2.4f)-.055f;unsigned char c=static_cast<unsigned char>(std::lround(std::clamp(srgb,0.f,1.f)*255));ppm.write(reinterpret_cast<char*>(&c),1);}
    Require(pfm&&ppm,"image write");
}
}
