#include "gi_reconnection.h"
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
using namespace restir_gi;
void Require(bool b,const char* m){if(!b)throw std::runtime_error(m);}
struct Moment {uint64_t n=0;double mean=0,m2=0;void Add(double x){++n;double d=x-mean;mean+=d/n;m2+=d*(x-mean);}double Var()const{return m2/(n-1);}double SE()const{return std::sqrt(Var()/n);}};
inline V3 Cross(V3 a,V3 b){return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
// 单位球面参数化面积由|∂ω/∂u × ∂ω/∂v|给出，用中央差分独立检查解析立体角因子。
double NumericalFactor(V3 x,V3 y){constexpr double e=1e-5;auto du=(Direction(x,y+V3{e,0,0})-Direction(x,y-V3{e,0,0}))*(.5/e);
    auto dv=(Direction(x,y+V3{0,e,0})-Direction(x,y-V3{0,e,0}))*(.5/e);return Length(Cross(du,dv));}
int main(int argc,char** argv){
    if(argc!=2)return 2;
    try{
        std::filesystem::path out=argv[1];std::filesystem::create_directories(out);
        const std::array<V3,2> sources{{{-.8,0,0},{.5,-.2,0}}};
        const std::array<V3,3> destinations{{{.6,.2,0},{.6,.2,.5},{.6,.2,1}}};
        constexpr unsigned trials=100000;double maxJacError=0,maxAreaDifference=0;unsigned negatives=0;
        // 解析锚点：源(0,0,0)、目标(0,0,1)、y(0,0,2)，距离减半，立体角扩大四倍。
        Require(std::abs(Jacobian({0,0,0},{0,0,1},{0,0,2})-4)<1e-14,"analytic J=4");
        for(auto d:destinations)for(auto s:sources)for(int j=0;j<9;++j)for(int i=0;i<9;++i){V3 y{-.9+i*.225,-.9+j*.225,2};
            double analytic=Jacobian(s,d,y),numeric=NumericalFactor(d,y)/NumericalFactor(s,y);
            maxJacError=std::max(maxJacError,std::abs(analytic-numeric)/analytic);
            Require(std::abs(analytic*Jacobian(d,s,y)-1)<1e-14,"inverse mapping");}
        Require(maxJacError<1e-8,"finite difference Jacobian");
        std::ofstream csv(out/"statistics.csv");csv<<std::setprecision(14)<<"destination,method,reference,mean,variance,se,quadrature_delta,method_expectation\n";
        const char* names[]{"direct-area-16","reconnect-J","reconnect-area","omit-J","inverse-J"};
        for(unsigned k=0;k<destinations.size();++k){auto x=destinations[k];double ref=Reference(x,512),error=std::abs(ref-Reference(x,256));std::array<Moment,5> stats;
            for(unsigned t=0;t<trials;++t){mis::Rng rng(20261025+t*65537ULL,k);Reservoir good,area,missing,inverse;double direct=0;
                for(unsigned group=0;group<2;++group){auto src=Generate(sources[group],group?12:4,rng);auto y=src.sample;
                    double aSource=AreaToSolidAngle(sources[group],y.position),aDest=AreaToSolidAngle(x,y.position),f=IntegrandOmega(x,y),j=aDest/aSource,u=rng.Uniform();
                    MergeMapped(good,src,f,j,u);MergeMapped(missing,src,f,1,u);MergeMapped(inverse,src,f,1/j,u);
                    // 对照改用次级表面面积：W_A=W_ω/a_source，F_A=F_ω*a_destination。
                    // 这两因子必须一起改变；面积域的恒等映射本身J=1。
                    MergeMapped(area,src,f*aDest,1/aSource,u);
                }
                for(unsigned i=0;i<16;++i){auto y=Draw(rng);direct+=IntegrandOmega(x,y)*AreaToSolidAngle(x,y.position)*4/16;}
                double correct=good.Normalization()*IntegrandOmega(x,good.sample);
                double areaValue=area.Normalization()*IntegrandOmega(x,area.sample)*AreaToSolidAngle(x,area.sample.position);
                maxAreaDifference=std::max(maxAreaDifference,std::abs(correct-areaValue));Require(good.M==16&&area.M==16,"merged group count");
                stats[0].Add(direct);stats[1].Add(correct);stats[2].Add(areaValue);
                stats[3].Add(missing.Normalization()*IntegrandOmega(x,missing.sample));stats[4].Add(inverse.Normalization()*IntegrandOmega(x,inverse.sample));
            }
            for(unsigned m=0;m<5;++m){auto& s=stats[m];double expectation=m<3?ref:WrongReference(x,sources,m==4,512);
                double ownError=m<3?error:std::abs(expectation-WrongReference(x,sources,m==4,256));
                Require(std::abs(s.mean-expectation)<6*s.SE()+4*ownError+1e-10,"method own expectation");
                csv<<k<<','<<names[m]<<','<<ref<<','<<s.mean<<','<<s.Var()<<','<<s.SE()<<','<<error<<','<<expectation<<'\n';
                if(m<3)Require(std::abs(s.mean-ref)<6*s.SE()+4*error+1e-10,"GI mean reference");
                else {bool detected=std::abs(s.mean-ref)>10*s.SE()+4*error+1e-10;if(detected)++negatives;
                    if(k>0)Require(detected,"height change exposes wrong J");}
                std::cout<<k<<' '<<names[m]<<" ref="<<ref<<" mean="<<s.mean<<'\n';}
        }
        Require(maxAreaDifference<1e-12,"area and solid-angle pathwise equivalence");Require(negatives>=4,"missing and inverse J negative controls");
        // 非法映射在触碰目标前拒绝；共享概率容器的原有边界验证由旧测试负责。
        Reservoir empty;bool rejected=false;try{MergeMapped(empty,empty,1,0,.5);}catch(const std::invalid_argument&){rejected=true;}
        Require(rejected&&empty.M==0,"reject zero Jacobian without mutation");
        std::ofstream checks(out/"checks.txt");checks<<std::setprecision(14)<<"CPU_only=1\ntrials_per_destination="<<trials<<"\nfinite_difference_points=486\nmax_relative_J_error="<<maxJacError<<"\nmax_pathwise_area_difference="<<maxAreaDifference<<"\nnegative_controls="<<negatives<<"\n";
        Require(csv&&checks,"GI report writes");std::cout<<"GI RECONNECTION PASS Jerror="<<maxJacError<<" areaDifference="<<maxAreaDifference<<'\n';return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
