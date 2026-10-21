#include "dynamic_reuse.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iomanip>
using namespace restir_di;
void Require(bool b,const char* s){if(!b)throw std::runtime_error(s);}
struct Moment {uint64_t n=0;double mean=0,m2=0;void Add(double x){++n;double d=x-mean;mean+=d/n;m2+=d*(x-mean);}double Var()const{return m2/(n-1);}double SE()const{return std::sqrt(Var()/n);}};
struct Frame {Scene scene;CameraGrid camera;SurfaceConfig surface;const char* name="initial";};
std::vector<Frame> Sequence(){
    std::vector<Frame> f(12);f[1]=f[0];f[1].name="stationary";
    f[2]=f[1];f[2].name="camera-one-pixel";f[2].camera.centerX=.2;
    f[3]=f[2];f[3].name="moving-blocker-camera-z";f[3].scene.bx0=-.65;f[3].scene.bx1=-.1;f[3].camera.z=4.3;
    f[4]=f[3];f[4].name="surface-depth";f[4].surface.height=.25;
    f[5]=f[4];f[5].name="surface-normal";f[5].surface.slope=.4;
    f[6]=f[5];f[6].name="surface-identity";f[6].surface.identity=2;
    f[7]=f[6];f[7].name="camera-cut";f[7].camera.cut=true;
    f[8]=f[7];f[8].name="resize";f[8].camera.cut=false;f[8].camera.width=10;f[8].camera.height=6;
    f[9]=f[8];f[9].name="light-revision";f[9].camera.lightRevision=2;f[9].scene.lights[2].emission=f[9].scene.lights[2].emission*.5;
    f[10]=f[9];f[10].name="surface-hole";f[10].surface.hideRight=true;
    f[11]=f[10];f[11].name="surface-reappears";f[11].surface.hideRight=false;return f;
}
int main(int argc,char** argv){
    if(argc!=2){std::cerr<<"verify_dynamic output-directory\n";return 2;}
    try{
        std::filesystem::path out=argv[1];std::filesystem::create_directories(out);auto frames=Sequence();constexpr unsigned runs=256;
        // 解析投影锚点：像素中心自映射与半开窗口边界；不依赖蒙特卡洛统计。
        CameraGrid c;SurfaceConfig g;for(unsigned p=0;p<c.width*c.height;++p)Require(Reproject(MakeSurface(c,g,p).position,c)==int(p),"identity reproject");
        Require(Reproject({1.2,0,0},c)==-1&&Reproject({-1.2,0,0},c)==int(c.height/2*c.width),"half-open projection bounds");
        Scene s;Surface x=MakeSurface(c,g,0);LightSample y{1,.3,.7};auto a=Evaluate(s,x.position,y),b=EvaluateSurface(s,x,y);Require(std::abs(a.target-b.target)<1e-14&&Visible(s,x.position,y)==VisibleSurface(s,x,y),"flat geometry regression");
        std::vector<std::vector<std::array<Moment,4>>> stats(frames.size());std::vector<std::vector<V3>> reference(frames.size()),error(frames.size()),snapshot(frames.size());
        for(unsigned f=0;f<frames.size();++f){auto& cfg=frames[f];unsigned n=cfg.camera.width*cfg.camera.height;stats[f].resize(n);reference[f].resize(n);error[f].resize(n);snapshot[f].resize(n);
            for(unsigned p=0;p<n;++p){auto surf=MakeSurface(cfg.camera,cfg.surface,p);reference[f][p]=ReferenceSurface(cfg.scene,surf,64);auto low=ReferenceSurface(cfg.scene,surf,32),d=reference[f][p]-low;error[f][p]={std::abs(d.x),std::abs(d.y),std::abs(d.z)};}}
        std::vector<Moment> stale(96);std::vector<V3> staleSnapshot(96);uint64_t visibilityChanges=0,resetMatches=0;unsigned countFailures=0;
        std::ofstream reject(out/"rejections.csv"),images(out/"pixels.csv"),summary(out/"frames.csv"),negative(out/"stale-visibility.csv");
        reject<<"frame,name,accepted,no-history,outside,invalid,identity,normal,depth,reset,spatial_rejected\n";
        for(unsigned run=0;run<runs;++run){DynamicReuse pipeline;uint64_t seed=20261024+run*65537ULL;
            for(unsigned f=0;f<frames.size();++f){const auto& cfg=frames[f];pipeline.Step(cfg.scene,cfg.camera,cfg.surface,seed,f);unsigned n=unsigned(pipeline.output.size());
                auto count=[&](Reject r){return pipeline.counts[unsigned(r)];};
                if(f==0)Require(count(Reject::NoHistory)==96,"initial no history");
                if(f==1||f==3)Require(count(Reject::Accepted)==96,"stationary / camera-z mapping");
                if(f==2){Require(count(Reject::Accepted)==88&&count(Reject::Outside)==8,"camera translation bounds");for(unsigned p=0;p<n;++p)Require(pipeline.sourceIndex[p]==(p%12==11?-1:int(p+1)),"analytic one-pixel reproject");}
                if(f==4)Require(count(Reject::Depth)==96,"actual plane depth change");
                if(f==5)Require(count(Reject::Normal)==96,"actual plane normal change");
                if(f==6)Require(count(Reject::Identity)==96,"actual surface identity change");
                if(f>=7&&f<=9){Require(count(Reject::Reset)==n,"global reset reason");DynamicReuse fresh;fresh.Step(cfg.scene,cfg.camera,cfg.surface,seed,f,false,true);
                    for(unsigned p=0;p<n;++p){V3 d=pipeline.output[p]-fresh.output[p];Require(std::abs(d.x)+std::abs(d.y)+std::abs(d.z)<1e-12&&pipeline.temporal[p].M==8,"reset equals fresh same random identity");++resetMatches;}}
                if(f==10)Require(count(Reject::Accepted)==24,"surface hole valid count");
                if(f==11)Require(count(Reject::Accepted)==24&&count(Reject::Invalid)==36,"disocclusion rejects missing surface");
                if(run==0){reject<<f<<','<<cfg.name;for(auto v:pipeline.counts)reject<<','<<v;reject<<','<<pipeline.spatialRejected<<'\n';snapshot[f]=pipeline.output;}
                for(unsigned p=0;p<n;++p){auto v=pipeline.output[p];Require(std::isfinite(Luma(v))&&v.x>=0&&v.y>=0&&v.z>=0,"dynamic finite RGB");auto& m=stats[f][p];m[0].Add(v.x);m[1].Add(v.y);m[2].Add(v.z);m[3].Add(Luma(v));
                    if(pipeline.surfaces[p].valid){uint64_t expected=8;if(pipeline.reasons[p]==Reject::Accepted)Require(pipeline.temporal[p].M>8,"accepted adds history");else Require(pipeline.temporal[p].M==expected,"rejected history fresh only");}
                    else Require(pipeline.temporal[p].M==0&&Luma(v)==0,"invalid surface cleared");
                    if(f==3){const auto& r=pipeline.spatial[p];auto current=pipeline.surfaces[p];bool oldV=VisibleSurface(frames[2].scene,current,r.sample),newV=VisibleSurface(cfg.scene,current,r.sample);visibilityChanges+=oldV!=newV;
                        V3 wrong=oldV?EvaluateSurface(cfg.scene,current,r.sample).unshadowed*r.Normalization():V3{};stale[p].Add(Luma(wrong));if(run==0)staleSnapshot[p]=wrong;}
                }
            }
        }
        images<<std::setprecision(12)<<"frame,name,width,height,pixel,ref_r,ref_g,ref_b,mean_r,mean_g,mean_b,noisy_r,noisy_g,noisy_b\n";
        summary<<std::setprecision(12)<<"frame,name,reference,mean,mean_variance,failed_pixels\n";
        for(unsigned f=0;f<frames.size();++f){unsigned fail=0;double mean=0,ref=0,var=0;auto n=stats[f].size();
            for(unsigned p=0;p<n;++p){auto& m=stats[f][p];auto r=reference[f][p],e=error[f][p],v=snapshot[f][p];double rr[]{r.x,r.y,r.z},ee[]{e.x,e.y,e.z};bool bad=false;
                for(unsigned k=0;k<3;++k)if(std::abs(m[k].mean-rr[k])>6*m[k].SE()+4*ee[k]+1e-8)bad=true;fail+=bad;mean+=m[3].mean/n;ref+=Luma(r)/n;var+=m[3].Var()/n;
                images<<f<<','<<frames[f].name<<','<<frames[f].camera.width<<','<<frames[f].camera.height<<','<<p<<','<<r.x<<','<<r.y<<','<<r.z<<','<<m[0].mean<<','<<m[1].mean<<','<<m[2].mean<<','<<v.x<<','<<v.y<<','<<v.z<<'\n';}
            countFailures+=fail;summary<<f<<','<<frames[f].name<<','<<ref<<','<<mean<<','<<var<<','<<fail<<'\n';std::cout<<frames[f].name<<" reference="<<ref<<" mean="<<mean<<" failed="<<fail<<'\n';}
        unsigned staleBad=0;double staleMean=0,newRef=0;negative<<std::setprecision(12)<<"pixel,reference,stale_mean,stale_se,wrong_r,wrong_g,wrong_b\n";
        for(unsigned p=0;p<96;++p){double ref=Luma(reference[3][p]);if(std::abs(stale[p].mean-ref)>10*stale[p].SE()+4*Luma(error[3][p])+1e-8)++staleBad;staleMean+=stale[p].mean/96;newRef+=ref/96;auto v=staleSnapshot[p];negative<<p<<','<<ref<<','<<stale[p].mean<<','<<stale[p].SE()<<','<<v.x<<','<<v.y<<','<<v.z<<'\n';}
        Require(countFailures==0,"dynamic RGB mean checks");Require(staleBad>=30&&visibilityChanges>0&&std::abs(staleMean-newRef)>.03,"stale visibility must expose moving-shadow error");
        std::ofstream checks(out/"checks.txt");checks<<std::setprecision(12)<<"CPU_only=1\nindependent_runs="<<runs<<"\nframes="<<frames.size()<<"\nfailed_pixels="<<countFailures<<"\nreset_pixel_matches="<<resetMatches<<"\nvisibility_changes="<<visibilityChanges<<"\nstale_failed_pixels="<<staleBad<<"\nstale_mean="<<staleMean<<"\ncurrent_reference="<<newRef<<'\n';
        Require(reject&&images&&summary&&negative&&checks,"dynamic reports");std::cout<<"DYNAMIC REUSE VERIFY PASS stale="<<staleMean<<" current="<<newRef<<" staleBad="<<staleBad<<'\n';return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
