#include "reservoir.h"
#include <array>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <random>
#include <string>
using restir::Reservoir;
void Require(bool value,const char* text){if(!value)throw std::runtime_error(text);}
struct Rng {
    std::mt19937_64 engine{20261021};
    // 明确取53个随机bit，构造[0,1)；候选和替换使用各自新的一次抽取。
    double Next(){return double(engine()>>11)*0x1.0p-53;}
};
struct Moments {
    uint64_t n=0;double mean=0,m2=0;
    void Add(double x){++n;double delta=x-mean;mean+=delta/double(n);m2+=delta*(x-mean);}
    double Variance()const{return m2/double(n-1);}
    double SE()const{return std::sqrt(Variance()/double(n));}
};
constexpr std::array<double,4> q{.1,.2,.3,.4},target{1,2,4,8},f{1,2,0,8};
unsigned Candidate(double u){double c=0;for(unsigned i=0;i<3;++i){c+=q[i];if(u<c)return i;}return 3;}

// 独立枚举所有二候选序列及二次选择概率，不调用reservoir更新实现。
// correct和wrong*均对所有候选序列求期望，不是把一次随机结果称为无偏证明。
std::array<double,4> Enumerate(const std::array<double,4>& t){
    std::array<double,4> mean{};
    for(unsigned a=0;a<4;++a)for(unsigned b=0;b<4;++b){
        unsigned ids[]{a,b};double weights[]{t[a]/q[a],t[b]/q[b]},sum=weights[0]+weights[1];if(sum==0)continue;
        for(unsigned j=0;j<2;++j){unsigned y=ids[j];if(weights[j]==0)continue;
            double probability=q[a]*q[b]*weights[j]/sum,w=sum/(2*t[y]);
            mean[0]+=probability*w*f[y]; // 正确RIS估计。
            mean[1]+=probability*f[y]/q[y]; // 错误：二次筛选后仍使用原候选q。
            mean[2]+=probability*(sum/t[y])*f[y]; // 错误：遗漏候选数M。
            mean[3]+=probability*w*target[y]; // 错误：把遮挡贡献4当成可见。
        }
    }
    return mean;
}
int main(int argc,char** argv){
    if(argc!=2){std::cerr<<"verify_reservoir output-directory\n";return 2;}
    try{
        std::filesystem::path out=argv[1];std::filesystem::create_directories(out);
        Reservoir<unsigned> zero;Require(zero.Normalization()==0,"empty normalization");zero.Update(0,0,.5,.2);Require(!zero.valid&&zero.M==1&&zero.Normalization()==0,"zero target still counts");
        zero.Update(1,2,.5,.9);Require(zero.valid&&zero.M==2&&zero.Normalization()==1,"positive after zero must divide by both candidates");
        Reservoir<unsigned> single;single.Update(0,3,.25,.7);Require(single.Normalization()==4,"M1 reduces to inverse proposal");
        unsigned rejected=0;
        for(auto bad:std::array<std::array<double,3>,6>{{{-1,.5,.2},{1,0,.2},{1,.5,1},{1,.5,-.1},{INFINITY,.5,.2},{1,NAN,.2}}}){
            auto r=single;try{r.Update(2,bad[0],bad[1],bad[2]);}catch(const std::invalid_argument&){++rejected;}
            Require(r.M==single.M&&r.weightSum==single.weightSum&&r.sample==single.sample,"invalid input atomicity");
        }
        Require(rejected==6,"bad input rejection");
        auto exact=Enumerate(target);Require(std::abs(exact[0]-11)<1e-12&&std::abs(exact[2]-22)<1e-12&&std::abs(exact[3]-15)<1e-12,"enumerated expectation");Require(std::abs(exact[1]-4113.0/350.0)<1e-12,"wrong proposal exact biased expectation");
        auto missing=target;missing[3]=0;auto unsupported=Enumerate(missing);Require(std::abs(unsupported[0]-3)<1e-12,"missing target support loses bright contribution");
        // 零权候选只计非零M的反例：q=(1/2,1/2),f=t=(0,2),M=2。
        // 00返回0；01/10错误返回4；11返回4，总期望为3，正确答案为2。
        double wrongPositiveM=.25*0+.25*4+.25*4+.25*4;Require(wrongPositiveM==3,"zero-M negative fixture");
        Rng rng;constexpr unsigned trials=400000;std::array<uint64_t,3> chosen{};
        for(unsigned t=0;t<trials;++t){Reservoir<unsigned> r;for(unsigned i=0;i<3;++i)r.Update(i,double(i==0?1:i==1?2:7),1,rng.Next());++chosen[r.sample];}
        std::ofstream freq(out/"selection.csv");freq<<"sample,expected_probability,observed_probability\n"<<std::setprecision(12);
        for(unsigned i=0;i<3;++i){double p=i==0?.1:i==1?.2:.7,actual=double(chosen[i])/trials;Require(std::abs(actual-p)<6*std::sqrt(p*(1-p)/trials),"selection frequency");freq<<i<<','<<p<<','<<actual<<'\n';}
        std::array<Moments,5> stats;uint64_t winnerZero=0;
        for(unsigned t=0;t<trials;++t){Reservoir<unsigned> r;double nee=0;
            for(unsigned k=0;k<8;++k){unsigned id=Candidate(rng.Next());double value=f[id]/q[id];if(k==0)stats[0].Add(value);nee+=value;r.Update(id,target[id],q[id],rng.Next());}
            double w=r.Normalization();stats[1].Add(nee/8);stats[2].Add(w*f[r.sample]);stats[3].Add(f[r.sample]/q[r.sample]);stats[4].Add(w*target[r.sample]);if(f[r.sample]==0)++winnerZero;
        }
        const char* names[]{"NEE-1","NEE-8","RIS-8","wrong-original-q","wrong-no-visibility"};
        std::ofstream csv(out/"statistics.csv");csv<<"method,trials,mean,variance,standard_error,target_mean,delta\n"<<std::setprecision(12);
        for(unsigned i=0;i<5;++i){auto& m=stats[i];csv<<names[i]<<','<<m.n<<','<<m.mean<<','<<m.Variance()<<','<<m.SE()<<",11,"<<m.mean-11<<'\n';
            if(i<3)Require(std::abs(m.mean-11)<6*m.SE(),"correct estimator sample mean");
            else Require(std::abs(m.mean-11)>10*m.SE(),"negative control must be detected");
            std::cout<<names[i]<<" mean="<<m.mean<<" variance="<<m.Variance()<<" SE="<<m.SE()<<'\n';}
        Require(stats[2].Variance()>stats[1].Variance(),"resampling is not free variance reduction vs all evaluated candidates");
        std::ofstream audit(out/"checks.txt");audit<<std::setprecision(15)<<"CPU_only=1\ntrials="<<trials<<"\nreservoir_bytes="<<sizeof(Reservoir<unsigned>)<<"\nexact_RIS_M2="<<exact[0]<<"\nwrong_original_q_M2="<<exact[1]<<"\nwrong_omit_M="<<exact[2]<<"\nwrong_no_visibility="<<exact[3]<<"\nmissing_support="<<unsupported[0]<<"\nwrong_positive_M="<<wrongPositiveM<<"\nrejected_invalid="<<rejected<<"\noccluded_winners="<<winnerZero<<'\n';
        Require(freq&&csv&&audit,"report output");std::cout<<"RESERVOIR CPU VERIFY PASS\n";return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
