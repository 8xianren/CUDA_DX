#pragma once
#include "pbr_resources.h"
#include "path_config.h"
#include "../pt08-materials/ggx_math.h"
#include <cstring>
#include <stdexcept>
// 共享主线的CPU场景工具。PT.8离线验收、PT.10渐进历史使用同一相机/灯分布定义。
using ggx::V;
inline V Vector(const float* p){return {p[0],p[1],p[2]};}
inline void Store(float* p,V v){p[0]=float(v.x);p[1]=float(v.y);p[2]=float(v.z);}
inline void Require(bool v,const char* message){if(!v)throw std::runtime_error(message);}
inline uint32_t Hash(uint32_t x){x=(x^(x>>16))*0x21f0aaadu;x=(x^(x>>15))*0x735a2d97u;return x^(x>>15);}
inline double Random(uint32_t pixel,uint32_t sample,uint32_t seed,uint32_t depth,uint32_t dim){uint32_t x=(pixel+1)*747796405u+(sample+1)*2891336453u+seed*277803737u+depth*1597334677u+dim*3812015801u;return ((Hash(x)>>9)+.5)/8388608.;}
struct Triangle {V a,b,c,normal;uint32_t instance,primitive,material;double area;};
inline std::vector<Triangle> WorldTriangles(const CpuScene& cpu){std::vector<Triangle> triangles;
    // CPU double独立参考与灯表共同读取自有CpuScene，不读取BLAS内部布局。
    // 先按节点world变换顶点，再计算实际世界面积；非均匀缩放不能直接沿用网格局部面积。
    for(uint32_t instance=0;instance<cpu.instances.size();++instance){auto entry=cpu.instances[instance];auto& mesh=cpu.meshes[entry.meshIndex];auto& world=cpu.nodes[entry.nodeIndex].world;
        for(uint32_t j=0;j<mesh.indices.size();j+=3){V p[3];for(unsigned k=0;k<3;++k){auto v=TransformPoint(world,mesh.vertices[mesh.indices[j+k]].position);p[k]=Vector(v.data());}
            V cross=ggx::Cross(p[1]-p[0],p[2]-p[0]);double length=std::sqrt(ggx::Dot(cross,cross));if(length<=1e-12)continue;
            triangles.push_back({p[0],p[1],p[2],cross*(1/length),instance,j/3,mesh.materialIndex,length*.5});}
    }return triangles;
}

// 相机以world空间eye/target定义，正交基用于透视射线；不把相机移动误当作屏幕平移。
inline void SetPathCamera(PathConfig& cfg,V eye,V target){
    V f=ggx::Normalize(target-eye),r=ggx::Normalize(ggx::Cross(f,{0,1,0})),u=ggx::Cross(r,f);
    Store(cfg.eye,eye);Store(cfg.forward,f);Store(cfg.right,r);Store(cfg.up,u);
}
// 世界面积CDF。只有emissive factor非零的三角形进入分布；纹理发光仍由shader逐点读取。
inline std::vector<PathLight> MakePathLights(const CpuScene& cpu,const std::vector<Triangle>& triangles,PathConfig& cfg){
    std::vector<PathLight> lights;double totalArea=0;
    for(auto& t:triangles){const auto& m=cpu.materialAssets.materials[t.material];
        if(m.emissive[0]+m.emissive[1]+m.emissive[2]<=0)continue;
        PathLight l{};Store(l.a,t.a);Store(l.b,t.b);Store(l.c,t.c);l.area=float(t.area);
        totalArea+=t.area;l.cdf=float(totalArea);l.instance=t.instance;l.primitive=t.primitive;lights.push_back(l);
    }
    Require(totalArea>0&&std::isfinite(totalArea)&&lights.size()<1000000,"scene must have finite triangle lights");
    cfg.totalArea=float(totalArea);cfg.lightCount=uint32_t(lights.size());
    for(auto& l:lights)l.cdf/=cfg.totalArea;lights.back().cdf=1;return lights;
}
inline std::vector<float> TeachingIors(const CpuScene& cpu){
    // 显式教学覆盖而非glTF扩展。每个正IOR实例是封闭、非嵌套、无吸收的平滑玻璃。
    std::vector<float> values(cpu.materialAssets.materials.size(),0);
    for(size_t i=0;i<values.size();++i)if(cpu.materialAssets.materials[i].name=="teaching_glass")values[i]=1.5f;
    return values;
}
inline std::vector<uint8_t> PackPathConfig(const PathConfig& cfg,const std::vector<PathLight>& lights){
    Require(cfg.lightCount==lights.size(),"light configuration count");
    std::vector<uint8_t> bytes(sizeof(cfg)+lights.size()*sizeof(PathLight));
    memcpy(bytes.data(),&cfg,sizeof(cfg));memcpy(bytes.data()+sizeof(cfg),lights.data(),lights.size()*sizeof(PathLight));return bytes;
}

struct CpuHit {const Triangle* triangle=nullptr;double distance=1000;};
inline CpuHit Intersect(const std::vector<Triangle>& triangles,V origin,V direction){CpuHit result;
    // 独立Möller–Trumbore，仅验收稀疏主射线；主渲染仍由DXR求交，没有将CPU遍历冒充GPU性能。
    for(auto& t:triangles){V e1=t.b-t.a,e2=t.c-t.a,p=ggx::Cross(direction,e2);double det=ggx::Dot(e1,p);if(std::abs(det)<1e-12)continue;
        double inv=1/det;V offset=origin-t.a;double u=ggx::Dot(offset,p)*inv;if(u<0||u>1)continue;
        V q=ggx::Cross(offset,e1);double v=ggx::Dot(direction,q)*inv;if(v<0||u+v>1)continue;
        double distance=ggx::Dot(e2,q)*inv;if(distance>=1e-5&&distance<result.distance)result={&t,distance};
    }return result;
}
