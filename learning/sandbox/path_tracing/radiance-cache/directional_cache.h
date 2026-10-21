#pragma once
#include "cache_scene.h"
#include <stdexcept>
#include <vector>
namespace cache_lesson {
class DirectionalCache {
public:
    unsigned resolution;std::vector<Coeff> values;bool valid=false;uint64_t revision=0;
    // 单张已知次级面的缓存；面ID和法线由对象所属场景固定，不在每格重复存储。
    // 按row*resolution+column存两个double系数，值拥有于vector；没有GPU/外部指针。
    explicit DirectionalCache(unsigned n):resolution(n){if(n<2||n>129)throw std::invalid_argument("cache resolution");values.resize(size_t(n)*n);}
    V3 Node(unsigned p)const{return {-1+2.*(p%resolution)/(resolution-1),-1+2.*(p/resolution)/(resolution-1),1};}
    // 更新噪声与查询路径独立：每个run、每个节点使用独立PCG流。
    // 先填临时表，完成后交换并发布版本，查询不会读到半更新结果。CPU串行，无隐式GPU同步。
    void Train(unsigned samples,uint64_t seed,uint64_t sceneRevision){
        if(!samples)throw std::invalid_argument("cache training samples");std::vector<Coeff> next(values.size());
        for(unsigned p=0;p<next.size();++p){mis::Rng rng(seed,p);auto y=Node(p);Coeff c;
            for(unsigned i=0;i<samples;++i)c=c+TailSample(y,DrawLight(rng));next[p]=c*(1./samples);}
        values.swap(next);revision=sceneRevision;valid=true;
    }
    void FillReference(unsigned n,uint64_t sceneRevision){if(!n)throw std::invalid_argument("quadrature resolution");
        for(unsigned p=0;p<values.size();++p)values[p]=ExactCoefficients(Node(p),n);revision=sceneRevision;valid=true;}
    // 返回bool表示覆盖/版本是否有效；失败时不提供可被误认成合法黑色的输出。
    // caller可回退完整后缀，本实验覆盖外测试显式检查false。禁止静默夹到边界读旧版本。
    bool Query(V3 y,uint64_t sceneRevision,Coeff& output)const{
        if(!valid||revision!=sceneRevision||!std::isfinite(y.x)||!std::isfinite(y.y)||y.x< -1||y.x>1||y.y< -1||y.y>1||y.z!=1)return false;
        double u=(y.x+1)*.5*(resolution-1),v=(y.y+1)*.5*(resolution-1);
        unsigned i=std::min(unsigned(u),resolution-2),j=std::min(unsigned(v),resolution-2);double tx=u-i,ty=v-j;
        auto bottom=values[j*resolution+i]*(1-tx)+values[j*resolution+i+1]*tx;
        auto top=values[(j+1)*resolution+i]*(1-tx)+values[(j+1)*resolution+i+1]*tx;
        output=bottom*(1-ty)+top*ty;return true;
    }
};
}
