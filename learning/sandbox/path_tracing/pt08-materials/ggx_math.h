#pragma once
#include <algorithm>
#include <cmath>

// PT.8各向同性GGX单次微表面反射的CPU double参考。
// 坐标约定：宏观法线n=(0,0,1)，wo和wi都从表面指向外部，区别于射线传播方向d。
// 它是局部坐标算法，不持有资源、不触发GPU调用，也不实现纹理、透射或微表面多次散射。
namespace ggx {
constexpr double Pi=3.14159265358979323846;
constexpr double DeltaAlpha=1e-4; // 应用选择：alpha<=此值按delta镜面处理，明确改变这一极窄范围的模型。
struct V {double x=0,y=0,z=0;};
inline V operator+(V a,V b){return {a.x+b.x,a.y+b.y,a.z+b.z};}
inline V operator-(V a,V b){return {a.x-b.x,a.y-b.y,a.z-b.z};}
inline V operator*(V a,double b){return {a.x*b,a.y*b,a.z*b};}
inline double Dot(V a,V b){return a.x*b.x+a.y*b.y+a.z*b.z;}
inline V Cross(V a,V b){return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
inline V Normalize(V a){return a*(1/std::sqrt(Dot(a,a)));}
inline bool Finite(V a){return std::isfinite(a.x)&&std::isfinite(a.y)&&std::isfinite(a.z);}
inline bool Unit(V a){return Finite(a)&&std::abs(Dot(a,a)-1)<1e-8;}
struct Material {double roughness;V F0;};
inline bool Valid(Material p){return std::isfinite(p.roughness)&&p.roughness>=0&&p.roughness<=1&&Finite(p.F0)&&
    p.F0.x>=0&&p.F0.x<=1&&p.F0.y>=0&&p.F0.y<=1&&p.F0.z>=0&&p.F0.z<=1;}
inline double Alpha(Material p){return p.roughness*p.roughness;}
inline bool Delta(Material p){return Alpha(p)<=DeltaAlpha;}
inline V Schlick(V F0,double cosine){double t=1-std::clamp(cosine,0.,1.);double t5=t*t*t*t*t;
    return F0+(V{1,1,1}-F0)*t5;}
inline double D(V m,double alpha){
    if(m.z<=0||alpha<=0)return 0;
    // 等价于alpha²/[pi*(1+(alpha²-1)*m.z²)²]，但此写法避免光滑极限1-m.z²相消。
    double a2=alpha*alpha,den=m.x*m.x+m.y*m.y+a2*m.z*m.z;
    return a2/(Pi*den*den);
}
inline double Lambda(V v,double alpha){
    if(v.z<=0)return INFINITY;
    double s=alpha*alpha*(v.x*v.x+v.y*v.y)/(v.z*v.z);
    // (sqrt(1+s)-1)/2有小s相消；有理化后保持相同数学定义。
    return s/(2*(std::sqrt(1+s)+1));
}
inline double G(V wo,V wi,double alpha){
    if(wo.z<=0||wi.z<=0)return 0;
    // Smith高度相关模型：两条方向共享同一个微表面高度，不是独立G1(wo)*G1(wi)。
    return 1/(1+Lambda(wo,alpha)+Lambda(wi,alpha));
}
struct Evaluation {V f{};double pdf=0;bool valid=false;};
inline Evaluation Eval(Material material,V wo,V wi){
    Evaluation e;
    if(!Valid(material)||!Unit(wo)||!Unit(wi))return e;
    e.valid=true;
    // delta在连续方向测度下没有有限BRDF/PDF；返回0，离散分支由Sample单独返回权重。
    if(Delta(material)||wo.z<=0||wi.z<=0)return e;
    V h=Normalize(wo+wi);double oh=Dot(wo,h),alpha=Alpha(material),ndf=D(h,alpha);
    e.f=Schlick(material.F0,oh)*(ndf*G(wo,wi,alpha)/(4*wo.z*wi.z));
    // 先采样p_m=D(m)*m.z，再通过反射方向的立体角Jacobian 4|wo·m|变换。
    e.pdf=ndf*h.z/(4*oh);
    return e;
}
inline V NormalFromNdf(double alpha,double u,double v){
    // GGX二维斜率径向CDF：u=r²/(alpha²+r²)，故r=alpha*sqrt(u/(1-u))。
    // 方位角均匀；输入调用者保证0<=u,v<1，不能把u==1钳成任意方向。
    double radius=alpha*std::sqrt(u/(1-u)),phi=2*Pi*v;
    double z=1/std::sqrt(1+radius*radius);
    return {radius*std::cos(phi)*z,radius*std::sin(phi)*z,z};
}
struct Sample {
    V wi{},weight{};double pdf=0,mass=0;
    // event: 0非法输入；1合法null样本（贡献0）；2连续GGX反射；3离散镜面。
    unsigned event=0;
};
inline Sample Draw(Material material,V wo,double u,double v){
    Sample s;
    if(!Valid(material)||!Unit(wo)||wo.z<=0||!std::isfinite(u)||!std::isfinite(v)||u<0||u>=1||v<0||v>=1)return s;
    if(Delta(material)){
        s.wi={-wo.x,-wo.y,wo.z};s.weight=Schlick(material.F0,wo.z);s.mass=1;s.event=3;return s;
    }
    V m=NormalFromNdf(Alpha(material),u,v);double om=Dot(wo,m);s.event=1;
    // NDF采样会选到从wo看不见的微面，或反射到宏观表面下方。
    // 这些是合法零样本，必须保留在样本总数中；不能循环重抽直到wi.z>0再沿用原PDF。
    if(om<=0)return s;
    s.wi=m*(2*om)-wo;if(s.wi.z<=0)return s;
    auto e=Eval(material,wo,s.wi);s.pdf=e.pdf;s.weight=e.f*(s.wi.z/e.pdf);s.event=2;return s;
}
}
