#include "material_sampling.h"
#include "mis_math.h"
#include <fstream>
#include <iostream>
#include <iomanip>
#include <stdexcept>
#include <array>
namespace {
constexpr int width=24,height=24,spp=64,seeds=16;
constexpr int count=width*height;
const char* names[]={"bsdf","nee","balance","power","wrong-add"};
struct Sample {double pB,pL;};
void Require(bool ok,const char* msg){if(!ok)throw std::runtime_error(msg);}
void Save(const std::filesystem::path& out,const std::string& name,const std::vector<double>& pixels,double exposure){
    std::ofstream csv(out/(name+".csv"));csv<<"x,y,linear_radiance\n";
    std::ofstream ppm(out/(name+".ppm"),std::ios::binary);ppm<<"P6\n"<<width<<' '<<height<<"\n255\n";
    for(int p=0;p<count;++p){csv<<p%width<<','<<p/width<<','<<std::setprecision(12)<<pixels[p]<<'\n';
        double v=std::clamp(pixels[p]*exposure,0.,1.);v=v<=.0031308?12.92*v:1.055*std::pow(v,1/2.4)-.055;
        uint8_t b=uint8_t(std::lround(v*255));for(int k=0;k<3;++k)ppm.write(reinterpret_cast<char*>(&b),1);}
}
}
int main(int argc,char** argv){
    if(argc!=5){std::cerr<<"usage: mis_test scene.gltf visibility.dxil output-dir light-half-size\n";return 2;}
    HRESULT com=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    try{
        Check(com,"COM");double h=std::stod(argv[4]);Require(h>0,"invalid light size");
        std::filesystem::path out=argv[3];std::filesystem::create_directories(out);
        auto cpu=LoadCpuScene(argv[1]);int emitter=-1,receiver=-1;
        for(size_t i=0;i<cpu.materialAssets.materials.size();++i){const auto& m=cpu.materialAssets.materials[i];
            if(m.name=="Emitter")emitter=int(i);if(m.name=="Receiver")receiver=int(i);}
        Require(emitter>=0&&receiver>=0,"fixture material missing");
        double le=cpu.materialAssets.materials[emitter].emissive[0],rho=cpu.materialAssets.materials[receiver].baseColor[0];
        Require(le>0&&rho>0,"fixture radiance invalid");
        UploadContext c;auto gpu=UploadScene(c,cpu);auto blases=BuildMeshBlases(c,gpu);
        c.SubmitWait();gpu.staging.clear();for(auto& b:blases)b.scratch.Reset();
        auto bindings=PrepareMaterialBindings(c,cpu,gpu);auto frame=BuildInstanceFrame(c,cpu,gpu,blases,false);
        // 输出是已知receiver平面上的直接出射辐亮度图，不经过相机主射线；rho/Le读自glTF因子。
        std::vector<double> reference(count);double quadratureError=0,referenceMean=0;
        for(int p=0;p<count;++p){double x=2.*(p%width+.5)/width-1,y=2.*(p/width+.5)/height-1;
            reference[p]=mis::Reference(x,y,h,rho,le,512);double coarse=mis::Reference(x,y,h,rho,le,256);
            quadratureError=std::max(quadratureError,std::abs(reference[p]-coarse));referenceMean+=reference[p]/count;}
        double exposure=h<1?16:1;Save(out,"reference",reference,exposure);
        std::array<std::vector<double>,5> sum,sum2;for(int k=0;k<5;++k){sum[k].resize(count);sum2[k].resize(count);}
        std::array<double,5> mse{},meanSum{},meanSquare{};uint64_t mismatches=0,totalRays=0;
        std::ofstream metrics(out/"seed_metrics.csv");metrics<<"seed,mode,mean,mse\n";
        for(int seed=0;seed<seeds;++seed){
            std::vector<MaterialRay> rays;std::vector<Sample> records;
            rays.reserve(count*spp*4);records.reserve(count*spp*4);
            for(int p=0;p<count;++p){double x=2.*(p%width+.5)/width-1,y=2.*(p/width+.5)/height-1;
                mis::Rng rng(0x12345678u+uint64_t(seed)*7919,p+1);
                for(int s=0;s<spp;++s)for(int technique=0;technique<4;++technique){
                    double dx,dy,dz;
                    if(technique<2){double qx=(2*rng.Uniform()-1)*h,qy=(2*rng.Uniform()-1)*h;
                        dx=qx-x;dy=qy-y;dz=2;double len=std::sqrt(dx*dx+dy*dy+4);dx/=len;dy/=len;dz/=len;
                    }else{ // Lambert余弦半球采样：r=sqrt(u)，phi=2*pi*v，z=sqrt(1-u)。
                        double u=rng.Uniform(),phi=2*mis::pi*rng.Uniform();dx=std::sqrt(u)*std::cos(phi);dy=std::sqrt(u)*std::sin(phi);dz=std::sqrt(1-u);}
                    MaterialRay ray{{float(x),float(y),0},1e-5f,{float(dx),float(dy),float(dz)},1e6f};
                    // 使用实际传给DXR的float射线评估方向PDF；不让参考与GPU使用不同射线。
                    double len=std::sqrt(double(ray.direction[0])*ray.direction[0]+double(ray.direction[1])*ray.direction[1]+double(ray.direction[2])*ray.direction[2]);
                    double cosine=ray.direction[2]/len,t=2./ray.direction[2];
                    double qx=ray.origin[0]+t*ray.direction[0],qy=ray.origin[1]+t*ray.direction[1];
                    bool inLight=mis::Inside(qx,qy,-h,h,-h,h);
                    // pL为面积PDF转立体角：r²/(A*cos_light)，本场景cos_light=cos_surface。
                    double pL=inLight?4/(cosine*cosine)/(4*h*h*cosine):0;
                    rays.push_back(ray);records.push_back({cosine/mis::pi,pL});
                }
            }
            auto hits=SampleHitMaterials(c,bindings,gpu,frame,rays,argv[2]);totalRays+=rays.size();
            std::array<std::vector<double>,5> image;for(auto& v:image)v.resize(count);
            for(size_t i=0;i<rays.size();i+=4){
                double contribution[4]{};
                for(int j=0;j<4;++j){const auto& ray=rays[i+j];const auto& rec=records[i+j];
                    double t=2./ray.direction[2],qx=ray.origin[0]+t*ray.direction[0],qy=ray.origin[1]+t*ray.direction[1];
                    bool expected=rec.pL>0&&!mis::Blocked(ray.origin[0],ray.origin[1],qx,qy);
                    bool actual=uint32_t(hits[i+j][0])==uint32_t(emitter+1);mismatches+=actual!=expected;
                    double own=j<2?rec.pL:rec.pB;
                    if(actual&&own>0)contribution[j]=rho*le*rec.pB/own;
                }
                int p=int(i/(spp*4));
                // 公平射线预算：pure方法每轮2条；MIS每轮1条L+1条B。额外纯方法样本只用于对照。
                image[0][p]+=(contribution[2]+contribution[3])/(2*spp);
                image[1][p]+=(contribution[0]+contribution[1])/(2*spp);
                const auto& L=records[i];const auto& B=records[i+2];
                for(int k=2;k<=3;++k)image[k][p]+=(mis::Weight(L.pL,L.pB,k-1)*contribution[0]+mis::Weight(B.pB,B.pL,k-1)*contribution[2])/spp;
                // 故意的错误：两个完整估计直接相加，其期望为2I，供课堂诊断。
                image[4][p]+=(contribution[0]+contribution[2])/spp;
            }
            for(int k=0;k<5;++k){double mean=0,error=0;for(int p=0;p<count;++p){double v=image[k][p];Require(std::isfinite(v),"nonfinite estimate");
                    sum[k][p]+=v;sum2[k][p]+=v*v;mean+=v/count;error+=(v-reference[p])*(v-reference[p])/count;}
                mse[k]+=error/seeds;meanSum[k]+=mean;meanSquare[k]+=mean*mean;metrics<<seed<<','<<names[k]<<','<<mean<<','<<error<<'\n';
                if(seed==0)Save(out,std::string(names[k])+"-seed0",image[k],exposure);
            }
        }
        Require(mismatches==0,"DXR/CPU visibility mismatch");
        std::ofstream report(out/"summary.csv");report<<"mode,mean,reference_mean,mean_standard_error,mse,mean_pixel_variance\n";
        for(int k=0;k<5;++k){double mean=meanSum[k]/seeds,variance=0;
            double se=std::sqrt(std::max(0.,(meanSquare[k]-meanSum[k]*meanSum[k]/seeds)/(seeds-1)/seeds));
            for(int p=0;p<count;++p){variance+=(sum2[k][p]-sum[k][p]*sum[k][p]/seeds)/(seeds-1)/count;sum[k][p]/=seeds;}
            Save(out,std::string(names[k])+"-mean",sum[k],exposure);
            std::cout<<names[k]<<" mean="<<mean<<" ref="<<referenceMean<<" SE="<<se<<" MSE="<<mse[k]<<" variance="<<variance<<'\n';
            report<<names[k]<<','<<mean<<','<<referenceMean<<','<<se<<','<<mse[k]<<','<<variance<<'\n';
            // 有限样本不能证明无偏；只检查均值与独立参考在统计/求积误差范围内相容。
            double target=(k==4?2:1)*referenceMean;
            Require(std::abs(mean-target)<=6*se+2*quadratureError+1e-6,"mean inconsistent with reference");
        }
        Require(c.CheckDebug()==0,"GPU debug failure");
        std::cout<<"PASS PT.6 direct estimator laboratory samples_per_pixel_per_method="<<2*spp<<" seeds="<<seeds
                 <<" traced_rays="<<totalRays<<" visibility_mismatch="<<mismatches<<" quadrature_max_change="<<quadratureError<<'\n';
    }catch(const std::exception& e){std::cerr<<"FAIL "<<e.what()<<'\n';if(SUCCEEDED(com))CoUninitialize();return 1;}
    CoUninitialize();return 0;
}
