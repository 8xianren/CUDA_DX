#include "../dxr-path-tracer/energy_lut.h"
#include "vndf_energy.h"
#include "energy_quadrature.h"
#include <atomic>
#include <future>
#include <iostream>
#include <iomanip>
#include <sstream>
int main(int argc,char** argv){try{
    if(argc!=2)throw std::runtime_error("energy_lut_build output-directory");
    namespace pe=pbr_energy;std::filesystem::path out=argv[1];std::filesystem::create_directories(out);
    auto coarse=vndf::Points(4096),fine=vndf::Points(16384),extra=vndf::Points(65536);
    pe::Table table;table.data.resize(pe::AverageOffset+pe::Rows);table.data[0]=pe::Rows;table.data[1]=pe::Columns;table.data[2]=pe::MinAlpha;table.data[3]=pe::AverageOffset;
    std::atomic<unsigned> next{0},refined{0};std::vector<double> changes(pe::Rows);std::vector<std::future<void>> jobs;
    // CPU工作线程独占不同表行，预生成圆盘点只读；get后才能计算平均/写文件/上传GPU。
    for(unsigned worker=0;worker<12;++worker)jobs.push_back(std::async(std::launch::async,[&](){
        for(unsigned row=next.fetch_add(1);row<pe::Rows;row=next.fetch_add(1)){
            double a=pe::Alpha(row);
            for(unsigned col=0;col<pe::Columns;++col){double c=pe::Cosine(col),v0=vndf::Integral(a,c,coarse),v=vndf::Integral(a,c,fine);
                double change=std::abs(v-v0);
                if(change>1e-4){v0=v;v=vndf::Integral(a,c,extra);change=std::abs(v-v0);++refined;}
                if(change>3e-4)throw std::runtime_error("VNDF table refinement failed");
                changes[row]=std::max(changes[row],change);table.data[pe::Header+row*pe::Columns+col]=float(v);
            }
        }
    }));for(auto& job:jobs)job.get();
    for(unsigned row=0;row<pe::Rows;++row){double average=0;
        for(unsigned col=0;col+1<pe::Columns;++col){double c=pe::Cosine(col),h=pe::Cosine(col+1)-c;
            double e=table.data[pe::Header+row*pe::Columns+col],d=table.data[pe::Header+row*pe::Columns+col+1]-e;
            average+=2*h*(e*c+(e*h+d*c)/2+d*h/3);
        }table.data[pe::AverageOffset+row]=float(average);
    }table.Validate();std::cout<<"LUT built, validating off-grid and independent integrals\n"<<std::flush;
    // 表外参考增加到262144点，并对第二轴作数字扰动。不是严格误差界或普通IID标准误差。
    auto reference=vndf::Points(262144,0x12345678u);double maxOff=0,maxCross=0;
    std::ofstream csv(out/"offgrid.csv");csv<<std::setprecision(12)<<"roughness,cosine,lut,reference,error\n";
    for(unsigned i=0;i<512;++i){double r=std::sqrt(1e-4*std::pow(1e4,(i+.37)/512.));
        double u=std::fmod(i*.6180339887498949+.113,1.),c=u*u*u*u;
        double ref=vndf::Integral(r*r,c,reference),got=table.At(r,c),error=std::abs(ref-got);maxOff=std::max(maxOff,error);
        csv<<r<<','<<c<<','<<got<<','<<ref<<','<<error<<'\n';
        if(error>.001)throw std::runtime_error("off-grid LUT error exceeds .001");
    }
    // 与上一节完全不同的入射方向Gauss积分交叉检查，防止VNDF分布/权重共同写错。
    for(double r:{.25,.5,.75,1.})for(double c:{.01,.1,.1736481776669303,.5,1.}){
        double direct=energy::Dielectric(energy::Converged(r,c).basis),ref=vndf::Integral(r*r,c,reference);
        maxCross=std::max(maxCross,std::abs(ref-direct));if(std::abs(ref-direct)>1e-4)throw std::runtime_error("VNDF versus direction integral");
    }
    std::ofstream file(out/"energy-lut.bin",std::ios::binary);file.write(reinterpret_cast<const char*>(table.data.data()),table.data.size()*sizeof(float));
    if(!file||!csv)throw std::runtime_error("energy LUT write failed");file.close();auto loaded=pe::Load(out/"energy-lut.bin");
    if(loaded.data!=table.data)throw std::runtime_error("energy LUT roundtrip");
    std::ostringstream report;report<<std::setprecision(12)<<"LUT CPU PASS rows="<<pe::Rows<<" columns="<<pe::Columns<<" bytes="<<table.data.size()*sizeof(float)
        <<" refined="<<refined<<" max_refinement_change="<<*std::max_element(changes.begin(),changes.end())
        <<" offgrid=512 max_offgrid_error="<<maxOff<<" direct_integrals=20 max_direct_error="<<maxCross<<'\n';
    std::ofstream summary(out/"lut-summary.txt");summary<<report.str();std::cout<<report.str();return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
