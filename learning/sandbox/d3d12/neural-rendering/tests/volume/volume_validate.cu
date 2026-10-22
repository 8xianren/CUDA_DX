#include "../../src/volume/volume.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <numeric>
#include <stdexcept>
#include <string>

using namespace neural::volume;
namespace fs=std::filesystem;
void Check(cudaError_t e,const char* op) {if(e!=cudaSuccess) throw std::runtime_error(std::string(op)+": "+cudaGetErrorString(e));}
void Require(bool ok,const std::string& message) {if(!ok) throw std::runtime_error(message);}
struct Error {double rmse=0,max=0;};
Error Compare(const std::vector<float4>& a,const std::vector<float4>& b) {
    Require(a.size()==b.size(),"image dimensions differ"); Error e;
    // RGBA一起比较，避免颜色偶然遮住透射率错误；计时不包含读回或此CPU比较。
    for(size_t i=0;i<a.size();++i) {
        const float aa[4]={a[i].x,a[i].y,a[i].z,a[i].w},bb[4]={b[i].x,b[i].y,b[i].z,b[i].w};
        for(int c=0;c<4;++c) {Require(std::isfinite(aa[c]),"non-finite pixel");const double d=std::abs(double(aa[c])-bb[c]); e.rmse+=d*d;e.max=std::max(e.max,d);}
    }
    e.rmse=sqrt(e.rmse/(a.size()*4)); return e;
}
void WritePpm(const fs::path& path,const std::vector<float4>& pixels,int width,int height) {
    std::ofstream f(path,std::ios::binary);f<<"P6\n"<<width<<" "<<height<<"\n255\n";
    for(auto p:pixels) for(float c:{p.x,p.y,p.z}) {
        // 仅预览：线性预乘图像合成黑背景后做sRGB OETF，误差统计仍在线性浮点域进行。
        c=std::clamp(c,0.0f,1.0f);c=c<=.0031308f?12.92f*c:1.055f*powf(c,1/2.4f)-.055f;
        f.put(char(std::clamp(int(c*255+.5f),0,255)));
    }
}
struct Buffers {
    float4* pixels=nullptr; float* depth=nullptr;float* mesh=nullptr;PixelStats* stats=nullptr;
    size_t count;
    explicit Buffers(size_t n):count(n) {
        Check(cudaMalloc(&pixels,n*sizeof(float4)),"alloc rgba");Check(cudaMalloc(&depth,n*sizeof(float)),"alloc depth");
        Check(cudaMalloc(&mesh,n*sizeof(float)),"alloc mesh");Check(cudaMalloc(&stats,n*sizeof(PixelStats)),"alloc stats");
    }
    ~Buffers(){cudaFree(pixels);cudaFree(depth);cudaFree(mesh);cudaFree(stats);}
    std::vector<float4> Read() const {std::vector<float4> p(count);Check(cudaMemcpy(p.data(),pixels,count*sizeof(float4),cudaMemcpyDeviceToHost),"read rgba");return p;}
};
void G1(const fs::path& root) {
    fs::create_directories(root/"g1");
    std::ofstream trace(root/"g1/ray_trace.csv");trace<<std::setprecision(17)<<"index,t,sigma,delta,alpha,T_before,weight,T_after\n";
    double T=1,sum=0,minWeight=1;
    // 中心射线，从 z=-1 积分到 z=+1；密度使用double独立解析计算，避免float公共公式掩盖错误。
    constexpr double step=.025;
    for(int i=0;i<80;++i) {
        const double z=-1+(i+.5)*step,q=std::max(0.0,1-z*z/(.65*.65));
        const double sigma=20*q*q,alpha=-std::expm1(-sigma*step),weight=T*alpha,before=T;
        sum+=weight;minWeight=std::min(minWeight,weight);T*=1-alpha;
        trace<<i<<','<<z<<','<<sigma<<','<<step<<','<<alpha<<','<<before<<','<<weight<<','<<T<<'\n';
    }
    Require(minWeight>=0 && sum<=1.0+1e-12 && std::abs(sum+T-1)<1e-12,"weight partition failed");
    const double exactT=std::exp(-16*20*.65/15);
    Camera c;RenderOptions o;o.width=64;o.height=64;o.termination=0;o.step=1.0f/1024;
    auto reference=RenderCpu(nullptr,c,o);
    WritePpm(root/"g1/analytic_sphere.ppm",reference,o.width,o.height);
    std::ofstream convergence(root/"g1/convergence.csv");convergence<<std::setprecision(12)<<"step,rgba_rmse_vs_1_over_1024,max_abs\n";
    double previous=1;bool decreasing=true;
    for(float stepSize:{.125f,.0625f,.03125f,.015625f}) {
        o.step=stepSize;auto e=Compare(RenderCpu(nullptr,c,o),reference);decreasing&=e.rmse<previous;previous=e.rmse;
        convergence<<stepSize<<','<<e.rmse<<','<<e.max<<'\n';
    }
    Require(decreasing,"analytic step convergence failed");
    std::ofstream summary(root/"g1/summary.json");summary<<std::setprecision(14)
        <<"{\n  \"status\": \"PASS\",\n  \"ray_steps\": 80,\n  \"weight_sum\": "<<sum<<",\n  \"final_transmittance\": "<<T
        <<",\n  \"exact_center_transmittance\": "<<exactT<<",\n  \"minimum_weight\": "<<minWeight<<",\n  \"partition_error\": "<<std::abs(sum+T-1)
        <<",\n  \"monotonic_image_convergence\": true\n}\n";
    std::cout<<"G1 PASS weights="<<sum<<" T="<<T<<" analytic_T="<<exactT<<'\n';
}
void G2(const fs::path& root,Volume& volume,const Field& field) {
    fs::create_directories(root/"g2"); Camera c;RenderOptions o;o.width=97;o.height=61;o.step=.0078125f;o.termination=.001f;
    Buffers b(size_t(o.width)*o.height);auto cpu=RenderCpu(&field,c,o);
    volume.Render(b.pixels,c,o,nullptr,b.depth,nullptr,b.stats);Check(cudaDeviceSynchronize(),"g2 render sync");auto gpu=b.Read();
    auto error=Compare(gpu,cpu);Require(error.max<.0005,"CPU/GPU trilinear mismatch > 5e-4");
    volume.Render(b.pixels,c,o);Check(cudaDeviceSynchronize(),"repeat sync");auto repeat=Compare(gpu,b.Read());Require(repeat.max==0,"render not deterministic");
    o.skipEmpty=true;volume.Render(b.pixels,c,o);Check(cudaDeviceSynchronize(),"skip sync");auto skip=Compare(gpu,b.Read());Require(skip.max<2e-6,"empty skip changes sample sequence");
    // 网格距离2.0在球前，必须全透明；网格距离4.0在球后，必须与无网格结果相同。
    std::vector<float> mesh(b.count,2);Check(cudaMemcpy(b.mesh,mesh.data(),b.count*sizeof(float),cudaMemcpyHostToDevice),"upload front mesh");
    volume.Render(b.pixels,c,o,nullptr,b.depth,b.mesh);Check(cudaDeviceSynchronize(),"mesh sync");
    auto blocked=b.Read();double blockedMax=0;for(auto p:blocked)blockedMax=std::max(blockedMax,double(p.w));Require(blockedMax==0,"front mesh did not occlude volume");
    Require(Compare(blocked,RenderCpu(&field,c,o,nullptr,mesh.data())).max==0,"front mesh CPU oracle mismatch");
    // 中间深度不是全挡/全透的平凡情形：CPU参考必须把最后一个积分段正确截短。
    std::fill(mesh.begin(),mesh.end(),3.0f);Check(cudaMemcpy(b.mesh,mesh.data(),b.count*sizeof(float),cudaMemcpyHostToDevice),"upload middle mesh");
    volume.Render(b.pixels,c,o,nullptr,b.depth,b.mesh);Check(cudaDeviceSynchronize(),"middle mesh sync");
    auto meshError=Compare(b.Read(),RenderCpu(&field,c,o,nullptr,mesh.data()));Require(meshError.max<.0005,"partial mesh CPU/GPU oracle mismatch");
    std::fill(mesh.begin(),mesh.end(),10.0f);Check(cudaMemcpy(b.mesh,mesh.data(),b.count*sizeof(float),cudaMemcpyHostToDevice),"upload back mesh");
    volume.Render(b.pixels,c,o,nullptr,b.depth,b.mesh);Check(cudaDeviceSynchronize(),"back mesh sync");Require(Compare(gpu,b.Read()).max<2e-6,"back mesh changed volume");
    // 奇数尺寸证明边界线程保护；相机在体内/平行slab、不整除8的网格、无交点分别覆盖不同失败路径。
    c.origin={0,0,0};volume.Render(b.pixels,c,o);Check(cudaDeviceSynchronize(),"inside camera sync");Require(Compare(b.Read(),RenderCpu(&field,c,o)).max<.0005,"inside-camera CPU/GPU mismatch");
    c.origin={0,0,-3};c.forward={0,0,-1};volume.Render(b.pixels,c,o);Check(cudaDeviceSynchronize(),"away camera sync");
    for(auto p:b.Read()) Require(p.w==0,"away-facing camera produced opacity");
    auto oddField=MakeSphereField(33);Volume oddVolume(oddField);c=Camera{};
    oddVolume.Render(b.pixels,c,o);Check(cudaDeviceSynchronize(),"odd field skip sync");auto oddSkipped=b.Read();
    o.skipEmpty=false;oddVolume.Render(b.pixels,c,o);Check(cudaDeviceSynchronize(),"odd field sync");Require(Compare(oddSkipped,b.Read()).max<2e-6,"non-divisible occupancy mismatch");
    o.jitter=true;o.seed=123;volume.Render(b.pixels,c,o);Check(cudaDeviceSynchronize(),"jitter sync");auto jittered=b.Read();
    o.skipEmpty=true;volume.Render(b.pixels,c,o);Check(cudaDeviceSynchronize(),"jitter skip sync");auto jitterError=Compare(jittered,b.Read());Require(jitterError.max<2e-6,"jitter+skip changes image");
    int rejected=0;
    try{auto bad=field;bad.density[0]=-1;Volume invalid(bad);}catch(const std::invalid_argument&){++rejected;}
    try{auto bad=field;bad.density.pop_back();Volume invalid(bad);}catch(const std::invalid_argument&){++rejected;}
    try{auto bad=o;bad.step=0;volume.Render(b.pixels,c,bad);}catch(const std::invalid_argument&){++rejected;}
    Require(rejected==3,"input validation failed");
    WritePpm(root/"g2/cuda_sphere.ppm",gpu,o.width,o.height);
    std::ofstream f(root/"g2/core_validation.json");f<<std::setprecision(12)<<"{\n  \"status\": \"PASS\",\n  \"width\": "<<o.width<<", \"height\": "<<o.height
        <<",\n  \"field_resolution\": "<<field.resolution<<",\n  \"cpu_gpu_rgba_rmse\": "<<error.rmse<<",\n  \"cpu_gpu_max_abs\": "<<error.max
        <<",\n  \"tolerance\": 0.0005,\n  \"repeat_max_abs\": "<<repeat.max<<",\n  \"skip_max_abs\": "<<skip.max
        <<",\n  \"jitter_skip_max_abs\": "<<jitterError.max<<",\n  \"front_mesh_max_alpha\": "<<blockedMax
        <<",\n  \"partial_mesh_cpu_gpu_max_abs\": "<<meshError.max
        <<",\n  \"inside_camera_cpu_gpu\": true,\n  \"away_camera_transparent\": true,\n  \"odd_resolution_skip_equivalence\": true,\n  \"invalid_inputs_rejected\": "<<rejected
        <<",\n  \"shared_texture_resize\": \"validated separately by G10 integration\"\n}\n";
    std::cout<<"G2 PASS CPU/GPU rmse="<<error.rmse<<" max="<<error.max<<" skip="<<skip.max<<'\n';
}
void G3(const fs::path& root,Volume& volume,bool profile) {
    fs::create_directories(root/"g3"); Camera camera;camera.tanHalfFovY=std::tan(25.0f*3.14159265358979323846f/180);
    RenderOptions o;o.width=640;o.height=360;Buffers b(size_t(o.width)*o.height);
    if(profile) {
        // 独立profile模式只启动一个明确命名内核，防止误采样CPU验证或其他变体。
        o.step=.0078125f;o.skipEmpty=true;volume.Render(b.pixels,camera,o,nullptr,nullptr,nullptr,b.stats);
        Check(cudaDeviceSynchronize(),"profile sync");return;
    }
    o.step=1.0f/1024;o.termination=0;volume.Render(b.pixels,camera,o);Check(cudaDeviceSynchronize(),"reference sync");auto reference=b.Read();
    WritePpm(root/"g3/reference.ppm",reference,o.width,o.height);
    std::ofstream f(root/"g3/quality_performance.csv");f<<std::setprecision(12)<<"step,skip,termination,jitter,gpu_median_ms,gpu_min_ms,gpu_max_ms,rgba_rmse,max_abs,avg_texture_samples,avg_skipped_steps,early_termination_ratio,hit_ratio\n";
    cudaEvent_t start,stop;Check(cudaEventCreate(&start),"create start event");Check(cudaEventCreate(&stop),"create stop event");
    for(float step:{.03125f,.015625f,.0078125f}) for(bool skip:{false,true}) {
        o.step=step;o.skipEmpty=skip;o.termination=.001f;
        for(int k=0;k<8;++k)volume.Render(b.pixels,camera,o);
        Check(cudaDeviceSynchronize(),"warmup sync");
        std::vector<float> times;
        // 统计输出不参与计时：避免写16B/像素统计缓冲影响待测的纯渲染成本。
        for(int k=0;k<40;++k) {
            Check(cudaEventRecord(start),"event start");volume.Render(b.pixels,camera,o);Check(cudaEventRecord(stop),"event stop");Check(cudaEventSynchronize(stop),"event sync");
            float ms;Check(cudaEventElapsedTime(&ms,start,stop),"event elapsed");times.push_back(ms);
        }
        std::sort(times.begin(),times.end());auto error=Compare(b.Read(),reference);
        volume.Render(b.pixels,camera,o,nullptr,nullptr,nullptr,b.stats);Check(cudaDeviceSynchronize(),"statistics sync");
        std::vector<PixelStats> stats(b.count);Check(cudaMemcpy(stats.data(),b.stats,b.count*sizeof(PixelStats),cudaMemcpyDeviceToHost),"read stats");
        double samples=0,skipped=0,terminated=0,hits=0;for(auto s:stats){samples+=s.samples;skipped+=s.skipped;terminated+=s.terminated;hits+=s.hit;}
        f<<step<<','<<skip<<','<<o.termination<<",0,"<<(times[19]+times[20])*.5f<<','<<times.front()<<','<<times.back()<<','<<error.rmse<<','<<error.max<<','<<samples/b.count<<','<<skipped/b.count<<','<<terminated/b.count<<','<<hits/b.count<<'\n';
    }
    cudaEventDestroy(start);cudaEventDestroy(stop);
    cudaDeviceProp prop{};Check(cudaGetDeviceProperties(&prop,0),"device properties");
    int driver=0,runtime=0;cudaDriverGetVersion(&driver);cudaRuntimeGetVersion(&runtime);
    std::ofstream meta(root/"g3/metadata.json");meta<<"{\n  \"device\": \""<<prop.name<<"\",\n  \"compute_capability\": \""<<prop.major<<'.'<<prop.minor
        <<"\",\n  \"driver_api_version\": "<<driver<<",\n  \"runtime_version\": "<<runtime<<",\n  \"resolution\": [640, 360],\n  \"vertical_fov_degrees\": 50,\n  \"camera\": [0,0,-3],\n  \"field_effective_bytes\": "<<volume.StorageBytes()
        <<",\n  \"warmup_frames\": 8,\n  \"measured_frames_per_variant\": 40,\n  \"reference_step\": 0.0009765625,\n  \"reference_termination\": 0,\n  \"error_channels\": \"linear premultiplied RGBA\",\n  \"timing\": \"CUDA events, render only; no readback/statistics; independent of Nsight replay\"\n}\n";
    std::cout<<"G3 six quality/performance variants recorded\n";
}
int main(int argc,char** argv) {
    try {
        fs::path root=argc>1?argv[1]:"results";const std::string mode=argc>2?argv[2]:"all";
        auto field=MakeSphereField(128);Volume volume(field);
        if(mode=="profile") G3(root,volume,true);
        else {G1(root);G2(root,volume,field);if(mode!="quick")G3(root,volume,false);}
        return 0;
    }catch(const std::exception& e){std::cerr<<"FAIL: "<<e.what()<<'\n';return 1;}
}
