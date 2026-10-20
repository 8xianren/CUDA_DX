#pragma once
#include <array>
#include <cmath>
#include <cstdint>
#include <algorithm>

// 本头文件仅供CPU验收：双精度灯面几何 + 射线与平面三角形解析可见性。
// GPU用方向PDF形式，CPU用面积几何项形式，避免只复制同一个最终权重表达式。
namespace area_reference {
constexpr unsigned Samples = 4096, Cases = 8;
constexpr double Pi = 3.14159265358979323846;
struct V3 { double x,y,z; };
struct Result { double value, visible, pdf, cos_light; };
// DWORD整数哈希与HLSL完全一致。跨case复用相同样本，减少成对实验的随机差异。
inline uint32_t hash_u32(uint32_t x) {
    x ^= x >> 16; x *= 0x7feb352dU;
    x ^= x >> 15; x *= 0x846ca68bU;
    x ^= x >> 16; return x;
}
inline double uniform_dimension(unsigned sample,unsigned dimension) {
    return (double(hash_u32((2*sample+dimension)^0x9e3779b9U)>>16)+0.5)/65536.0;
}
// 解析遮挡：光线从(0,0,.0001)指向q，挡板位于z=zb，三角形顶点
// (0,s),(-s,-s),(s,-s)。平面交点的二维条件：y>=-s，y<=s-2|x|。
// 与GPU使用相同偏移和有限距离区间，但不调用DXR，也不构造BVH。
inline bool visible(unsigned test,V3 q) {
    double zb=0,scale=0;
    if(test==1) { zb=1.5; scale=.35; }
    else if(test==3) { zb=4; scale=4; }
    else if(test==7) { zb=1.5; scale=2; }
    else return true;
    const double dz=q.z-.0001;
    const double length=std::sqrt(q.x*q.x+q.y*q.y+dz*dz);
    const double fraction=(zb-.0001)/dz;
    const double t=fraction*length;
    if(t<.001 || t>length-.001) return true;
    const double px=fraction*q.x, py=fraction*q.y;
    return !(py>=-scale && py<=scale-2*std::fabs(px));
}
// a,b是[0,1]²中的位置参数，不是世界坐标；调用者负责提供有效输入。
// 无动态资源、无全局RNG状态，按值返回；背面返回零，与单面发光约定一致。
inline Result evaluate(unsigned test,double a,double b) {
    const double h=test==4?.5:1, height=test==5?6:3, area=4*h*h;
    const double su=(2*a-1)*h,sv=(2*b-1)*h;
    V3 v{0,-1,0}; if(test==2)v={0,1,0}; if(test==6)v={0,-.8,.6};
    const V3 q{su,sv*v.y,height+sv*v.z};
    // u=(1,0,0)，cross(u,v)=(0,-v.z,v.y)，长度为1。
    const double d2=q.x*q.x+q.y*q.y+q.z*q.z, d=std::sqrt(d2);
    const double cs=std::max(0.0,q.z/d);
    const double cl=std::max(0.0,(v.z*q.y-v.y*q.z)/d);
    if(cs<=0 || cl<=0)return {0,0,0,0};
    const double vis=visible(test,q)?1:0;
    return {vis*5*(.7/Pi)*cs*cl*area/d2,vis,d2/(area*cl),cl};
}
// 高分辨率面积中点积分作为随机样本均值的独立数值参考；不是解析真值。
// 比较512与1024两种网格，记录可见性不连续引起的求积误差估计。
inline double grid(unsigned test,unsigned resolution) {
    double sum=0;
    for(unsigned y=0;y<resolution;++y)for(unsigned x=0;x<resolution;++x)
        sum+=evaluate(test,(x+.5)/resolution,(y+.5)/resolution).value;
    return sum/(double(resolution)*resolution);
}
// Shader输出float4与CPU结构明确保持16B stride；禁用uint量化，直接看浮点误差。
struct GpuResult { float value,visible,pdf,cos_light; };
static_assert(sizeof(GpuResult)==16,"HLSL float4 stride must be 16 bytes");
inline bool verify(const GpuResult* data) {
    const char* names[]={"free","partial blocker","back-facing","behind light","smaller light","farther light","tilted light","fully blocked"};
    bool pass=true; std::array<double,Cases> means{};
    for(unsigned test=0;test<Cases;++test) {
        double cpu=0,gpu=0,m2=0,mean=0,maxError=0,maxPdfRel=0,maxCosError=0;
        unsigned mismatches=0,visibleCount=0,invalid=0;
        for(unsigned s=0;s<Samples;++s) {
            const auto ref=evaluate(test,uniform_dimension(s,0),uniform_dimension(s,1));
            const auto& actual=data[test*Samples+s];
            if(!std::isfinite(actual.value)||!std::isfinite(actual.visible)||
               !std::isfinite(actual.pdf)||!std::isfinite(actual.cos_light)||actual.value<0)++invalid;
            cpu+=ref.value; gpu+=actual.value;
            const double delta=ref.value-mean; mean+=delta/(s+1); m2+=delta*(ref.value-mean);
            maxError=std::max(maxError,std::fabs(actual.value-ref.value));
            maxPdfRel=std::max(maxPdfRel,std::fabs(actual.pdf-ref.pdf)/std::max(1.0,ref.pdf));
            maxCosError=std::max(maxCosError,std::fabs(actual.cos_light-ref.cos_light));
            if(actual.visible!=float(ref.visible))++mismatches;
            if(actual.visible==1)++visibleCount;
        }
        cpu/=Samples; gpu/=Samples; means[test]=gpu;
        const double coarse=grid(test,512), fine=grid(test,1024);
        const double se=std::sqrt(m2/(Samples-1)/Samples);
        // SE以理想独立样本模型作为诊断尺度，不宣称固定哈希序列的统计置信证明。
        const double tolerance=5*se+2*std::fabs(fine-coarse)+1e-5;
        const bool ok=invalid==0 && mismatches==0 && maxError<3e-5 && maxPdfRel<3e-5 &&
                      maxCosError<3e-5 && std::fabs(gpu-fine)<tolerance;
        pass &= ok;
        std::printf("case[%u] %-16s GPU=%.9f CPU_same=%.9f grid1024=%.9f grid_delta=%.2g SE=%.2g visible=%u/%u\n",
          test,names[test],gpu,cpu,fine,std::fabs(fine-coarse),se,visibleCount,Samples);
        std::printf("  max_value_err=%.3g max_pdf_rel=%.3g max_cos_err=%.3g visibility_mismatch=%u invalid=%u %s\n",
          maxError,maxPdfRel,maxCosError,mismatches,invalid,ok?"PASS":"FAIL");
    }
    const bool relations=means[1]>0 && means[1]<means[0] && means[2]==0 && means[7]==0 &&
      std::fabs(means[3]-means[0])<1e-6 && means[4]>0 && means[4]<means[0] && means[5]>0 && means[5]<means[0];
    std::printf("Cross-case energy/orientation/finite-shadow checks: %s\n",relations?"PASS":"FAIL");
    return pass && relations;
}
} // namespace area_reference
