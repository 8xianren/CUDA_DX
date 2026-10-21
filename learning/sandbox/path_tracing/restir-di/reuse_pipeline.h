#pragma once
#include "direct_scene.h"
namespace restir_di {
using LightReservoir=restir::Reservoir<LightSample>;
struct Grid {
    unsigned width=12,height=8;
    V3 Point(unsigned id)const{return {-1.2+2.4*(id%width+.5)/width,-.8+1.6*(id/width+.5)/height,0};}
};
struct StaticReuse {
    // 本节固定场景/网格：同pixel历史对应同一世界点。改变相机/几何必须重建本对象；
    // 下一节再加入显式重投影和拒绝，不能把本节identity映射当成动态场景方案。
    Grid grid;uint64_t frame=0;unsigned candidates=8;
    std::vector<LightReservoir> fresh,temporal,spatial,history;
    std::vector<V3> output;
    explicit StaticReuse(Grid g):grid(g){
        if(!g.width||!g.height||uint64_t(g.width)*g.height>1048576)throw std::invalid_argument("grid capacity");
        size_t n=size_t(g.width)*g.height;fresh.resize(n);temporal.resize(n);spatial.resize(n);history.resize(n);output.resize(n);
    }
    // 同一run内frame推进；seed代表独立重复实验，不能用连续帧代替独立样本统计。
    // reverse只改变遍历次序，随机数由seed/frame/pixel/stage决定，用于验证没有读写反馈。
    void Step(const Scene& scene,uint64_t seed,bool useTemporal,bool useSpatial,bool reverse=false){
        const unsigned n=unsigned(output.size());
        auto idAt=[&](unsigned k){return reverse?n-1-k:k;};
        for(unsigned k=0;k<n;++k){unsigned id=idAt(k);V3 x=grid.Point(id);mis::Rng rng(seed+frame*0x9e3779b97f4a7c15ULL,uint64_t(id)*4);
            LightReservoir r;for(unsigned s=0;s<candidates;++s){auto y=Draw(scene,rng);auto e=Evaluate(scene,x,y);r.Update(y,e.target,e.proposal,rng.Uniform());}fresh[id]=r;}
        for(unsigned k=0;k<n;++k){unsigned id=idAt(k);V3 x=grid.Point(id);mis::Rng rng(seed+frame*0x9e3779b97f4a7c15ULL,uint64_t(id)*4+1);
            LightReservoir r;r.Merge(fresh[id],fresh[id].selectedTarget,rng.Uniform());
            if(useTemporal&&history[id].M){const auto& h=history[id];r.Merge(h,h.valid?Evaluate(scene,x,h.sample).target:0,rng.Uniform());}temporal[id]=r;}
        // 必须完整结束temporal阶段才读取邻域；每个目标只写自己的spatial[id]。
        for(unsigned k=0;k<n;++k){unsigned id=idAt(k);V3 x=grid.Point(id);mis::Rng rng(seed+frame*0x9e3779b97f4a7c15ULL,uint64_t(id)*4+2);
            LightReservoir r;
            if(useSpatial){int px=int(id%grid.width),py=int(id/grid.width);constexpr int dx[]{0,-1,1,0,0},dy[]{0,0,0,-1,1};
                for(unsigned j=0;j<5;++j){int nx=px+dx[j],ny=py+dy[j];if(nx<0||ny<0||nx>=int(grid.width)||ny>=int(grid.height))continue;
                    const auto& src=temporal[ny*grid.width+nx];r.Merge(src,src.valid?Evaluate(scene,x,src.sample).target:0,rng.Uniform());}
            }else r=temporal[id];spatial[id]=r;
            output[id]=r.valid&&Visible(scene,x,r.sample)?Evaluate(scene,x,r.sample).unshadowed*r.Normalization():V3{};
        }
        // 历史只保存空间复用前的temporal，避免本课把邻域代表反复反馈、M按邻居数指数增长。
        // 这是明确教学调度选择，不是所有生产ReSTIR实现必须如此；空间输出仍可能互相关联。
        history=temporal;++frame;
    }
};
}
