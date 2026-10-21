#include "direct_scene.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iomanip>
using namespace restir_di;
void Require(bool b,const char* s){if(!b)throw std::runtime_error(s);}
struct Moment {uint64_t n=0;double mean=0,m2=0;void Add(double x){++n;double d=x-mean;mean+=d/n;m2+=d*(x-mean);}double Var()const{return m2/(n-1);}double SE()const{return std::sqrt(Var()/n);}};
using R=restir::Reservoir<LightSample>;
R Build(const Scene& scene,V3 x,unsigned count,mis::Rng& rng){R r;for(unsigned k=0;k<count;++k){auto y=Draw(scene,rng);auto e=Evaluate(scene,x,y);r.Update(y,e.target,e.proposal,rng.Uniform());}return r;}
double Output(const Scene& s,V3 x,const R& r){if(!r.valid)return 0;return Visible(s,x,r.sample)?Evaluate(s,x,r.sample).target*r.Normalization():0;}

// 独立二灯枚举：q=(1/2,1/2)，目标F=(2,3)、t_dst=(1,4)。
// 源A只有1候选；源B有2候选且评分(4,1)。遍历原始候选与B获选事件，
// 再对合并选择求条件期望。此函数不调用Merge，实现与验证路径分开。
std::array<double,3> Enumerate(){
    double f[]{2,3},t[]{1,4},tb[]{4,1};std::array<double,3> result{};
    for(unsigned a=0;a<2;++a)for(unsigned b=0;b<2;++b)for(unsigned c=0;c<2;++c){
        unsigned candidates[]{b,c};double sumB=2*(tb[b]+tb[c]);
        for(unsigned selected=0;selected<2;++selected){unsigned y=candidates[selected];double probability=.125*(2*tb[y]/sumB);
            double wA=2,wB=sumB/(2*tb[y]);unsigned ids[]{a,y};double norms[]{wA,wB};
            double mergedWeights[]{t[a]*wA,t[y]*wB*2},total=mergedWeights[0]+mergedWeights[1];
            for(unsigned j=0;j<2;++j)result[0]+=probability*(mergedWeights[j]/total)*f[ids[j]]*total/(3*t[ids[j]]);
            // 负对照1：分子忘记乘源M，最终分母却仍使用总M=3。
            double badTotal=t[a]*wA+t[y]*wB;for(unsigned j=0;j<2;++j)result[1]+=probability*(t[ids[j]]*norms[j]/badTotal)*f[ids[j]]*badTotal/(3*t[ids[j]]);
            // 负对照2：把两个选中样本当成q=1/2的两个新原始候选。
            double naiveTotal=2*(t[a]+t[y]);for(unsigned j=0;j<2;++j)result[2]+=probability*(2*t[ids[j]]/naiveTotal)*f[ids[j]]*naiveTotal/(2*t[ids[j]]);
        }
    }return result;
}
int main(int argc,char** argv){
    if(argc!=2){std::cerr<<"verify_merge output-directory\n";return 2;}
    try{
        std::filesystem::path out=argv[1];std::filesystem::create_directories(out);
        auto exact=Enumerate();Require(std::abs(exact[0]-5)<1e-12&&std::abs(exact[1]-10./3)<1e-12&&std::abs(exact[2]-4.85)<1e-12,"enumerated merge expectations");
        restir::Reservoir<unsigned> empty,zero,one;zero.Update(0,0,.5,.2);one.Update(1,2,.5,.8);
        empty.Merge(zero,0,.2);Require(empty.M==1&&!empty.valid,"zero group count");empty.Merge(one,2,.9);Require(empty.M==2&&empty.Normalization()==1,"zero+positive group normalization");
        unsigned rejected=0;try{one.Merge(one,2,.1);}catch(const std::invalid_argument&){++rejected;}
        try{empty.Merge(one,-1,.1);}catch(const std::invalid_argument&){++rejected;}
        Require(rejected==2&&one.M==1&&empty.M==2,"invalid merge no partial updates");
        // 同目标固定候选的两级选择概率应等于平铺选择：在每次试验中分别随机建组与合并。
        constexpr unsigned count=200000;mis::Rng fixture(20261022,1);unsigned hits[3]{};
        for(unsigned i=0;i<count;++i){restir::Reservoir<unsigned> a,b,c;a.Update(0,1,1,fixture.Uniform());a.Update(1,2,1,fixture.Uniform());b.Update(2,7,1,fixture.Uniform());
            c.Merge(a,a.sample==0?1:2,fixture.Uniform());c.Merge(b,7,fixture.Uniform());Require(c.M==3&&std::abs(c.weightSum-10)<1e-12,"same-target sufficient weight sum");++hits[c.sample];}
        std::ofstream freq(out/"selection.csv");freq<<"sample,expected,observed\n";
        for(unsigned i=0;i<3;++i){double p=i==0?.1:i==1?.2:.7,observed=double(hits[i])/count;Require(std::abs(observed-p)<6*std::sqrt(p*(1-p)/count),"hierarchical selection probability");freq<<i<<','<<p<<','<<observed<<'\n';}
        Scene scene;constexpr unsigned trials=100000;
        const char* names[]{"merged-4+12","naive-original-q","wrong-count","source-once","duplicate-source"};
        std::ofstream csv(out/"geometry.csv");csv<<std::setprecision(12)<<"point,method,reference,mean,variance,se,reference_delta\n";
        unsigned wrongNaive=0,wrongCount=0;
        for(unsigned p=0;p<5;++p){V3 x{-1.+p*.5,.1,0},xa{x.x-.6,x.y+.25,0},xb{x.x+.6,x.y-.25,0};
            double ref=Luma(Reference(scene,x,256)),delta=std::abs(ref-Luma(Reference(scene,x,128)));std::array<Moment,5> stats;mis::Rng rng(20261022,p+9);
            for(unsigned trial=0;trial<trials;++trial){auto a=Build(scene,xa,4,rng),b=Build(scene,xb,12,rng);R merged,naive,bad;
                for(const auto* src:{&a,&b}){auto e=Evaluate(scene,x,src->sample);double u=rng.Uniform();merged.Merge(*src,e.target,u);naive.Update(src->sample,e.target,e.proposal,u);
                    // 通过Update编码“忘记源M”的错误选择权，再错误地使用总M=16。
                    bad.Update(src->sample,e.target,1/src->Normalization(),u);}
                bad.M=16;Require(merged.M==16&&naive.M==2,"represented candidate counts");
                stats[0].Add(Output(scene,x,merged));stats[1].Add(Output(scene,x,naive));stats[2].Add(Output(scene,x,bad));
                // 同一源副本合并两次：两次都是同一个样本，不创造独立信息。
                R duplicate;double t=Evaluate(scene,x,a.sample).target;duplicate.Merge(a,t,rng.Uniform());duplicate.Merge(a,t,rng.Uniform());
                double single=Output(scene,x,a),twice=Output(scene,x,duplicate);Require(std::abs(single-twice)<1e-12,"duplicate cannot improve independent information");
                stats[3].Add(single);stats[4].Add(twice);
            }
            for(unsigned m=0;m<5;++m){auto& s=stats[m];csv<<p<<','<<names[m]<<','<<ref<<','<<s.mean<<','<<s.Var()<<','<<s.SE()<<','<<delta<<'\n';
                if(m==0||m>=3)Require(std::abs(s.mean-ref)<6*s.SE()+4*delta+1e-8,"geometry unbiased merge check");
                else if(std::abs(s.mean-ref)>10*s.SE()+4*delta){if(m==1)++wrongNaive;else ++wrongCount;}}
            std::cout<<"point="<<p<<" reference="<<ref<<" merged="<<stats[0].mean<<" naive="<<stats[1].mean<<" duplicate variance="<<stats[4].Var()<<'\n';
        }
        Require(wrongNaive>=3&&wrongCount==5,"wrong merge controls must expose bias");
        std::ofstream check(out/"checks.txt");check<<std::setprecision(12)<<"CPU_only=1\nexact_correct="<<exact[0]<<"\nexact_missing_M="<<exact[1]<<"\nexact_naive_q="<<exact[2]<<"\ngeometry_trials_per_point="<<trials<<"\nnaive_failed_points="<<wrongNaive<<"\nwrong_count_failed_points="<<wrongCount<<"\nduplicate_per_trial_equal=1\ninvalid_rejected="<<rejected<<'\n';
        Require(csv&&freq&&check,"merge reports");std::cout<<"RESERVOIR MERGE VERIFY PASS\n";return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
