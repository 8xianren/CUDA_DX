// 纯CPU数学验收，沿用build.ps1/nvcc sm_120构建；没有CUDA kernel，也没有DXR提交。
#include "refraction_math.h"
#include <array>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <vector>
using refraction::V;using refraction::Status;using refraction::RefractBoundary;
constexpr double Pi=3.14159265358979323846;
struct D {double x,y,z;};
D operator+(D a,D b){return {a.x+b.x,a.y+b.y,a.z+b.z};}
D operator-(D a,D b){return {a.x-b.x,a.y-b.y,a.z-b.z};}
D operator*(D a,double s){return {a.x*s,a.y*s,a.z*s};}
double Dot(D a,D b){return a.x*b.x+a.y*b.y+a.z*b.z;}
double Length(D a){return std::sqrt(Dot(a,a));}
D Unit(D a){return a*(1/Length(a));}
D Cross(D a,D b){return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
D ToD(V a){return {a.x,a.y,a.z};}V ToV(D a){return {float(a.x),float(a.y),float(a.z)};}
void Require(bool ok,const char* s){if(!ok)throw std::runtime_error(s);}
struct Stats {size_t cases=0,transmitted=0,blocked=0,reverse=0,boundary=0;double maxDirection=0,maxSnell=0,maxLength=0,maxReverse=0;};
int main(int argc,char**argv){try{
    Require(argc==2,"usage: refraction_test output-directory");std::filesystem::path out=argv[1];std::filesystem::create_directories(out);
    std::ofstream table(out/"anchors.csv");Require(bool(table),"cannot open anchors.csv");
    table<<"name,incident_deg,entering,status,eta_i,eta_t,k,tx,ty,tz,transmitted_deg\n"<<std::setprecision(12);Stats stats;
    auto verify=[&](V input,V ng,float outside,float inside,const char* label,double degree,bool boundary=false){
        auto r=RefractBoundary(input,ng,outside,inside);Require(r.status!=Status::Invalid,"valid case rejected");++stats.cases;
        D d=Unit(ToD(input)),g=Unit(ToD(ng));bool enters=Dot(d,g)<0;D n=enters?g:g*(-1);
        double ni=enters?outside:inside,nt=enters?inside:outside;
        // 独立double参考：先用atan2取入射角，再经asin求透射角，在入射平面中重建方向。
        // 不复用被测函数的float平方根表达式；比较的是同一组已量化float输入。
        D tangent=d-n*Dot(d,n);double sinI=Length(tangent),thetaI=std::atan2(sinI,-Dot(d,n));
        double sinT=ni/nt*std::sin(thetaI),angleT=-1;
        Require(r.entering==enters&&r.etaIncident==ni&&r.etaTransmitted==nt,"medium side mismatch");
        if(!boundary)Require((r.status==Status::Transmitted)==(sinT<1),"transmission/TIR classification");
        else ++stats.boundary; // 仅显式临界角样本：float最后几位可改变符号，不给出伪造的精确分类保证。
        if(r.status==Status::Transmitted){++stats.transmitted;D t=ToD(r.direction);
            Require(refraction::Finite(r.direction)&&Dot(t,n)<0,"invalid transmitted hemisphere");
            double normError=std::abs(Length(t)-1);stats.maxLength=std::max(stats.maxLength,normError);Require(normError<5e-6,"unit length");
            double snell=std::abs(ni*sinI-nt*Length(t-n*Dot(t,n)));stats.maxSnell=std::max(stats.maxSnell,snell);Require(snell<3e-6,"Snell residual");
            angleT=std::atan2(Length(t-n*Dot(t,n)),-Dot(t,n))*180/Pi;
            if(!boundary){double thetaT=std::asin(sinT);D reference=sinI>1e-12?tangent*(std::sin(thetaT)/sinI)-n*std::cos(thetaT):n*(-1);
                double error=Length(t-reference);stats.maxDirection=std::max(stats.maxDirection,error);Require(error<5e-5,"direction reference");
                // 可逆性：沿-t回到同一界面，保持外向法线与介质定义不变，应返回-d。
                auto back=RefractBoundary(ToV(t*(-1)),ng,outside,inside);Require(back.status==Status::Transmitted,"reverse blocked");
                double reverseError=Length(ToD(back.direction)+d);stats.maxReverse=std::max(stats.maxReverse,reverseError);Require(reverseError<8e-5,"reverse direction");++stats.reverse;
            }
        }else{++stats.blocked;Require(r.k<=0&&refraction::Dot(r.direction,r.direction)==0,"no-transmission output contract");}
        if(label)table<<label<<','<<degree<<','<<r.entering<<','<<(r.status==Status::Transmitted?"transmitted":"no_transmission")<<','<<ni<<','<<nt<<','<<r.k<<','<<r.direction.x<<','<<r.direction.y<<','<<r.direction.z<<','<<angleT<<'\n';
    };
    auto axis=[&](double degrees,bool enter,float outside,float inside,const char* label,bool boundary=false){double a=degrees*Pi/180;
        verify({float(std::sin(a)),0,float((enter?-1:1)*std::cos(a))},{0,0,1},outside,inside,label,degrees,boundary);};
    axis(0,true,1,1.5f,"air_to_glass_normal");axis(30,true,1,1.5f,"air_to_glass_30");axis(60,true,1,1.5f,"air_to_glass_60");
    axis(30,false,1,1.5f,"glass_to_air_30");axis(45,false,1,1.5f,"glass_to_air_45");axis(60,true,1,1,"equal_IOR");
    double critical=std::asin(1/1.5)*180/Pi;
    axis(critical-.001,false,1,1.5f,"critical_minus_0.001");axis(critical,false,1,1.5f,"critical_float_boundary",true);axis(critical+.001,false,1,1.5f,"critical_plus_0.001");
    // 多个旋转法线和切向方向，防止实现只在n=(0,0,1)时看似正确。
    std::vector<D> normals{{0,0,1},{1,0,0},{0,1,0},{1,2,3},{-2,1,3},{1,-3,-2},{-1,-2,-3},{3,2,-1},{2,-1,3}};
    for(D raw:normals){D g=Unit(raw),tangent=Unit(Cross(std::abs(g.z)<.9?D{0,0,1}:D{0,1,0},g));
        for(auto pair:std::array<std::array<float,2>,4>{{{1,1},{1,1.33f},{1,1.5f},{1.33f,1.5f}}})
            for(int entering=0;entering<2;++entering)for(int j=0;j<180;++j){double a=(j*.5)*Pi/180;
                D d=tangent*std::sin(a)+g*((entering?-1:1)*std::cos(a));verify(ToV(d),ToV(g),pair[0],pair[1],nullptr,j*.5);}}
    // 非法参数单独拒绝，不能把NaN、零法线或未知介质侧误报成物理全反射。
    unsigned invalid=0;auto reject=[&](V d,V n,float a,float b){Require(RefractBoundary(d,n,a,b).status==Status::Invalid,"bad input accepted");++invalid;};
    reject({0,0,-1},{0,0,0},1,1.5f);reject({0,0,-1},{0,0,2},1,1.5f);reject({0,0,0},{0,0,1},1,1.5f);
    reject({1,0,0},{0,0,1},1,1.5f);reject({0,0,-1},{0,0,1},0,1.5f);reject({0,0,-1},{0,0,1},1,std::numeric_limits<float>::quiet_NaN());
    // 固定两端点的费马原理验证：A=(-1,+1), B=(+1,-1)，界面z=0；求驻值横坐标x。
    // 这里的时间省略共同常数1/c；二分求导数根，完全独立于折射向量实现。
    auto derivative=[](double x){return (x+1)/std::hypot(x+1,1.)+1.5*(x-1)/std::hypot(x-1,1.);};
    double lo=-1,hi=1;for(int i=0;i<100;++i){double mid=(lo+hi)*.5;if(derivative(mid)>0)hi=mid;else lo=mid;}
    double crossing=(lo+hi)*.5;D fromA=Unit({crossing+1,0,-1}),toB=Unit({1-crossing,0,-1});
    auto fermat=RefractBoundary(ToV(fromA),{0,0,1},1,1.5f);double fermatError=Length(ToD(fermat.direction)-toB);Require(fermat.status==Status::Transmitted&&fermatError<1e-6,"Fermat stationary path");
    table.flush();Require(bool(table),"write anchors failed");std::ofstream summary(out/"summary.txt");Require(bool(summary),"summary open");
    auto print=[&](std::ostream& stream){stream<<std::setprecision(12)<<"CPU ONLY / no GPU dispatch\ncases="<<stats.cases<<" transmitted="<<stats.transmitted<<" no_transmission="<<stats.blocked<<" boundary_diagnostic="<<stats.boundary<<" reverse_checks="<<stats.reverse<<" invalid_rejected="<<invalid<<"\nmax_direction_error="<<stats.maxDirection<<" max_unit_error="<<stats.maxLength<<" max_Snell_residual="<<stats.maxSnell<<" max_reverse_error="<<stats.maxReverse<<"\ncritical_degrees="<<critical<<" Fermat_crossing_x="<<crossing<<" Fermat_direction_error="<<fermatError<<"\nRefraction PASS\n";};
    print(summary);summary.flush();Require(bool(summary),"summary write");print(std::cout);
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}return 0;}
