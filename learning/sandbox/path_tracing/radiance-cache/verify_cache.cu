#include "directional_cache.h"
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
using namespace cache_lesson;
void Require(bool b,const char* text){if(!b)throw std::runtime_error(text);}
struct Moment {unsigned n=0;double mean=0,m2=0;void Add(double x){++n;double d=x-mean;mean+=d/n;m2+=d*(x-mean);}double Var()const{return m2/(n-1);}double SE()const{return std::sqrt(Var()/n);}};
constexpr unsigned Points=5;
V3 Receiver(unsigned p){return {-.8+.25*p,.15,0};}
// 同一模型的独立面积积分：先积分灯，再积分次级面。缓存参考把后缀替换为确定性格点插值。
std::array<double,Points> Reference(unsigned ny,unsigned nl,const DirectionalCache* cache=nullptr){
    std::array<double,Points> sum{};double step=2./ny;
    for(unsigned j=0;j<ny;++j)for(unsigned i=0;i<ny;++i){V3 y{-1+(i+.5)*step,-1+(j+.5)*step,1};Coeff c;
        if(cache)Require(cache->Query(y,1,c),"reference cache coverage");else c=ExactCoefficients(y,nl);
        for(unsigned p=0;p<Points;++p){auto x=Receiver(p);double dx=x.x-y.x,dy=x.y-y.y,r2=dx*dx+dy*dy+1;
            sum[p]+=(.7/Pi)/(r2*r2)*(c.a+c.b*dx/std::sqrt(r2))*step*step;}
    }return sum;
}
int main(int argc,char** argv){if(argc!=2)return 2;try{
    std::filesystem::path out=argv[1];std::filesystem::create_directories(out);constexpr unsigned runs=4096,spp=64,training=64;
    // 双线性插值必须复现仿射场与边界节点；防止参考与采样共同使用错误索引而互相掩盖。
    DirectionalCache affine(3);for(unsigned i=0;i<affine.values.size();++i){auto y=affine.Node(i);affine.values[i]={2+y.x+.5*y.y,.1*y.x};}affine.valid=true;affine.revision=1;
    for(unsigned j=0;j<11;++j)for(unsigned i=0;i<11;++i){V3 y{-1+.2*i,-1+.2*j,1};Coeff c;Require(affine.Query(y,1,c)&&std::abs(c.a-(2+y.x+.5*y.y))<1e-14&&std::abs(c.b-.1*y.x)<1e-14,"affine interpolation");}
    Coeff sentinel{12,34};Require(!affine.Query({2,0,1},1,sentinel)&&!affine.Query({0,0,1},2,sentinel)&&sentinel.a==12,"invalid cache does not return black");
    DirectionalCache empty(3);Require(!empty.Query({0,0,1},1,sentinel),"untrained cache rejected");
    DirectionalCache coarseExact(3),fineExact(9);coarseExact.FillReference(96,1);fineExact.FillReference(96,1);
    // 格点精确复现与真正的方向依赖：固定y，两个相反横向出射方向必须得到不同辐亮度。
    for(unsigned p=0;p<fineExact.values.size();++p){Coeff c;Require(fineExact.Query(fineExact.Node(p),1,c)&&std::abs(c.a-fineExact.values[p].a)<1e-14&&std::abs(c.b-fineExact.values[p].b)<1e-14,"node reconstruction");}
    Coeff center;Require(fineExact.Query({0,0,1},1,center),"center query");
    double right=Tail(center,{0,0,1},{.5,0,0}),left=Tail(center,{0,0,1},{-.5,0,0});
    Require(right>left&&std::abs((right-left)-center.b/std::sqrt(1.25))<1e-14,"directional cache is not scalar irradiance");
    auto ref=Reference(192,48),low=Reference(96,24),coarseRef=Reference(192,0,&coarseExact),fineRef=Reference(192,0,&fineExact);
    auto coarseLow=Reference(96,0,&coarseExact),fineLow=Reference(96,0,&fineExact);
    std::array<std::array<Moment,Points>,5> stats{};uint64_t tailSamples=0,trainSamples=0,queries=0;
    // 三个查询方法使用相同前缀；两个确定性记录控制组去除更新噪声，仅保留空间近似和前缀噪声。
    // 所有统计跨独立run，随机缓存每次重训；不同接收点共享同run缓存，不假设像素间独立。
    for(unsigned run=0;run<runs;++run){DirectionalCache coarse(3),fine(9);coarse.Train(training,20261027+run*65537ULL,1);fine.Train(training,30261027+run*65537ULL,1);trainSamples+=(9+81)*training;
        for(unsigned p=0;p<Points;++p){mis::Rng rng(40261027+run*65537ULL,p);double sums[5]{};auto x=Receiver(p);
            for(unsigned s=0;s<spp;++s){auto y=DrawSecondary(rng);double beta=PrefixWeight(x,y);sums[0]+=beta*Tail(TailSample(y,DrawLight(rng)),y,x);++tailSamples;
                const DirectionalCache* caches[]{&coarse,&fine,&coarseExact,&fineExact};for(unsigned m=0;m<4;++m){Coeff c;Require(caches[m]->Query(y,1,c),"valid query");double v=beta*Tail(c,y,x);Require(std::isfinite(v)&&v>=0,"cache finite positive");sums[m+1]+=v;++queries;}}
            for(unsigned m=0;m<5;++m)stats[m][p].Add(sums[m]/spp);}
    }
    std::ofstream csv(out/"statistics.csv");csv<<std::setprecision(14)<<"pixel,x,method,physical_reference,method_reference,mean,variance,se,empirical_bias,expected_bias\n";
    const char* names[]{"full-tail","cache3-trained","cache9-trained","cache3-exact-nodes","cache9-exact-nodes"};double coarseBias2=0,fineBias2=0,maxRefDelta=0;unsigned coarseDetected=0;
    for(unsigned p=0;p<Points;++p){double err=std::abs(ref[p]-low[p]);maxRefDelta=std::max(maxRefDelta,err);coarseBias2+=std::pow(coarseRef[p]-ref[p],2)/Points;fineBias2+=std::pow(fineRef[p]-ref[p],2)/Points;
        for(unsigned m=0;m<5;++m){auto a=stats[m][p];double expected=m==0?ref[p]:((m==1||m==3)?coarseRef[p]:fineRef[p]);double qe=m==0?err:std::abs(expected-((m==1||m==3)?coarseLow[p]:fineLow[p]))+err;
            Require(std::abs(a.mean-expected)<6*a.SE()+4*qe+1e-8,"mean matches method integral");if(m==1&&std::abs(a.mean-ref[p])>10*a.SE()+4*err)++coarseDetected;
            csv<<p<<','<<Receiver(p).x<<','<<names[m]<<','<<ref[p]<<','<<expected<<','<<a.mean<<','<<a.Var()<<','<<a.SE()<<','<<a.mean-ref[p]<<','<<expected-ref[p]<<'\n';}
    }
    Require(fineBias2<coarseBias2*.05,"refining spatial cache reduces bias");Require(coarseDetected>=3,"coarse cache exposes bias");
    std::ofstream checks(out/"checks.txt");checks<<std::setprecision(14)<<"CPU_only=1\nindependent_runs="<<runs<<"\npaths_per_receiver="<<spp<<"\ntraining_samples_per_node="<<training<<"\nmax_reference_delta="<<maxRefDelta<<"\ncoarse_expected_bias_rms="<<std::sqrt(coarseBias2)<<"\nfine_expected_bias_rms="<<std::sqrt(fineBias2)<<"\ncoarse_detected_pixels="<<coarseDetected<<"\nfull_tail_light_samples="<<tailSamples<<"\ncache_training_light_samples="<<trainSamples<<"\ncache_queries_all_four_modes="<<queries<<"\ncoarse_coefficient_bytes="<<9*sizeof(Coeff)<<"\nfine_coefficient_bytes="<<81*sizeof(Coeff)<<"\ndirectional_right="<<right<<"\ndirectional_left="<<left<<'\n';
    Require(csv&&checks,"reports written");std::cout<<"CACHE VERIFY PASS coarseBias="<<std::sqrt(coarseBias2)<<" fineBias="<<std::sqrt(fineBias2)<<" coarseDetected="<<coarseDetected<<" refDelta="<<maxRefDelta<<'\n';return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
