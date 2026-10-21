// 本课CPU数值参考：用nvcc/sm_120构建，但不启动CUDA kernel或DXR。
#include "dielectric_math.h"
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <random>
#include <stdexcept>
#include <limits>
using namespace dielectric;
constexpr double Pi=3.14159265358979323846;
void Require(bool b,const char* message){if(!b)throw std::runtime_error(message);}
struct Moment {uint64_t count=0;double mean=0,m2=0;void Add(double x){double delta=x-mean;mean+=delta/++count;m2+=delta*(x-mean);}double SE()const{return count>1?std::sqrt(m2/(count-1)/count):0;}};
int main(int argc,char** argv){try{
    Require(argc==2,"usage: dielectric_test output-directory");std::filesystem::path out=argv[1];std::filesystem::create_directories(out);
    std::ofstream curve(out/"fresnel.csv"),mc(out/"sampling.csv"),summary(out/"summary.txt");Require(bool(curve)&&bool(mc)&&bool(summary),"output open");
    curve<<"eta_i,eta_t,angle_deg,F,Rs,Rp,TIR\n"<<std::setprecision(12);
    mc<<"case,strategy,F,p_reflect,samples,reflected,mean,SE,expected,wrong_repeat_F,wrong_no_eta_squared\n"<<std::setprecision(12);
    double maxBoundary=0,maxPower=0,maxJacobian=0;uint64_t checks=0;
    for(bool exiting:{false,true})for(int j=0;j<900;++j){double degree=j*.1,ci=std::cos(degree*Pi/180),ni=exiting?1.5:1,nt=exiting?1:1.5;auto f=Evaluate(ci,ni,nt);Require(f.valid&&f.F>=0&&f.F<=1,"F range");
        if(!f.tir){
            // 独立参考从切向场的两条边界方程解t和r，而非复制rs/rp的展开式。
            // 非磁介质中相对波导纳Ys=eta*cos(theta)，Yp=eta/cos(theta)。
            double reflectedPower=0;
            for(int polarization=0;polarization<2;++polarization){double yi=polarization?ni/ci:ni*ci,yt=polarization?nt/f.cosT:nt*f.cosT;
                double transmissionAmplitude=2*yi/(yi+yt),r=transmissionAmplitude-1;
                double R=r*r,T=yt/yi*transmissionAmplitude*transmissionAmplitude;
                double residual=std::abs(yi*(1-r)-yt*transmissionAmplitude);maxBoundary=std::max(maxBoundary,residual);
                maxPower=std::max(maxPower,std::abs(R+T-1));Require(std::abs(R+T-1)<1e-12,"power conservation");reflectedPower+=R*.5;
            }
            Require(std::abs(reflectedPower-f.F)<1e-12,"boundary reference");
        }else Require(f.F==1,"TIR must reflect fully");
        curve<<ni<<','<<nt<<','<<degree<<','<<f.F<<','<<(f.tir?1:f.rs*f.rs)<<','<<(f.tir?1:f.rp*f.rp)<<','<<f.tir<<'\n';++checks;
    }
    Require(std::abs(Evaluate(1,1,1.5).F-.04)<1e-15,"normal F0");Require(Evaluate(0,1,1).F==0,"equal IOR grazing");Require(Evaluate(0,1,1.5).F==1,"grazing F");
    double brewster=std::atan(1.5),rp=Evaluate(std::cos(brewster),1,1.5).rp;Require(std::abs(rp)<1e-14,"Brewster p amplitude");
    // 立体角Jacobian由小角环带的精确积分独立验证。把i侧角区间用Snell映到t侧，比较投影立体角。
    // 投影立体角为( sin²(theta_hi)-sin²(theta_lo) )/2，公共deltaPhi省略。
    for(bool exiting:{false,true})for(int degree=5;degree<=(exiting?40:85);degree+=5){double ni=exiting?1.5:1,nt=exiting?1:1.5,q=ni/nt;
        double a=degree*Pi/180,da=1e-4,lo=a-da,hi=a+da,tl=std::asin(q*std::sin(lo)),th=std::asin(q*std::sin(hi));
        double gi=.5*(std::pow(std::sin(hi),2)-std::pow(std::sin(lo),2)),gt=.5*(std::pow(std::sin(th),2)-std::pow(std::sin(tl),2));
        double err=std::abs(ni*ni*gi-nt*nt*gt)/(ni*ni*gi);maxJacobian=std::max(maxJacobian,err);Require(err<2e-10,"projected solid angle Jacobian");
        // 相机侧i接收来自t侧的Li：Lo=(1-F)*q²*Li，应守恒穿过界面的通量。
        double F=Evaluate(std::cos(a),ni,nt).F,Li=3,Lo=(1-F)*q*q*Li;
        Require(std::abs(Lo*gi-(1-F)*Li*gt)<1e-12,"radiance vs flux");
    }
    struct Case {const char* name;double angle;bool entering;float inside;};
    Case cases[]{{"air_normal",0,true,1.5f},{"air_60",60,true,1.5f},{"air_80",80,true,1.5f},{"glass_30",30,false,1.5f},{"glass_TIR45",45,false,1.5f},{"equal_IOR",60,true,1}};
    constexpr uint64_t N=262144;uint64_t total=0;
    for(auto c:cases){double a=c.angle*Pi/180;V d{float(std::sin(a)),0,float((c.entering?-1:1)*std::cos(a))};auto boundary=Prepare(d,{0,0,1},1,c.inside);Require(boundary.valid,"prepare");
        // 设两个后续方向已知辐亮度分别为2和3，只验证界面估计器，不伪装为几何路径成像。
        double expected=boundary.F*2+(1-boundary.F)*boundary.q2*3;
        for(Choice choice:{Choice::Fresnel,Choice::Half}){std::mt19937_64 rng(20261021);Moment m,wrongF,wrongEta;uint64_t reflected=0;
            double pr=boundary.F<=0?0:(boundary.F>=1?1:(choice==Choice::Half?.5:boundary.F));
            for(uint64_t i=0;i<N;++i){double u=double(rng()>>11)/9007199254740992.;auto s=Draw(boundary,u,choice);Require(s.event!=Event::Invalid&&s.eventMass>0,"sample valid");
                bool reflect=s.event==Event::Reflection;reflected+=reflect;double Li=reflect?2:3,coefficient=reflect?boundary.F:(1-boundary.F);
                m.Add(s.weight*Li);wrongF.Add(s.weight*coefficient*Li);wrongEta.Add(s.weight*(reflect?1:1/boundary.q2)*Li);
                Require(std::abs(s.weight*s.rrEtaScale-coefficient/s.eventMass)<1e-12,"RR eta compensation");
                Require(std::abs(refraction::Dot(s.direction,s.direction)-1)<2e-6,"sample direction");
            }
            Require(std::abs(m.mean-expected)<6*m.SE()+1e-10,"Monte Carlo mean");
            Require(std::abs(double(reflected)/N-pr)<6*std::sqrt(pr*(1-pr)/N)+1./N,"event frequency");
            double wrongExpected=boundary.F*boundary.F*2+(1-boundary.F)*(1-boundary.F)*boundary.q2*3;
            Require(std::abs(wrongF.mean-wrongExpected)<6*wrongF.SE()+1e-10,"wrong F negative control");
            Require(std::abs(wrongEta.mean-(boundary.F*2+(1-boundary.F)*3))<6*wrongEta.SE()+1e-10,"missing eta negative control");
            mc<<c.name<<','<<(choice==Choice::Half?"half":"Fresnel")<<','<<boundary.F<<','<<pr<<','<<N<<','<<reflected<<','<<m.mean<<','<<m.SE()<<','<<expected<<','<<wrongF.mean<<','<<wrongEta.mean<<'\n';total+=N;
        }
    }
    // 两次实际透射的IOR比例相消，不意味着整块玻璃没有Fresnel反射损失。
    auto enter=Prepare({0,0,-1},{0,0,1},1,1.5f),leave=Prepare({0,0,-1},{0,0,-1},1,1.5f);
    auto a=Draw(enter,.5),b=Draw(leave,.5);Require(a.event==Event::Transmission&&b.event==Event::Transmission,"slab transmissions");
    Require(std::abs(a.weight*b.weight-1)<1e-14&&std::abs(a.rrEtaScale*b.rrEtaScale-1)<1e-14,"slab eta cancellation");
    auto t=Prepare({.70710677f,0,.70710677f},{0,0,1},1,1.5f);Require(Draw(t,.999).event==Event::Reflection,"TIR event");
    Require(Draw(enter,1).event==Event::Invalid&&Draw(enter,-.1).event==Event::Invalid&&Draw(enter,std::numeric_limits<double>::quiet_NaN()).event==Event::Invalid,"invalid RNG");
    auto report=[&](std::ostream& os){os<<std::setprecision(12)<<"CPU ONLY / no GPU dispatch\nFresnel_angle_cases="<<checks<<" samples="<<total<<"\nmax_boundary_residual="<<maxBoundary<<" max_power_residual="<<maxPower<<" max_Jacobian_relative_error="<<maxJacobian<<"\nnormal_F="<<Evaluate(1,1,1.5).F<<" Brewster_degrees="<<brewster*180/Pi<<" Brewster_rp="<<rp<<"\nslab_eta_product="<<a.weight*b.weight<<" RR_eta_scale_product="<<a.rrEtaScale*b.rrEtaScale<<"\nDielectric PASS\n";};report(summary);report(std::cout);
    curve.flush();mc.flush();summary.flush();Require(bool(curve)&&bool(mc)&&bool(summary),"output write");
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}return 0;}
