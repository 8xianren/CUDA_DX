#pragma once
#include "throughput_math.h"
#include <vector>
namespace throughput {
enum class Mode {Cosine,Uniform,WrongMissingPdf,WrongEmissionOrder};
struct VertexRecord {
    RGB betaBefore{},contribution{},sum{},betaAfter{};
    double cosine=0,pdf=0,distance=0,sphereResidual=0;
};
// 最多K次散射，最多访问K+1个表面。相机位于球心，主射线沿+Z，所以首命中(0,0,1)。
// 每条路径独占局部状态；没有GPU资源/异步操作。返回记录由调用者vector拥有。
inline std::vector<VertexRecord> Trace(RGB rho,RGB emission,int maxScatters,Mode mode,uint64_t seed,uint64_t stream){
    for(int c=0;c<3;++c)if(!(rho[c]>=0&&rho[c]<1&&emission[c]>=0))throw std::runtime_error("invalid cavity material");
    if(maxScatters<0||maxScatters>64)throw std::runtime_error("invalid scatter limit");
    mis::Rng rng(seed,stream);RGB beta{1,1,1},sum{};Vec position{0,0,1};
    std::vector<VertexRecord> records;records.reserve(maxScatters+1);
    for(int depth=0;depth<=maxScatters;++depth){
        VertexRecord record;record.betaBefore=beta;
        // 正确顺序：当前顶点的自发光用抵达时的beta；当前材质只影响随后散射的光。
        // 故意错误分支把当前rho提前乘到自发光上，相当于无故多滤一次材质颜色。
        for(int c=0;c<3;++c){record.contribution[c]=beta[c]*emission[c]*(mode==Mode::WrongEmissionOrder?rho[c]:1);
            sum[c]+=record.contribution[c];}
        record.sum=sum;record.betaAfter=beta;
        if(depth==maxScatters){records.push_back(record);break;} // 仍须先收取最后顶点的发光。
        Vec normal=position*(-1); // 球腔内表面朝球心，和普通外表面法线方向相反。
        bool cosineSampling=mode==Mode::Cosine||mode==Mode::WrongEmissionOrder;
        auto sample=Sample(normal,rng,cosineSampling);record.cosine=sample.cosine;record.pdf=sample.pdf;
        for(int c=0;c<3;++c){
            double f=rho[c]/mis::pi;
            // 核心递推。保留f*cos/pdf写法，不能把所有BSDF/采样器都简化成beta*=rho。
            double factor=f*sample.cosine;
            if(mode!=Mode::WrongMissingPdf)factor/=sample.pdf;
            beta[c]*=factor;if(!std::isfinite(beta[c]))throw std::runtime_error("nonfinite throughput");
        }
        record.betaAfter=beta;
        position=NextSphereHit(position,sample.wi,record.distance,record.sphereResidual);
        records.push_back(record);
    }
    return records;
}
}
