#include "pbr_resources.h"
#include "pbr_math.h"
#include "ggx_quadrature.h"
#include "energy_quadrature.h"
#include "../dxr-path-tracer/energy_lut.h"
#include <cstring>
#include <fstream>
#include <iostream>
#include <iomanip>
using ggx::V;
// 同一测试宿主可运行基线或修正shader；额外LUT参数显式选择修正模型，不覆盖旧实验结果。
pbr_energy::Table energyTable;
bool balanced=false;
pbr::Evaluation Evaluate(pbr::Material p,V wo,V wi,unsigned mode){
    auto e=pbr::Eval(p,wo,wi,mode);if(balanced&&wo.z>0&&wi.z>0){
        double factor=(1-energyTable.At(p.roughness,wo.z))*(1-energyTable.At(p.roughness,wi.z))/(ggx::Pi*(1-energyTable.Average(p.roughness)));
        e.diffuse=p.base*((1-p.metallic)*factor);e.f=e.diffuse+e.specular;
    }return e;
}
struct Config {uint32_t width=640,height=64,seed=0,mode=0;float slope=0;uint32_t tiles=10,pad0=0,pad1=0;};
struct Record {float baseMetal[4],pointRough[4],normalPs[4],outgoingPdf[4],weightMass[4],emissionU0[4],random12Uv[4];uint32_t tags[4];};
static_assert(sizeof(Config)==32&&sizeof(Record)==128&&offsetof(Record,tags)==112);
void Require(bool v,const char* s){if(!v)throw std::runtime_error(s);}
struct Moment {uint64_t n=0;double mean=0,m2=0;void Add(double x){double d=x-mean;mean+=d/++n;m2+=d*(x-mean);}double SE()const{return n>1?std::sqrt(m2/(n-1)/n):0;}};
double Component(V v,int k){return k==0?v.x:(k==1?v.y:v.z);}
V ReadVector(const float* a){return {a[0],a[1],a[2]};}
double Random(uint32_t index,uint32_t seed,uint32_t dim){uint32_t x=(index+1)*747796405u+seed*2891336453u+dim*277803737u+0x9e3779b9u;
    x=(x^(x>>16))*0x21f0aaadu;x=(x^(x>>15))*0x735a2d97u;x^=x>>15;return ((x>>9)+.5)/8388608.;}
double Srgb(int code){double v=code/255.;return v<=.04045?v/12.92:std::pow((v+.055)/1.055,2.4);}
struct Reference {V value{};double difference=0;unsigned order=0;};
V Integrate(pbr::Material p,V wo,unsigned order){
    // 独立方向积分：在wi.z与phi上求整个混合BRDF，不调用GPU采样器，也不重放其随机方向。
    V sum{};auto nodes=ggx::Gauss(order,0,1);unsigned phiCount=2*order;
    for(auto q:nodes){double radius=std::sqrt(1-q.x*q.x);
        for(unsigned j=0;j<phiCount;++j){double phi=2*ggx::Pi*(j+.5)/phiCount;V wi{radius*std::cos(phi),radius*std::sin(phi),q.x};
            sum=sum+pbr::Eval(p,wo,wi,0).f*(q.x*q.w*2*ggx::Pi/phiCount);}}
    // 连续积分不会捕获delta镜面；其离散质量应独立加上Fspec，而不是给它虚构有限PDF。
    if(ggx::Delta({p.roughness,pbr::F0(p)}))sum=sum+ggx::Schlick(pbr::F0(p),wo.z);return sum;
}
Reference ReferenceIntegral(pbr::Material p,V wo){
    if(balanced){auto ref=energy::Converged(p.roughness,wo.z);Reference result;
        // 镜面用独立方向积分；漫反射积分由已证明的查表归一化结果给出。GPU值不参与参考生成。
        result.value=energy::Colored(ref.basis,pbr::F0(p))+p.base*((1-p.metallic)*(1-energyTable.At(p.roughness,wo.z)));
        result.difference=ref.change;result.order=ref.order;return result;}
    Reference r;V low=Integrate(p,wo,128);r.order=256;r.value=Integrate(p,wo,r.order);
    auto error=[](V a){return std::max({std::abs(a.x),std::abs(a.y),std::abs(a.z)});};r.difference=error(r.value-low);
    while(r.difference>3e-6&&r.order<2048){low=r.value;r.order*=2;r.value=Integrate(p,wo,r.order);r.difference=error(r.value-low);}
    Require(r.difference<3e-6,"PBR quadrature not converged");return r;
}
int main(int argc,char** argv){if(argc!=4&&argc!=5){std::cerr<<"pbr_test pbr.gltf pbr.dxil output-directory [energy-lut.bin]\n";return 2;}
    HRESULT com=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    try{
        Check(com,"COM");auto cpu=LoadCpuScene(argv[1]);uint32_t ids[10]{};
        for(uint32_t i=0;i<cpu.materialAssets.materials.size();++i){auto name=cpu.materialAssets.materials[i].name;
            if(name.size()==3&&name[0]=='m'){int tile=std::stoi(name.substr(1));Require(tile>=0&&tile<10,"fixture name");ids[tile]=i+1;}}
        for(auto id:ids)Require(id>0,"fixture material missing");
        UploadContext c;auto gpu=UploadScene(c,cpu);auto blases=BuildMeshBlases(c,gpu);c.SubmitWait();gpu.staging.clear();for(auto& b:blases)b.scratch.Reset();
        auto frame=BuildInstanceFrame(c,cpu,gpu,blases,false);auto bindings=PreparePbrBindings(c,cpu,gpu);
        balanced=argc==5;
        if(balanced){energyTable=pbr_energy::Load(argv[4]);bindings.energy=InstanceUpload(c,energyTable.data.data(),energyTable.data.size()*sizeof(float));}
        // 两个未支持语义必须失败，防止资产被接受后悄悄忽略alpha或法线贴图。
        auto bad=cpu;bad.materialAssets.materials[0].alpha=AlphaMode::Mask;bool rejected=false;
        try{auto unused=PreparePbrBindings(c,bad,gpu);}catch(const std::exception&){rejected=true;}Require(rejected,"MASK not rejected");
        bad=cpu;bad.materialAssets.materials[0].textures[2].image=0;rejected=false;
        try{auto unused=PreparePbrBindings(c,bad,gpu);}catch(const std::exception&){rejected=true;}Require(rejected,"normal map not rejected");
        std::filesystem::path out=argv[3];std::filesystem::create_directories(out);
        std::ofstream csv(out/"summary.csv"),trace(out/"samples.csv"),report(out/"summary.txt");Require(bool(csv)&&bool(trace)&&bool(report),"output open");
        double maxLookup=0,maxProbe=0,maxReciprocity=0,maxSampleProbe=0,maxReconstructedPdf=0;
        if(balanced){Config probe;probe.pad0=1;
            auto raw=DispatchMaterialBuffer(c,bindings,gpu,frame,&probe,sizeof(probe),probe.width,probe.height,size_t(probe.width)*probe.height*sizeof(Record),argv[2]);
            std::vector<Record> records(size_t(probe.width)*probe.height);memcpy(records.data(),raw.data(),raw.size());
            for(const auto& r:records){double rough=r.pointRough[3],co=r.pointRough[0],ci=r.pointRough[1];
                double wanted[]{energyTable.At(rough,co),energyTable.At(rough,ci),energyTable.Average(rough)};
                for(unsigned k=0;k<3;++k){double error=std::abs(r.baseMetal[k]-wanted[k]);Require(std::isfinite(error)&&error<2e-5,"GPU LUT query");maxLookup=std::max(maxLookup,error);}
                Require(std::isfinite(r.baseMetal[3])&&r.baseMetal[3]<1e-4,"GPU reciprocity");maxReciprocity=std::max(maxReciprocity,double(r.baseMetal[3]));
                V wo=ggx::Normalize(ReadVector(r.normalPs)),wi=ggx::Normalize(ReadVector(r.outgoingPdf));
                auto e=Evaluate({{.2,.6,.9},.3,rough},wo,wi,0);
                for(unsigned k=0;k<3;++k){double v=Component(e.f,k),error=std::abs(r.weightMass[k]-v)/(1+std::abs(v));
                    Require(std::isfinite(error)&&error<.001,"GPU full-domain BRDF probe");maxProbe=std::max(maxProbe,error);}
                if(co>0){pbr::Material material{{.2,.6,.9},.3,rough};V weight{};double pdf=0,mass=0;
                    unsigned event=r.tags[0]%4,branch=r.tags[0]/4;Require(event>=1&&event<=3,"GPU full-domain sample event");
                    if(branch==1&&event!=3){float hf[3];memcpy(hf,r.tags+1,sizeof(hf));V h=ggx::Normalize(ReadVector(hf));
                        uint32_t index=uint32_t(&r-records.data());V expected=ggx::NormalFromNdf(rough*rough,Random(index,93,1),Random(index,93,2));
                        Require(ggx::Dot(h-expected,h-expected)<1e-10,"probe NDF generated half-vector");}
                    if(event==3){weight=ggx::Schlick(pbr::F0(material),wo.z)*2;mass=.5;}
                    if(event==2){V sampled=ggx::Normalize(ReadVector(r.emissionU0));Require(sampled.z>0,"sample hemisphere");
                        auto sampleEval=Evaluate(material,wo,sampled,0);
                        if(!ggx::Delta({rough,{}})){
                            // CPU以读回的生成微面重算；其单位性和反射映射另验收，不把大相消误差放进容差。
                            float hf[3];memcpy(hf,r.tags+1,sizeof(hf));V h=ggx::Normalize(ReadVector(hf));double oh=ggx::Dot(wo,h);
                            if(branch==1){V reflected=h*(2*oh)-wo;Require(ggx::Dot(reflected-sampled,reflected-sampled)<1e-10,"preserved half-vector reflection");}
                            double d=ggx::D(h,rough*rough);sampleEval.specular=ggx::Schlick(pbr::F0(material),oh)*(d*ggx::G(wo,sampled,rough*rough)/(4*wo.z*sampled.z));
                            sampleEval.specPdf=d*h.z/(4*oh);sampleEval.pdf=.5*(sampleEval.specPdf+sampleEval.diffPdf);sampleEval.f=sampleEval.diffuse+sampleEval.specular;
                        }
                        pdf=sampleEval.pdf;weight=sampleEval.f*(sampled.z/pdf);}
                    if(event==2)maxReconstructedPdf=std::max(maxReconstructedPdf,std::abs(r.weightMass[3]-r.random12Uv[3])/(1+double(r.random12Uv[3])));
                    if(!(std::isfinite(r.random12Uv[3])&&std::abs(r.random12Uv[3]-pdf)<.005*(1+pdf))){
                        std::cerr<<std::setprecision(12)<<"sample probe rough="<<rough<<" co="<<co<<" event="<<event<<" branch="<<branch<<" wi="<<r.emissionU0[0]<<','<<r.emissionU0[1]<<','<<r.emissionU0[2]<<" actual_pdf="<<r.random12Uv[3]<<" expected="<<pdf<<'\n';
                        throw std::runtime_error("sample probe PDF");}
                    Require(std::abs(r.emissionU0[3]-mass)<1e-6,"sample probe mass");
                    for(unsigned k=0;k<3;++k){double v=Component(weight,k),error=std::abs(r.random12Uv[k]-v)/(1+std::abs(v));
                        Require(std::isfinite(error)&&error<.005,"sample probe weight");maxSampleProbe=std::max(maxSampleProbe,error);}
                }
            }
            Require(maxReconstructedPdf>.01,"half-vector cancellation negative control");
        }
        csv<<std::setprecision(12)<<"angle,mode,tile,quadrant,samples,specular_count,null_count,delta_count,base_r,metallic,roughness,r_mean,r_SE,r_reference,g_mean,g_SE,g_reference,b_mean,b_SE,b_reference,wrong_selected_pdf_r,wrong_SE,quad_difference,quad_order\n";
        trace<<std::setprecision(12)<<"angle,mode,seed,pixel,material,event,branch,base_r,metallic,roughness,ps,pdf,mass,weight_r,emission_r\n";
        uint64_t paths=0,rays=0;double maxNumeric=0,maxTexture=0,maxPosition=0,maxEnergy=0;unsigned energyCases=0;
        struct Stats {Moment rgb[3],wrong;uint64_t spec=0,nulls=0,delta=0;pbr::Material material{};bool initialized=false;};
        for(double degrees:{0.,60.,80.})for(uint32_t mode=0;mode<2;++mode){Config cfg;cfg.mode=mode;cfg.slope=float(std::tan(degrees*ggx::Pi/180));
            double len=std::sqrt(1+double(cfg.slope)*cfg.slope);V wo{-cfg.slope/len,0,1/len};Stats stats[40];
            auto check=[&](double a,double b,double tolerance){Require(std::isfinite(a)&&std::abs(a-b)<=tolerance,"PBR numeric mismatch");};
            for(uint32_t seed=0;seed<8;++seed){cfg.seed=seed;auto bytes=DispatchMaterialBuffer(c,bindings,gpu,frame,&cfg,sizeof(cfg),cfg.width,cfg.height,size_t(cfg.width)*cfg.height*sizeof(Record),argv[2]);
                std::vector<Record> records(size_t(cfg.width)*cfg.height);std::memcpy(records.data(),bytes.data(),bytes.size());
                for(uint32_t index=0;index<records.size();++index){const auto& r=records[index];uint32_t x=index%cfg.width,y=index/cfg.width,tile=x/64,q=(y>=32?2:0)+(x%64>=32?1:0);
                    auto& s=stats[4*tile+q];const auto& asset=cpu.materialAssets.materials[ids[tile]-1];
                    Require(r.tags[2]+1==ids[tile],"DXR material identity");
                    double expectedX=(x+.5)*2/64-10,expectedY=(y+.5)*2/64-1;
                    check(r.pointRough[0],expectedX,3e-5);check(r.pointRough[1],expectedY,3e-5);check(r.pointRough[2],0,3e-5);
                    maxPosition=std::max(maxPosition,std::max(std::abs(r.pointRough[0]-expectedX),std::abs(r.pointRough[1]-expectedY)));
                    check(r.normalPs[0],0,1e-6);check(r.normalPs[1],0,1e-6);check(r.normalPs[2],1,1e-6);
                    check(r.random12Uv[2],(x%64+.5)/64,3e-5);check(r.random12Uv[3],(y+.5)/64,3e-5);
                    // 材质通道单独对解析PNG码值检查，BRDF数值审计随后使用已检查的实际GPU解码值。
                    int basePixels[4][3]{{200,40,20},{40,200,20},{20,40,200},{220,180,100}},emPixels[4][3]{{32,64,128},{64,128,32},{128,32,64},{255,255,255}};
                    int roughCodes[]{64,128,192,255},metalCodes[]{0,85,170,255};double vertex[]{.5,.75,1};
                    for(int k=0;k<3;++k){double expected=asset.baseColor[k]*(tile==9?vertex[k]*Srgb(basePixels[q][k]):1);
                        check(r.baseMetal[k],expected,.002);maxTexture=std::max(maxTexture,std::abs(r.baseMetal[k]-expected));
                        double emission=asset.emissive[k]*(tile==9?Srgb(emPixels[q][k]):1);check(r.emissionU0[k],emission,.002);}
                    check(r.baseMetal[3],asset.metallic*(tile==9?metalCodes[q]/255.:1),2e-6);
                    check(r.pointRough[3],asset.roughness*(tile==9?roughCodes[q]/255.:1),2e-6);
                    pbr::Material material{ReadVector(r.baseMetal),r.baseMetal[3],r.pointRough[3]};
                    if(!s.initialized){s.material=material;s.initialized=true;}
                    else {check(material.base.x,s.material.base.x,1e-7);check(material.metallic,s.material.metallic,1e-7);check(material.roughness,s.material.roughness,1e-7);}
                    double ps=pbr::SpecProbability(material,mode),u0=Random(index,seed,0),u=Random(index,seed,1),v=Random(index,seed,2);
                    check(r.normalPs[3],ps,1e-6);check(r.emissionU0[3],u0,1e-7);check(r.random12Uv[0],u,1e-7);check(r.random12Uv[1],v,1e-7);
                    bool spec=u0<r.normalPs[3];Require(r.tags[1]==(spec?1u:2u),"sampling branch");s.spec+=spec;
                    bool delta=spec&&ggx::Delta({material.roughness,pbr::F0(material)});V wi{};unsigned event=2;
                    if(delta){wi={-wo.x,-wo.y,wo.z};event=3;}
                    else if(spec){V h=ggx::NormalFromNdf(ggx::Alpha({material.roughness,{}}),u,v);double oh=ggx::Dot(wo,h);
                        if(oh<=0)event=1;else{wi=h*(2*oh)-wo;if(wi.z<=0)event=1;}}
                    else {double radius=std::sqrt(u),phi=2*ggx::Pi*v;wi={radius*std::cos(phi),radius*std::sin(phi),std::sqrt(1-u)};}
                    Require(r.tags[0]==event&&r.tags[3]==(event==1?1u:2u),"event/secondary miss/count");s.nulls+=event==1;s.delta+=event==3;
                    V expectedWeight{};double wantedPdf=0,wantedMass=0,wrong=0;
                    if(event!=1){for(int k=0;k<3;++k)check(r.outgoingPdf[k],Component(wi,k),3e-5);
                        // 用实际出射方向重新求BRDF，避免把float方向扰动在窄峰上的放大误判为PDF实现错误。
                        V actual=ggx::Normalize(ReadVector(r.outgoingPdf));
                        if(event==3){wantedMass=ps;expectedWeight=ggx::Schlick(pbr::F0(material),wo.z)*(1/ps);wrong=expectedWeight.x;}
                        else {auto e=Evaluate(material,wo,actual,mode);wantedPdf=e.pdf;expectedWeight=e.f*(actual.z/e.pdf);
                            double selected=spec?ps*e.specPdf:(1-ps)*e.diffPdf;wrong=e.f.x*actual.z/selected;}}
                    check(r.outgoingPdf[3],wantedPdf,.002*(1+wantedPdf));check(r.weightMass[3],wantedMass,1e-6);
                    for(int k=0;k<3;++k){double expected=Component(expectedWeight,k),error=std::abs(r.weightMass[k]-expected)/(1+std::abs(expected));
                        maxNumeric=std::max(maxNumeric,error);check(r.weightMass[k],expected,5e-4*(1+std::abs(expected)));s.rgb[k].Add(r.weightMass[k]);}
                    s.wrong.Add(wrong);++paths;rays+=r.tags[3];
                    if(seed==0&&(x%64==0||x%64==32)&&(y==0||y==32))trace<<degrees<<','<<mode<<','<<seed<<','<<index<<','<<r.tags[2]<<','<<event<<','<<r.tags[1]
                        <<','<<material.base.x<<','<<material.metallic<<','<<material.roughness<<','<<ps<<','<<wantedPdf<<','<<wantedMass<<','<<r.weightMass[0]<<','<<r.emissionU0[0]<<'\n';
                }
            }
            for(uint32_t tile=0;tile<10;++tile)for(uint32_t q=0;q<4;++q){auto& s=stats[4*tile+q];auto reference=ReferenceIntegral(s.material,wo);double count=double(s.rgb[0].n),ps=pbr::SpecProbability(s.material,mode);
                Require(std::abs(s.spec/count-ps)<6*std::sqrt(ps*(1-ps)/count)+2e-6,"mixture branch frequency");
                csv<<degrees<<','<<mode<<','<<tile<<','<<q<<','<<s.rgb[0].n<<','<<s.spec<<','<<s.nulls<<','<<s.delta<<','<<s.material.base.x<<','<<s.material.metallic<<','<<s.material.roughness;
                for(int k=0;k<3;++k){double target=Component(reference.value,k);Require(std::abs(s.rgb[k].mean-target)<6*s.rgb[k].SE()+.0001,"PBR mean vs quadrature");
                    csv<<','<<s.rgb[k].mean<<','<<s.rgb[k].SE()<<','<<target;}
                csv<<','<<s.wrong.mean<<','<<s.wrong.SE()<<','<<reference.difference<<','<<reference.order<<'\n';
                if(ps<1&&!ggx::Delta({s.material.roughness,pbr::F0(s.material)}))
                    Require(std::abs(s.wrong.mean-2*reference.value.x)<8*s.wrong.SE()+.0002,"selected-PDF negative control must double integral");
                if(tile<=1){maxEnergy=std::max(maxEnergy,reference.value.x);if(reference.value.x>1.001)++energyCases;
                    if(balanced)Require(std::abs(reference.value.x-1)<.001,"balanced white furnace model");}
            }
            std::cout<<"angle="<<degrees<<" mode="<<mode<<" materials/textures/mixture PASS\n";
        }
        Require(balanced?energyCases==0:energyCases>0,"energy model classification");
        if(balanced){report<<std::setprecision(12)<<"BALANCED GPU PASS paths="<<paths<<" TraceRay="<<rays<<" probes=40960 max_LUT_error="<<maxLookup
            <<" max_probe_relative_error="<<maxProbe<<" max_sample_probe_relative_error="<<maxSampleProbe<<" max_reciprocity_relative_error="<<maxReciprocity<<" max_relative_weight_error="<<maxNumeric<<" max_white_output="<<maxEnergy<<" negative_reconstructed_pdf_relative="<<maxReconstructedPdf<<'\n';}
        else {
        report<<std::setprecision(12)<<"PBR GPU sampling PASS paths="<<paths<<" TraceRay="<<rays<<" max_relative_weight_error="<<maxNumeric
            <<" max_base_texture_error="<<maxTexture<<" max_position_error="<<maxPosition<<"\nMODEL_ENERGY_FAILURE cases="<<energyCases<<" max_white_output="<<maxEnergy
            <<"\nThe sampling implementation passes; the baseline diffuse/specular coupling is not energy conserving. PT.8 remains incomplete pending correction.\n";
        }
        report.flush();csv.flush();trace.flush();Require(bool(report)&&bool(csv)&&bool(trace),"output write");Require(c.CheckDebug()==0,"D3D debug");
        std::cout<<(balanced?"BALANCED":"BASELINE")<<" GPU sampling PASS paths="<<paths<<" TraceRay="<<rays<<" max white="<<maxEnergy<<'\n';
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';if(SUCCEEDED(com))CoUninitialize();return 1;}CoUninitialize();return 0;
}
