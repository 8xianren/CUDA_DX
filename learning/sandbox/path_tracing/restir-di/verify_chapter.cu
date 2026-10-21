#include "reuse_pipeline.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iomanip>
using namespace restir_di;
struct Moment {unsigned n=0;double mean=0,m2=0;void Add(double x){++n;double d=x-mean;mean+=d/n;m2+=d*(x-mean);}double Var()const{return m2/(n-1);}double SE()const{return std::sqrt(Var()/n);}};
// 章末对照补齐同一个12×8网格：NEE1、MIS2、单帧RIS8与16帧时空复用。
// 所有方法估计相同积分，但候选、阴影查询与历史成本不同，不能当作等时间性能比较。
// 统计固定第16帧，跨256个独立run；不把同一run的连续帧或不同像素当独立样本。
int main(int argc,char** argv){if(argc!=2)return 2;try{
    std::filesystem::path out=argv[1];std::filesystem::create_directories(out);Grid grid;constexpr unsigned n=96,runs=256;
    std::ofstream csv(out/"comparison.csv");csv<<std::setprecision(13)<<"scene,method,reference,mean,mean_pixel_variance,mean_squared_mean_error,failed_pixels\n";
    const char* names[]{"NEE1","MIS2","RIS8","ReSTIR-DI-frame16"};
    unsigned failures=0;
    for(bool blocked:{false,true}){Scene scene;scene.blocker=blocked;std::array<std::array<std::array<Moment,4>,n>,4> stats{};
        for(unsigned run=0;run<runs;++run){uint64_t seed=20261026+65537ULL*run;StaticReuse pipeline(grid);
            for(unsigned frame=0;frame<16;++frame)pipeline.Step(scene,seed,true,true);
            for(unsigned p=0;p<n;++p){mis::Rng rng(seed,p+1000);auto trial=Trial(scene,grid.Point(p),rng);V3 values[]{trial[0],trial[2],trial[4],pipeline.output[p]};
                for(unsigned m=0;m<4;++m){auto v=values[m];stats[m][p][0].Add(v.x);stats[m][p][1].Add(v.y);stats[m][p][2].Add(v.z);stats[m][p][3].Add(Luma(v));}}
        }
        std::array<V3,n> refs{},deltas{};double refMean=0;
        for(unsigned p=0;p<n;++p){refs[p]=Reference(scene,grid.Point(p),64);deltas[p]=refs[p]-Reference(scene,grid.Point(p),32);refMean+=Luma(refs[p])/n;}
        for(unsigned m=0;m<4;++m){double mean=0,var=0,err2=0;unsigned bad=0;
            for(unsigned p=0;p<n;++p){auto& a=stats[m][p];double rr[]{refs[p].x,refs[p].y,refs[p].z},dd[]{deltas[p].x,deltas[p].y,deltas[p].z};bool fail=false;
                for(unsigned c=0;c<3;++c)fail|=!std::isfinite(a[c].mean)||std::abs(a[c].mean-rr[c])>6*a[c].SE()+4*std::abs(dd[c])+1e-8;
                bad+=fail;mean+=a[3].mean/n;var+=a[3].Var()/n;double e=a[3].mean-Luma(refs[p]);err2+=e*e/n;}
            failures+=bad;csv<<(blocked?"blocked":"open")<<','<<names[m]<<','<<refMean<<','<<mean<<','<<var<<','<<err2<<','<<bad<<'\n';
            std::cout<<(blocked?"blocked":"open")<<' '<<names[m]<<" mean="<<mean<<" variance="<<var<<" failed="<<bad<<'\n';}
    }
    if(failures||!csv)throw std::runtime_error("chapter comparison failed");
    std::ofstream checks(out/"checks.txt");checks<<"CPU_only=1\nindependent_runs=256\nwidth=12\nheight=8\ncomparison_failed_pixels="<<failures<<"\n";
    if(!checks)throw std::runtime_error("chapter report write");std::cout<<"CHAPTER COMPARISON PASS\n";return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
