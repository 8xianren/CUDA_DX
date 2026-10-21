#include "direct_scene.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iomanip>
using namespace restir_di;
void Require(bool b,const char* text){if(!b)throw std::runtime_error(text);}
struct Moment {uint64_t n=0;double mean=0,m2=0;void Add(double v){++n;double d=v-mean;mean+=d/n;m2+=d*(v-mean);}double Var()const{return m2/(n-1);}double SE()const{return std::sqrt(Var()/n);}};
int main(int argc,char** argv){
    if(argc!=2){std::cerr<<"verify_direct output-directory\n";return 2;}
    try{
        std::filesystem::path out=argv[1];std::filesystem::create_directories(out);
        constexpr unsigned width=24,height=16,trials=4096;const char* names[]{"NEE1","BSDF1","MIS2","NEE8","RIS8","wrong-no-visibility"};
        std::ofstream data(out/"pixels.csv"),summary(out/"summary.csv");data<<std::setprecision(12)<<"scene,pixel,method,ref_r,ref_g,ref_b,mean_r,mean_g,mean_b,noisy_r,noisy_g,noisy_b,ref_luma,mean_luma,variance_luma,se_luma,reference_delta\n";
        summary<<std::setprecision(12)<<"scene,method,mean_luma,reference_luma,mean_variance,mean_squared_mean_error,aggregate_se,outside_6se\n";
        double maxReferenceDelta=0,maxPointDelta=0;uint64_t checked=0;
        for(bool blocked:{false,true}){Scene scene;scene.blocker=blocked;const char* sceneName=blocked?"blocked":"open";
            std::array<double,Methods> mean{},variance{},bias2{},sumSe2{};std::array<unsigned,Methods> failures{};double refMean=0;
            // 更高分辨率参考只用于四个独立位置，检查低分辨率求积是否遗漏遮挡边界。
            for(V3 p:std::array<V3,4>{{{0,0,0},{-.8,.1,0},{.6,-.3,0},{1,1,0}}}){
                V3 a=Reference(scene,p,256),b=Reference(scene,p,512);maxPointDelta=std::max(maxPointDelta,std::abs(Luma(a-b)));Require(std::abs(Luma(a-b))<1e-5,"high resolution quadrature stability");}
            for(unsigned pixel=0;pixel<width*height;++pixel){V3 p{-1.2+2.4*(pixel%width+.5)/width,-.8+1.6*(pixel/width+.5)/height,0};
                auto ref=Reference(scene,p,64),coarse=Reference(scene,p,32);double rd=std::abs(Luma(ref-coarse));maxReferenceDelta=std::max(maxReferenceDelta,rd);double refY=Luma(ref);refMean+=refY;
                std::array<std::array<Moment,4>,Methods> stats{};std::array<V3,Methods> noisy{};
                mis::Rng rng(20261021,pixel+1);for(unsigned t=0;t<trials;++t){auto v=Trial(scene,p,rng);if(t==0)noisy=v;
                    for(unsigned m=0;m<Methods;++m){Require(std::isfinite(Luma(v[m]))&&v[m].x>=0&&v[m].y>=0&&v[m].z>=0,"finite nonnegative output");stats[m][0].Add(v[m].x);stats[m][1].Add(v[m].y);stats[m][2].Add(v[m].z);stats[m][3].Add(Luma(v[m]));}}
                for(unsigned m=0;m<Methods;++m){auto& st=stats[m];double delta=st[3].mean-refY;
                    // 每像素逐RGB检查，容许6SE与保守数值参考差；这不是一般无偏性的数学证明。
                    std::array<double,3> refs{ref.x,ref.y,ref.z},diff{std::abs(ref.x-coarse.x),std::abs(ref.y-coarse.y),std::abs(ref.z-coarse.z)};
                    bool fail=false;for(unsigned c=0;c<3;++c)if(std::abs(st[c].mean-refs[c])>6*st[c].SE()+4*diff[c]+1e-8)fail=true;
                    failures[m]+=fail;mean[m]+=st[3].mean;variance[m]+=st[3].Var();bias2[m]+=delta*delta;sumSe2[m]+=st[3].SE()*st[3].SE();
                    data<<sceneName<<','<<pixel<<','<<names[m]<<','<<ref.x<<','<<ref.y<<','<<ref.z<<','<<st[0].mean<<','<<st[1].mean<<','<<st[2].mean<<','<<noisy[m].x<<','<<noisy[m].y<<','<<noisy[m].z<<','<<refY<<','<<st[3].mean<<','<<st[3].Var()<<','<<st[3].SE()<<','<<rd<<'\n';++checked;}
            }
            double count=width*height;for(unsigned m=0;m<Methods;++m){double se=std::sqrt(sumSe2[m])/count;
                summary<<sceneName<<','<<names[m]<<','<<mean[m]/count<<','<<refMean/count<<','<<variance[m]/count<<','<<bias2[m]/count<<','<<se<<','<<failures[m]<<'\n';
                if(m<5||!blocked)Require(failures[m]==0,"correct method outside per-pixel RGB tolerance");}
            if(blocked)Require(failures[5]>width*height/2&&(mean[5]-refMean)/count>.05,"omitting visibility must expose leakage");
            std::cout<<sceneName<<" PASS reference="<<refMean/count<<" RIS="<<mean[4]/count<<" wrong="<<mean[5]/count<<" leakage_pixels="<<failures[5]<<'\n';
        }
        std::ofstream checks(out/"checks.txt");checks<<std::setprecision(12)<<"CPU_only=1\nwidth="<<width<<"\nheight="<<height<<"\ntrials_per_pixel="<<trials<<"\nchecked_method_pixels="<<checked<<"\nmax_grid_reference_delta="<<maxReferenceDelta<<"\nmax_point_reference_delta="<<maxPointDelta<<"\nlight_sample_bytes="<<sizeof(LightSample)<<"\nreservoir_bytes="<<sizeof(restir::Reservoir<LightSample>)<<'\n';
        Require(data&&summary&&checks,"report output");std::cout<<"DIRECT LIGHTING CPU VERIFY PASS\n";return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
