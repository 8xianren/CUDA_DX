// nvcc/sm_120构建的CPU实验，不启动CUDA kernel或DXR。先把积分目标与采样器独立验清。
#include "ggx_quadrature.h"
#include "dielectric_math.h"
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <random>
#include <limits>
#include <cstdint>
using namespace ggx;
void Require(bool value,const char* message){if(!value)throw std::runtime_error(message);}
struct Moment {uint64_t n=0;double mean=0,m2=0;void Add(double v){double d=v-mean;mean+=d/++n;m2+=d*(v-mean);}
    double SE()const{return n>1?std::sqrt(m2/(n-1)/n):0;}};
double Random(std::mt19937& rng){return (double(rng())+.5)/4294967296.;}
V View(double degree){double a=degree*Pi/180;return {std::sin(a),0,std::cos(a)};}
double MaxAbs(V a){return std::max({std::abs(a.x),std::abs(a.y),std::abs(a.z)});}
double Component(V a,unsigned k){return k==0?a.x:(k==1?a.y:a.z);}

int main(int argc,char** argv){try{
    Require(argc==2,"ggx_test output-directory");std::filesystem::path out=argv[1];std::filesystem::create_directories(out);
    std::ofstream summary(out/"summary.txt"),curve(out/"roughness.csv"),furnace(out/"furnace.csv"),distribution(out/"distribution.csv");
    Require(bool(summary)&&bool(curve)&&bool(furnace)&&bool(distribution),"output open");
    summary<<std::setprecision(14);curve<<std::setprecision(14);furnace<<std::setprecision(14);distribution<<std::setprecision(14);
    curve<<"roughness,alpha,delta,normal_white_mean,SE,null_fraction,D_at_normal\n";
    furnace<<"roughness,view_degrees,material,strategy,samples,valid_fraction,pdf_integral,r_mean,r_SE,r_reference,g_mean,g_SE,g_reference,b_mean,b_SE,b_reference,wrong_conditional_red,wrong_no_jacobian_red,no_mask_reference,quadrature_difference,quadrature_z_order\n";
    distribution<<"roughness,m_degrees,D,p_m\n";

    // 一、分布归一化。独立角度积分：r=alpha*tan(pi*v/2)，dω=r*dr*dphi/(1+r²)^(3/2)。
    // 直接对D(m)*m.z*dω积分，不调用NormalFromNdf，不以采样直方图自证正确。
    double maxNormalization=0,maxProjectedArea=0,maxJacobian=0,maxReciprocity=0,maxUnit=0;
    auto nodes=Gauss(256,0,1);
    for(double alpha:{.000101,.001,.01,.0625,.25,.5625,1.}){
        double integral=0;
        for(auto p:nodes){double angle=Pi*p.x/2,r=alpha*std::tan(angle),dr=alpha*Pi/2/(std::cos(angle)*std::cos(angle));
            double mz=1/std::sqrt(1+r*r);V m{r*mz,0,mz};
            integral+=D(m,alpha)*mz*(2*Pi*r*dr*mz*mz*mz)*p.w;}
        maxNormalization=std::max(maxNormalization,std::abs(integral-1));Require(std::abs(integral-1)<2e-10,"NDF projected normalization");
        // Smith G1的独立约束：总正投影面积A=∫max(1-tan(theta)*s,0)*P_s(s)ds。
        // GGX二维斜率分布积分掉另一坐标后，P_s=alpha²/[2(alpha²+s²)^(3/2)]。
        for(double degrees:{0.,30.,60.,80.,89.9}){V wo=View(degrees);double tangent=wo.x/wo.z;
            double upper=tangent==0?1:(std::atan(1/(tangent*alpha))/Pi+.5),area=0;
            for(auto p:Gauss(256,0,upper)){double a=Pi*(p.x-.5),s=alpha*std::tan(a),ds=alpha*Pi/(std::cos(a)*std::cos(a));
                double density=alpha*alpha/(2*std::pow(alpha*alpha+s*s,1.5));area+=(1-tangent*s)*density*ds*p.w;}
            double wanted=1+Lambda(wo,alpha),error=std::abs(area/wanted-1);maxProjectedArea=std::max(maxProjectedArea,error);
            Require(error<2e-10,"Smith projected area");
        }
    }

    // 二、反射Jacobian由数值微分验证，不直接拿PDF公式与其自身比较。
    std::mt19937 rng(739391);uint64_t jacobianChecks=0,reciprocityChecks=0;
    for(unsigned j=0;j<10000;++j){V m=NormalFromNdf(.5,Random(rng),Random(rng)),wo=View(70);double om=Dot(wo,m);
        if(std::abs(om)<.02)continue;
        V t1=Normalize(Cross(std::abs(m.z)<.9?V{0,0,1}:V{1,0,0},m)),t2=Cross(m,t1);
        auto reflect=[&](V a){return a*(2*Dot(wo,a))-wo;};constexpr double epsilon=1e-5;
        V a=(reflect(Normalize(m+t1*epsilon))-reflect(Normalize(m-t1*epsilon)))*(1/(2*epsilon));
        V b=(reflect(Normalize(m+t2*epsilon))-reflect(Normalize(m-t2*epsilon)))*(1/(2*epsilon));
        double area=std::sqrt(Dot(Cross(a,b),Cross(a,b))),error=std::abs(area/(4*std::abs(om))-1);
        maxJacobian=std::max(maxJacobian,error);Require(error<5e-7,"reflection solid-angle Jacobian");++jacobianChecks;
    }
    for(unsigned j=0;j<10000;++j){Material p{.1+.9*Random(rng),{.9,.6,.2}};
        auto hemisphere=[&](){double z=.001+.999*Random(rng),phi=2*Pi*Random(rng),r=std::sqrt(1-z*z);return V{r*std::cos(phi),r*std::sin(phi),z};};
        V wo=hemisphere(),wi=hemisphere();auto a=Eval(p,wo,wi),b=Eval(p,wi,wo);
        double error=MaxAbs(a.f-b.f)/(1+MaxAbs(a.f));maxReciprocity=std::max(maxReciprocity,error);
        Require(error<1e-12,"BRDF reciprocity");++reciprocityChecks;
    }

    // 三、roughness扫描覆盖明确delta边界和非常窄的连续峰；本扫不拿不足分辨率的均匀网格充当参考。
    uint64_t scanSamples=0;
    for(double roughness:{0.,1e-6,.005,.01,.0101,.025,.05,.1,.25,.5,.75,1.}){
        Material p{roughness,{1,1,1}};Moment white;uint64_t nulls=0;
        for(unsigned i=0;i<65536;++i){auto s=Draw(p,{0,0,1},Random(rng),Random(rng));
            Require(s.event!=0&&Finite(s.weight)&&std::isfinite(s.pdf),"roughness finite sample");
            if(s.event==1)++nulls;else {double error=std::abs(Dot(s.wi,s.wi)-1);maxUnit=std::max(maxUnit,error);Require(error<1e-8,"unit sampled direction");}
            Require(s.weight.x>=0&&s.weight.x<=1+1e-10,"normal white bound");white.Add(s.weight.x);++scanSamples;
            if(Delta(p))Require(s.event==3&&s.pdf==0&&s.mass==1&&s.weight.x==1,"delta contract");
        }
        if(roughness<=.1)Require(white.mean>.995,"smooth limit white furnace");
        curve<<roughness<<','<<Alpha(p)<<','<<Delta(p)<<','<<white.mean<<','<<white.SE()<<','<<double(nulls)/white.n<<','<<(Delta(p)?0:D({0,0,1},Alpha(p)))<<'\n';
        if(!Delta(p))for(unsigned j=0;j<=900;++j){double angle=j*.1*Pi/180;V m{std::sin(angle),0,std::cos(angle)};
            double ndf=D(m,Alpha(p));distribution<<roughness<<','<<j*.1<<','<<ndf<<','<<ndf*m.z<<'\n';}
        // 掠射方向也检验有限性；正好切线不属于当前反射半球的有效wo。
        for(double degrees:{0.,45.,80.,89.9})for(unsigned i=0;i<2048;++i){auto s=Draw(p,View(degrees),Random(rng),Random(rng));
            Require(s.event&&Finite(s.weight)&&std::isfinite(s.pdf)&&s.weight.x>=0,"grazing finite scan");++scanSamples;}
    }
    Material good{.5,{.04,.04,.04}};double nan=std::numeric_limits<double>::quiet_NaN();
    Require(Draw(good,{0,0,1},1,.5).event==0&&Draw(good,{0,0,1},-.1,.5).event==0&&
        Draw(good,{0,0,1},nan,.5).event==0&&Draw(good,{0,0,0},.5,.5).event==0&&
        Draw(good,{0,0,-1},.5,.5).event==0&&Draw({-1,{1,1,1}},{0,0,1},.5,.5).event==0&&
        Draw({.5,{1.1,1,1}},{0,0,1},.5,.5).event==0,"invalid inputs");
    Require(Schlick(good.F0,1).x==.04&&Schlick(good.F0,0).x==1,"Schlick endpoints");
    double maxSchlick=0,schlickAngle=0;
    for(unsigned j=0;j<=899;++j){double angle=j*.1,c=std::cos(angle*Pi/180),difference=std::abs(Schlick(good.F0,c).x-dielectric::Evaluate(c,1,1.5).F);
        if(difference>maxSchlick){maxSchlick=difference;schlickAngle=angle;}}

    // 四、白炉：所有入射方向Li=(1,1,1)。输出等于积分∫f*wi.z*dω。
    // 独立方向积分比较256x512与512x1024收敛，再比较NDF和余弦两种MC估计。
    const V colors[]{{1,1,1},{.04,.04,.04},{.9,.6,.2}};
    uint64_t mcSamples=0;double maxQuad=0;
    for(double roughness:{.25,.5,.75,1.})for(double degrees:{0.,45.,80.})for(unsigned color=0;color<3;++color){
        Material p{roughness,colors[color]};V wo=View(degrees);
        auto low=Hemisphere(p,wo,256,512),reference=Hemisphere(p,wo,512,1024);
        unsigned order=512;
        double qdiff=std::max(MaxAbs(low.rgb-reference.rgb),std::abs(low.pdf-reference.pdf));
        // 掠射下镜面峰的方向范围更窄；参考自身未收敛时细化积分，不放宽MC验收来迁就粗参考。
        while(qdiff>=3e-6&&order<2048){low=reference;order*=2;reference=Hemisphere(p,wo,order,2*order);
            qdiff=std::max(MaxAbs(low.rgb-reference.rgb),std::abs(low.pdf-reference.pdf));}
        maxQuad=std::max(maxQuad,qdiff);
        Require(qdiff<3e-6,"white reference quadrature convergence");
        Require(reference.rgb.x>=0&&reference.rgb.x<=1+3e-6&&reference.pdf>=0&&reference.pdf<=1+3e-6,"furnace energy bound");
        if(roughness==1&&degrees==0&&color==0)Require(std::abs(reference.rgb.x-(1-std::log(2.)))<1e-10,"alpha1 analytic white furnace");
        if(degrees==0)Require(std::abs(reference.pdf-1/(1+Alpha(p)*Alpha(p)))<3e-6,"normal acceptance analytic");
        for(unsigned strategy=0;strategy<2;++strategy){Moment moment[3],wrong,conditional;uint64_t valid=0;
            constexpr uint32_t perSeed=65536,seeds=4;
            for(uint32_t seed=0;seed<seeds;++seed){std::mt19937 random(1907+seed*7919);
                for(uint32_t j=0;j<perSeed;++j){double u=Random(random),v=Random(random);V weight{};
                    if(strategy==0){auto s=Draw(p,wo,u,v);Require(s.event==1||s.event==2,"continuous sampling event");weight=s.weight;
                        if(s.event==2){++valid;conditional.Add(weight.x);V h=Normalize(wo+s.wi);wrong.Add(weight.x/(4*Dot(wo,h)));}
                        else wrong.Add(0);
                    }else{
                        double radius=std::sqrt(u),phi=2*Pi*v;V wi{radius*std::cos(phi),radius*std::sin(phi),std::sqrt(1-u)};
                        auto e=Eval(p,wo,wi);weight=e.f*Pi;++valid;
                        // 余弦采样PDF=wi.z/pi，与NDF采样PDF不同，但积分目标相同。
                    }
                    Require(Finite(weight)&&weight.x>=0&&weight.y>=0&&weight.z>=0,"MC finite nonnegative");
                    for(unsigned k=0;k<3;++k)moment[k].Add(Component(weight,k));++mcSamples;
                }
            }
            double count=double(perSeed)*seeds,fraction=valid/count;
            if(strategy==0)Require(std::abs(fraction-reference.pdf)<6*std::sqrt(reference.pdf*(1-reference.pdf)/count)+3e-6,"NDF PDF integral vs acceptance");
            furnace<<roughness<<','<<degrees<<','<<color<<','<<strategy<<','<<uint64_t(count)<<','<<fraction<<','<<reference.pdf;
            for(unsigned k=0;k<3;++k){double target=Component(reference.rgb,k);
                Require(std::abs(moment[k].mean-target)<6*moment[k].SE()+3e-6,"MC mean vs directional quadrature");
                furnace<<','<<moment[k].mean<<','<<moment[k].SE()<<','<<target;}
            furnace<<','<<conditional.mean<<','<<wrong.mean<<','<<reference.noMask<<','<<qdiff<<','<<order<<'\n';
            if(roughness==1&&degrees==0&&color==0&&strategy==0){
                Require(conditional.mean>moment[0].mean*1.9,"resample-with-old-pdf negative control");
                Require(std::abs(wrong.mean-moment[0].mean)>.1,"missing Jacobian negative control");
                summary<<"alpha1_normal_correct="<<moment[0].mean<<" target="<<reference.rgb.x<<" conditional_wrong="<<conditional.mean<<" no_jacobian_wrong="<<wrong.mean<<'\n';}
            if(roughness==1&&degrees==80&&color==0)Require(reference.noMask>2.8,"missing Smith energy explosion negative control");
        }
        std::cout<<"roughness="<<roughness<<" view="<<degrees<<" material="<<color<<" white_R="<<reference.rgb.x<<" PASS\n";
    }
    summary<<"CPU_ONLY no CUDA kernel or DXR\nnormalization_error="<<maxNormalization<<" projected_area_error="<<maxProjectedArea
        <<" jacobian_relative_error="<<maxJacobian<<" jacobian_checks="<<jacobianChecks<<" reciprocity_error="<<maxReciprocity
        <<" reciprocity_checks="<<reciprocityChecks<<" unit_error="<<maxUnit<<" scan_samples="<<scanSamples
        <<" MC_samples="<<mcSamples<<" quadrature_difference="<<maxQuad<<" Schlick_max_abs_error="<<maxSchlick<<" angle="<<schlickAngle<<'\n';
    summary<<"PASS; delta alpha <= "<<DeltaAlpha<<"; single microsurface scattering, no multiple-scattering energy compensation\n";
    summary.flush();curve.flush();furnace.flush();distribution.flush();Require(bool(summary)&&bool(curve)&&bool(furnace)&&bool(distribution),"output write");
    std::cout<<"GGX PASS CPU_ONLY MC_samples="<<mcSamples<<" normalization_error="<<maxNormalization<<" quadrature_difference="<<maxQuad<<'\n';
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}return 0;}
