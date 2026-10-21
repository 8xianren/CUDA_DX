#include "energy_balance.h"
#include "energy_quadrature.h"
#include <array>
#include <filesystem>
#include <fstream>
#include <future>
#include <iomanip>
#include <iostream>
#include <random>
#include <sstream>
namespace fs=std::filesystem;
using ggx::V;
void Require(bool value,const char* message){if(!value)throw std::runtime_error(message);}
double Error(V a,V b){return std::max({std::abs(a.x-b.x),std::abs(a.y-b.y),std::abs(a.z-b.z)});}
struct Stats {V sum{},square{};size_t n=0;
    void Add(V v){Require(ggx::Finite(v),"nonfinite weight");sum=sum+v;square=square+pbr::Product(v,v);++n;}
    V Mean()const{return sum*(1./n);}
    V SE()const{V m=Mean(),q=square*(1./n)-pbr::Product(m,m);
        return {std::sqrt(std::max(0.,q.x)/(n-1)),std::sqrt(std::max(0.,q.y)/(n-1)),std::sqrt(std::max(0.,q.z)/(n-1))};}
};
V Draw(pbr::Material m,V wo,unsigned mode,const energy::Row& row,double choice,double u,double v){
    double ps=pbr::SpecProbability(m,mode);V wi;
    if(choice<ps){auto sample=ggx::Draw({m.roughness,pbr::F0(m)},wo,u,v);
        if(sample.event==1)return {};Require(sample.event!=0,"invalid sample");
        if(sample.event==3)return sample.weight*(1/ps);wi=sample.wi;
    }else{double radius=std::sqrt(u),phi=2*ggx::Pi*v;wi={radius*std::cos(phi),radius*std::sin(phi),std::sqrt(1-u)};}
    auto e=energy::Eval(m,wo,wi,mode,row);Require(e.pdf>0,"zero mixed pdf");return e.f*(wi.z/e.pdf);
}
V Integral(pbr::Material m,V wo,const energy::Row& row,bool original,unsigned order){
    // 独立于随机Draw与E构表积分：使用等距中点phi，直接积完整BRDF，保留旧模型作负对照。
    V result{};auto nodes=ggx::Gauss(order,0,1);unsigned nphi=2*order;
    for(auto z:nodes){double radius=std::sqrt(1-z.x*z.x);
        for(unsigned j=0;j<nphi;++j){double phi=2*ggx::Pi*(j+.5)/nphi;
            V wi{radius*std::cos(phi),radius*std::sin(phi),z.x};
            auto e=original?pbr::Eval(m,wo,wi,0):energy::Eval(m,wo,wi,0,row);
            result=result+e.f*(z.x*z.w*2*ggx::Pi/nphi);
        }
    }
    // delta不出现在连续方向积分中，须单独加上其离散反射质量。
    if(m.roughness*m.roughness<=ggx::DeltaAlpha)result=result+ggx::Schlick(pbr::F0(m),wo.z);
    return result;
}
int main(int argc,char** argv){try{
    Require(argc==2,"usage: energy_test output-directory");fs::path out=argv[1];fs::create_directories(out);
    std::array<double,5> roughness{0,.25,.5,.75,1};std::array<energy::Row,5> rows;
    std::ofstream lut(out/"energy.csv"),curves(out/"furnace.csv"),sampling(out/"sampling.csv"),summary(out/"summary.txt");
    Require(lut&&curves&&sampling&&summary,"cannot open output files");
    lut<<std::setprecision(15)<<"roughness,cosine,energy,average,quadrature_change,order\n";
    curves<<std::setprecision(15)<<"roughness,angle,original_white,corrected_white,predicted_white,energy,average\n";
    sampling<<std::setprecision(15)<<"roughness,angle,case,mode,samples,reference_r,mean_r,se_r,reference_g,mean_g,se_g,reference_b,mean_b,se_b\n";
    double maxChange=0,maxTableError=0,maxWhiteError=0,maxIndependent=0,maxReciprocity=0,maxNaiveReciprocity=0;
    unsigned maxOrder=0;size_t offGrid=0,samples=0;double bad80=0;
    // 各roughness行相互独立；std::async只并行CPU数值任务。future.get形成同步点并传播异常。
    // 每个任务拥有自己的Row/Reference数组，不共享写入文件，不涉及CUDA stream或D3D12 Fence。
    using Built=std::pair<energy::Row,std::vector<energy::Reference>>;
    std::array<std::future<Built>,5> jobs;
    for(size_t k=0;k<rows.size();++k)jobs[k]=std::async(std::launch::async,[r=roughness[k]](){
        energy::Row row;row.roughness=r;row.values.resize(257);std::vector<energy::Reference> refs(257);
        for(size_t j=0;j<257;++j){double u=j/256.;refs[j]=energy::Converged(r,u*u);row.values[j]=energy::Dielectric(refs[j].basis);}
        row.Normalize();return Built{std::move(row),std::move(refs)};
    });
    for(size_t k=0;k<rows.size();++k){auto built=jobs[k].get();rows[k]=std::move(built.first);auto& row=rows[k];
        for(size_t j=0;j<257;++j){const auto& ref=built.second[j];maxChange=std::max(maxChange,ref.change);maxOrder=std::max(maxOrder,ref.order);
            lut<<row.roughness<<','<<std::pow(j/256.,2)<<','<<row.values[j]<<','<<row.average<<','<<ref.change<<','<<ref.order<<'\n';}
        std::cout<<"row roughness="<<row.roughness<<" average="<<row.average<<" ready\n"<<std::flush;
        // 半格点不参与构表。比较真实积分与线性查表，避免用表去验证表自身。
        for(unsigned j=0;j<64;++j){double c=std::pow((4*j+.5)/256.,2);auto ref=energy::Converged(row.roughness,c);
            double error=std::abs(row.At(c)-energy::Dielectric(ref.basis));maxTableError=std::max(maxTableError,error);++offGrid;
            Require(error<1e-4,"energy interpolation error");}
        for(double angle:{0.,60.,80.}){double c=std::cos(angle*ggx::Pi/180);V wo{std::sqrt(1-c*c),0,c};
            auto ref=energy::Converged(row.roughness,c);double es=energy::Dielectric(ref.basis);
            pbr::Material white{{1,1,1},0,row.roughness};
            V oldValue=Integral(white,wo,row,true,1024),newValue=Integral(white,wo,row,false,1024);
            double predicted=es+1-row.At(c);maxWhiteError=std::max(maxWhiteError,std::abs(newValue.x-1));
            maxIndependent=std::max(maxIndependent,std::abs(newValue.x-predicted));
            Require(std::abs(newValue.x-predicted)<1e-5&&std::abs(newValue.x-1)<1e-4,"independent white furnace");
            if(row.roughness==.25&&angle==80)bad80=oldValue.x;
            curves<<row.roughness<<','<<angle<<','<<oldValue.x<<','<<newValue.x<<','<<predicted<<','<<es<<','<<row.average<<'\n';
            std::array<pbr::Material,4> materials{{white,{{.2,.6,.9},0,row.roughness},{{.5,.3,.1},.5,row.roughness},{{.9,.6,.2},1,row.roughness}}};
            for(unsigned caseID=0;caseID<materials.size();++caseID){auto m=materials[caseID];
                // 此预测不调用完整BRDF积分：镜面使用独立积分基，漫反射使用已证明的归一化结果。
                V reference=energy::Colored(ref.basis,pbr::F0(m))+m.base*((1-m.metallic)*(1-row.At(c)));
                Require(reference.x<=1.0001&&reference.y<=1.0001&&reference.z<=1.0001,"colored/mixed energy bound");
                for(unsigned mode=0;mode<2;++mode){Stats stat;std::mt19937 random(3407+caseID*31+mode*103+unsigned(angle)+unsigned(row.roughness*100));
                    auto uniform=[&](){return (double(random())+.5)/4294967296.;};
                    for(unsigned n=0;n<65536;++n){double choice=uniform(),u=uniform(),v=uniform();stat.Add(Draw(m,wo,mode,row,choice,u,v));}
                    V mean=stat.Mean(),se=stat.SE();samples+=stat.n;
                    Require(std::abs(mean.x-reference.x)<6*se.x+1e-4&&std::abs(mean.y-reference.y)<6*se.y+1e-4&&std::abs(mean.z-reference.z)<6*se.z+1e-4,"mixed sampling confidence");
                    sampling<<row.roughness<<','<<angle<<','<<caseID<<','<<mode<<','<<stat.n<<','<<reference.x<<','<<mean.x<<','<<se.x<<','<<reference.y<<','<<mean.y<<','<<se.y<<','<<reference.z<<','<<mean.z<<','<<se.z<<'\n';
                }
            }
        }
        std::mt19937 random(983);auto uniform=[&](){return (double(random())+.5)/4294967296.;};
        auto direction=[&](){double c=.01+.99*uniform(),phi=2*ggx::Pi*uniform(),s=std::sqrt(1-c*c);return V{s*std::cos(phi),s*std::sin(phi),c};};
        for(unsigned j=0;j<2000;++j){V wo=direction(),wi=direction();pbr::Material m{{.2,.6,.9},.3,row.roughness};
            double error=Error(energy::Eval(m,wo,wi,0,row).f,energy::Eval(m,wi,wo,0,row).f);maxReciprocity=std::max(maxReciprocity,error);
            Require(error<1e-9,"reciprocity");
            // 单侧(1-Eo)*B/pi虽可守恒，但交换方向后不同，保留这个反例。
            maxNaiveReciprocity=std::max(maxNaiveReciprocity,std::abs(row.At(wo.z)-row.At(wi.z))/ggx::Pi);
        }
    }
    Require(bad80>1.26&&maxNaiveReciprocity>.1,"negative control was not detected");
    Require(std::abs(rows[0].average-3./35)<1e-15,"analytic delta average");
    unsigned rejected=0;
    try{energy::Converged(-1,.5);}catch(const std::exception&){++rejected;}
    try{rows[1].At(1.1);}catch(const std::exception&){++rejected;}
    try{auto bad=rows[1];bad.values[3]=1.1;bad.Normalize();}catch(const std::exception&){++rejected;}
    try{energy::Eval({{1,1,1},0,.5},{0,0,1},{0,0,1},0,rows[1]);}catch(const std::exception&){++rejected;}
    Require(rejected==4,"invalid input rejection");
    std::ostringstream report;report<<std::setprecision(12)<<"ENERGY CPU PASS samples="<<samples<<" rows=5 nodes_per_row=257 offgrid="<<offGrid<<" reciprocity_pairs=10000\n"
        <<"max_quadrature_change="<<maxChange<<" max_order="<<maxOrder<<" max_interpolation_error="<<maxTableError<<'\n'
        <<"max_white_error="<<maxWhiteError<<" max_independent_integral_error="<<maxIndependent<<" max_reciprocity_error="<<maxReciprocity<<'\n'
        <<"negative_baseline_80="<<bad80<<" negative_one_sided_reciprocity="<<maxNaiveReciprocity<<" rejected="<<rejected<<'\n'
        <<"CPU_ONLY; tested roughness={0,.25,.5,.75,1}; no roughness interpolation, GPU LUT or full integrator yet.\n";
    summary<<report.str();std::cout<<report.str();return 0;
}catch(const std::exception& e){std::cerr<<"ENERGY FAIL: "<<e.what()<<'\n';return 1;}}
