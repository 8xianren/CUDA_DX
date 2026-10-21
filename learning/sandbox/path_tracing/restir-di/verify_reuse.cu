#include "reuse_pipeline.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iomanip>
using namespace restir_di;
void Require(bool b,const char* text){if(!b)throw std::runtime_error(text);}
struct Moments {uint64_t n=0;double mean=0,m2=0;void Add(double v){++n;double d=v-mean;mean+=d/n;m2+=d*(v-mean);}double Var()const{return m2/(n-1);}double SE()const{return std::sqrt(Var()/n);}};
int main(int argc,char** argv){
    if(argc!=2){std::cerr<<"verify_reuse output-directory\n";return 2;}
    try{
        std::filesystem::path out=argv[1];std::filesystem::create_directories(out);Grid grid;unsigned n=grid.width*grid.height;
        constexpr unsigned frames=16,runs=256;const char* names[]{"fresh","temporal","spatial","both"};
        std::ofstream curve(out/"frames.csv"),pixels(out/"pixels.csv"),checks(out/"checks.txt");
        curve<<std::setprecision(12)<<"scene,mode,frame,mean,reference,mean_variance,mean_mse,mean_error_squared,failed_pixels\n";
        pixels<<std::setprecision(12)<<"scene,mode,pixel,ref_r,ref_g,ref_b,mean_r,mean_g,mean_b,noisy_r,noisy_g,noisy_b\n";
        double finalVariance[2][4]{};uint64_t maxHistory=0,maxSpatial=0;unsigned failuresTotal=0;
        for(unsigned sc=0;sc<2;++sc){Scene scene;scene.blocker=sc!=0;const char* sceneName=sc?"blocked":"open";
            // stats为每帧每位置跨独立run的统计；没有把16个相关历史帧混在同一个估计中。
            using RGBMom=std::array<Moments,4>;
            std::array<std::vector<RGBMom>,4> stats;std::array<std::vector<V3>,4> snapshot;
            for(unsigned m=0;m<4;++m){stats[m].resize(frames*n);snapshot[m].resize(n);}
            std::vector<V3> refs(n),errors(n);double meanRef=0;
            for(unsigned p=0;p<n;++p){refs[p]=Reference(scene,grid.Point(p),128);auto c=Reference(scene,grid.Point(p),64);errors[p]={std::abs(refs[p].x-c.x),std::abs(refs[p].y-c.y),std::abs(refs[p].z-c.z)};meanRef+=Luma(refs[p])/n;}
            for(unsigned run=0;run<runs;++run){std::array<StaticReuse,4> pipelines{StaticReuse(grid),StaticReuse(grid),StaticReuse(grid),StaticReuse(grid)};
                for(unsigned frame=0;frame<frames;++frame)for(unsigned m=0;m<4;++m){auto& pipe=pipelines[m];pipe.Step(scene,20261023+run*65537ULL,(m&1)!=0,(m&2)!=0);
                    for(unsigned p=0;p<n;++p){V3 v=pipe.output[p];Require(std::isfinite(Luma(v))&&v.x>=0&&v.y>=0&&v.z>=0,"finite output");auto& s=stats[m][frame*n+p];s[0].Add(v.x);s[1].Add(v.y);s[2].Add(v.z);s[3].Add(Luma(v));
                        if(run==0&&frame==frames-1)snapshot[m][p]=v;
                        uint64_t expected=8*((m&1)?frame+1:1);Require(pipe.history[p].M==expected,"history contains only temporal candidates");
                        unsigned px=p%grid.width,py=p/grid.width,neighbors=1+(px>0)+(px+1<grid.width)+(py>0)+(py+1<grid.height);
                        Require(pipe.spatial[p].M==expected*((m&2)?neighbors:1),"spatial represented count");maxHistory=std::max(maxHistory,pipe.history[p].M);maxSpatial=std::max(maxSpatial,pipe.spatial[p].M);}
                }
            }
            for(unsigned m=0;m<4;++m)for(unsigned frame=0;frame<frames;++frame){double mean=0,var=0,err2=0;unsigned failed=0;
                for(unsigned p=0;p<n;++p){auto& s=stats[m][frame*n+p];double ref=Luma(refs[p]),error=s[3].mean-ref;mean+=s[3].mean/n;var+=s[3].Var()/n;err2+=error*error/n;
                    double rr[]{refs[p].x,refs[p].y,refs[p].z},ee[]{errors[p].x,errors[p].y,errors[p].z};bool bad=false;for(unsigned c=0;c<3;++c)if(std::abs(s[c].mean-rr[c])>6*s[c].SE()+4*ee[c]+1e-8)bad=true;failed+=bad;
                    if(frame==frames-1){auto v=snapshot[m][p];pixels<<sceneName<<','<<names[m]<<','<<p<<','<<refs[p].x<<','<<refs[p].y<<','<<refs[p].z<<','<<s[0].mean<<','<<s[1].mean<<','<<s[2].mean<<','<<v.x<<','<<v.y<<','<<v.z<<'\n';}}
                // 经验MSE=样本方差*(R-1)/R+(样本均值-reference)^2，不假装已知真实偏差。
                curve<<sceneName<<','<<names[m]<<','<<frame<<','<<mean<<','<<meanRef<<','<<var<<','<<var*(runs-1)/runs+err2<<','<<err2<<','<<failed<<'\n';
                failuresTotal+=failed;if(frame==frames-1){finalVariance[sc][m]=var;std::cout<<sceneName<<' '<<names[m]<<" final mean="<<mean<<" variance="<<var<<" failures="<<failed<<'\n';}}
        }
        Require(failuresTotal==0,"independent-run RGB mean checks");
        // 只在无遮挡、目标接近完整贡献的受控场景要求明显的开关噪声差异；有板结果照实报告。
        Require(finalVariance[0][3]<finalVariance[0][1]*.7&&finalVariance[0][3]<finalVariance[0][2]*.7,"turning off either reuse must expose increased noise in open scene");
        // 反序遍历不能改变结果：若空间阶段读写同一个buffer，这个检查通常会暴露顺序依赖。
        Scene scene;StaticReuse forward(grid),reverse(grid);for(unsigned f=0;f<4;++f){forward.Step(scene,71,true,true);reverse.Step(scene,71,true,true,true);for(unsigned p=0;p<n;++p){auto a=forward.output[p],b=reverse.output[p];Require(a.x==b.x&&a.y==b.y&&a.z==b.z,"stage buffer traversal independence");}}
        checks<<"CPU_only=1\nwidth="<<grid.width<<"\nheight="<<grid.height<<"\nframes="<<frames<<"\nindependent_runs="<<runs<<"\nfailed_method_frame_pixels="<<failuresTotal<<"\nmax_temporal_M="<<maxHistory<<"\nmax_spatial_M="<<maxSpatial<<"\nreverse_traversal_bit_exact=1\n";
        Require(curve&&pixels&&checks,"reuse reports");std::cout<<"STATIC REUSE VERIFY PASS\n";return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
