// PT.5：直接光照、阴影射线与 NEE 的 CPU 参考验收。
// 重点：面积光源的 p_A -> p_omega Jacobian、有限长度 shadow ray、Lambert direct estimator。
// 不做多次反弹、不做 BSDF sampling/MIS；这些分别留到 PT.6/PT.7。
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>

namespace {
constexpr double kPi = 3.14159265358979323846;
constexpr double kEps = 1.0e-5;
struct Vec3 { double x,y,z; };
Vec3 operator+(Vec3 a,Vec3 b){return {a.x+b.x,a.y+b.y,a.z+b.z};}
Vec3 operator-(Vec3 a,Vec3 b){return {a.x-b.x,a.y-b.y,a.z-b.z};}
Vec3 operator-(Vec3 a){return {-a.x,-a.y,-a.z};}
Vec3 operator*(Vec3 a,double s){return {a.x*s,a.y*s,a.z*s};}
Vec3 operator/(Vec3 a,double s){return a*(1.0/s);}
double dot(Vec3 a,Vec3 b){return a.x*b.x+a.y*b.y+a.z*b.z;}
Vec3 cross(Vec3 a,Vec3 b){return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
double length2(Vec3 a){return dot(a,a);}
double length(Vec3 a){return std::sqrt(length2(a));}
Vec3 normalize(Vec3 a){return a/length(a);}
double pos(double x){return std::max(0.0,x);}

// PCG32：本节继续使用工程层 RNG。每个完整 run 拥有自己的 state/inc。
struct Rng { uint64_t state,inc; };
uint32_t next_u32(Rng* r){
  uint64_t old=r->state;
  r->state=old*6364136223846793005ULL+r->inc;
  uint32_t x=static_cast<uint32_t>(((old>>18U)^old)>>27U);
  uint32_t rot=static_cast<uint32_t>(old>>59U);
  return (x>>rot)|(x<<((-rot)&31U));
}
Rng make_rng(uint64_t seed,uint64_t stream){
  Rng r{0,(stream<<1U)|1ULL}; next_u32(&r); r.state+=seed; next_u32(&r); return r;
}
double uniform01(Rng* r){return (static_cast<double>(next_u32(r))+.5)/4294967296.0;}

struct Ray { Vec3 o,d; double tmin,tmax; };
Ray make_ray(Vec3 o,Vec3 d,double tmin,double tmax){return {o,normalize(d),tmin,tmax};}
struct Sphere { Vec3 c; double r; };
bool hit_sphere(const Ray& ray,const Sphere& s,double* out_t){
  Vec3 oc=ray.o-s.c; double b=dot(ray.d,oc), c=dot(oc,oc)-s.r*s.r;
  double disc=b*b-c; if(disc<0) return false;
  double q=std::sqrt(disc); double t=-b-q;
  if(t<ray.tmin||t>ray.tmax){t=-b+q; if(t<ray.tmin||t>ray.tmax)return false;}
  *out_t=t; return true;
}

// one-sided 矩形发光体。u/v 是单位轴，hu/hv 是半边长，面积=4hu hv。
struct RectLight { Vec3 center,u,v; double hu,hv,Le; };
Vec3 light_normal(const RectLight& l){return normalize(cross(l.u,l.v));}
double light_area(const RectLight& l){return 4.0*l.hu*l.hv;}
struct LightSample { Vec3 q, wi; double dist, dist2, cos_surface, cos_light; double pdf_A,pdf_omega; };

// 从面积域均匀抽点：ξu,ξv -> q。返回 p_A=1/A 与相对 dω 的 p_ω。
// dω = cos_light / dist² dA，因此 p_ω = p_A * dist² / cos_light。
// 若光源背对着 shading point，方向域 PDF 不可用，本样本直接贡献 0。
LightSample sample_rect(const RectLight& l,Vec3 x,Vec3 n,Rng* rng){
  double su=(2*uniform01(rng)-1)*l.hu;
  double sv=(2*uniform01(rng)-1)*l.hv;
  Vec3 q=l.center+l.u*su+l.v*sv;
  Vec3 d=q-x; double d2=length2(d), dist=std::sqrt(d2), inv=1.0/dist;
  Vec3 wi=d*inv; Vec3 nl=light_normal(l);
  double cs=pos(dot(n,wi));
  double cl=pos(dot(nl,-wi));
  double pa=1.0/light_area(l);
  double po=(cl>0)?pa*d2/cl:0.0;
  return {q,wi,dist,d2,cs,cl,pa,po};
}

// 有限长度阴影射线：从偏移后的 x 发向 q，只允许 0<t<dist。
// tmax=dist-eps 的关键是：光源本身不应被当作遮挡物；场景物体在端点前才遮挡。
bool visible(Vec3 x,Vec3 n,Vec3 q,const Sphere* blocker){
  Vec3 d=q-x; double dist=length(d); if(!(dist>2*kEps)) return false;
  Vec3 origin=x+n*kEps;
  Ray shadow=make_ray(origin,q-origin,kEps,dist-kEps);
  if(!blocker)return true;
  double t=0; return !hit_sphere(shadow,*blocker,&t);
}

// NEE 面积采样估计：Le * fr * cos_surface * V / p_omega。
// 等价写法是 Le * fr * cos_surface * cos_light * A / dist² * V。
// 这里只允许 Lambert，fr=rho/pi；Li=Le 只在可见发光面上成立。
double nee_area(const RectLight& l,Vec3 x,Vec3 n,double rho,Rng* rng,const Sphere* blocker){
  LightSample s=sample_rect(l,x,n,rng);
  if(!(s.cos_surface>0&&s.cos_light>0&&s.pdf_omega>0))return 0;
  if(!visible(x,n,s.q,blocker))return 0;
  return l.Le*(rho/kPi)*s.cos_surface/s.pdf_omega;
}

// 点光源是 delta 光源：没有普通的有限 p_omega，不能拿面积光公式硬套。
// intensity 的单位是 W/sr；Li 的点极限等价带来 I/dist² 的 irradiance 因子。
double direct_point(Vec3 x,Vec3 n,double rho,Vec3 light_pos,double intensity,const Sphere* blocker){
  Vec3 d=light_pos-x; double d2=length2(d), dist=std::sqrt(d2); if(!(dist>2*kEps))return 0;
  Vec3 wi=d/dist; double cs=pos(dot(n,wi)); if(cs<=0)return 0;
  if(!visible(x,n,light_pos,blocker))return 0;
  return intensity* (rho/kPi)*cs/d2;
}

struct Stats {double mean=0,m2=0;int n=0;};
void push(Stats* s,double x){++s->n;double d=x-s->mean;s->mean+=d/s->n;s->m2+=d*(x-s->mean);}
double var(Stats s){return s.n>1?s.m2/(s.n-1):0;}
int failures=0;
void check(bool ok,const char* name){std::printf("  %-58s %s\n",name,ok?"PASS":"FAIL");if(!ok)++failures;}
bool near(double a,double b,double tol){return std::fabs(a-b)<=tol;}

// 用 z/phi 中点网格直接积分矩形光源的面积表达式，作为独立 reference。
double rect_reference(const RectLight& l,Vec3 x,Vec3 n,double rho,const Sphere* blocker,int nu,int nv){
  double sum=0, A=light_area(l);
  for(int iy=0;iy<nv;++iy)for(int ix=0;ix<nu;++ix){
    double su=((ix+.5)/nu*2-1)*l.hu, sv=((iy+.5)/nv*2-1)*l.hv;
    Vec3 q=l.center+l.u*su+l.v*sv, d=q-x; double d2=length2(d), dist=std::sqrt(d2);
    Vec3 wi=d/dist,nl=light_normal(l); double cs=pos(dot(n,wi)),cl=pos(dot(nl,-wi));
    double f=0; if(cs>0&&cl>0&&visible(x,n,q,blocker)) f=l.Le*(rho/kPi)*cs*cl/d2;
    sum+=f;
  }
  return sum*A/(nu*nv);
}

Stats area_runs(RectLight l,Vec3 x,Vec3 n,double rho,const Sphere* blocker,int k,int spp){
  Stats s;
  for(int r=0;r<k;++r){Rng rng=make_rng(0x50540000ULL+r*7919,l.Le>0?17:19);double sum=0;
    for(int i=0;i<spp;++i)sum+=nee_area(l,x,n,rho,&rng,blocker);
    push(&s,sum/spp);
  } return s;
}
} // namespace

int main(){
  std::puts("PT.5 Direct lighting / shadow ray / NEE (CPU reference; PCG32)");
  Vec3 x{0,0,0}, n{0,0,1};
  RectLight light{{0,0,3},{1,0,0},{0,1,0},1,1,5}; // z=3，法线+Z；从原点看是背面，先翻 v
  light.v={0,-1,0}; // cross(u,v)=-Z，发光面朝向原点
  Vec3 nl=light_normal(light);
  check(near(length(nl),1,1e-12)&&dot(nl,{0,0,-1})>0,"rectangle area/normal and one-sided orientation");

  // 0) Jacobian：对一组实际样本验证 pA * dA = pω * dω，代入 dω=cosL/dist² dA。
  Rng jr=make_rng(42,5); bool jac=true;
  for(int i=0;i<10000;++i){LightSample s=sample_rect(light,x,n,&jr); if(s.cos_light>0)
    jac &= near(s.pdf_omega, s.pdf_A*s.dist2/s.cos_light,1e-12);}
  check(jac,"area PDF -> solid-angle PDF Jacobian");

  // 1) 点光源：解析直接光照和有限阴影射线。
  Vec3 lp{0,0,3}; double intensity=12,rho=.6;
  double point_exact=intensity*(rho/kPi)/9.0;
  check(near(direct_point(x,n,rho,lp,intensity,nullptr),point_exact,1e-12),"point light inverse-square direct term");
  Sphere blocker{{0,0,1.5},.35};
  check(direct_point(x,n,rho,lp,intensity,&blocker)==0,"point shadow ray rejects blocker");
  check(direct_point(x,n,rho,lp,intensity,nullptr)>0,"point shadow ray unoccluded");

  // 2) 面积光源无遮挡：MC NEE 与独立中点面积积分 reference 相符。
  double rho2=.7; int nu=512,nv=512;
  double ref=rect_reference(light,x,n,rho2,nullptr,nu,nv);
  Stats free=area_runs(light,x,n,rho2,nullptr,64,4096);
  std::printf("  rectangle free: reference=%.9f mean=%.9f var_runs=%.9g\n",ref,free.mean,var(free));
  check(std::fabs(free.mean-ref)<0.012,"unoccluded area-light NEE matches area reference");

  // 3) 遮挡：球体只挡住部分矩形光源，得到软阴影；reference 同样逐点做有限可见性。
  double blocked_ref=rect_reference(light,x,n,rho2,&blocker,nu,nv);
  Stats blocked=area_runs(light,x,n,rho2,&blocker,64,4096);
  std::printf("  rectangle blocked: reference=%.9f mean=%.9f var_runs=%.9g\n",blocked_ref,blocked.mean,var(blocked));
  check(blocked.mean<free.mean&&std::fabs(blocked.mean-blocked_ref)<0.018,"partial blocker produces correct soft-shadow mean");

  // 4) 单面发光反向时没有贡献；双面约定可通过换成 two-sided cl=abs(dot) 另行实现。
  RectLight back=light; back.v={0,1,0};
  Rng br=make_rng(7,7); double back_sum=0; for(int i=0;i<4096;++i)back_sum+=nee_area(back,x,n,rho2,&br,nullptr);
  check(back_sum==0,"one-sided emitter rejects back-facing samples");

  // 5) 固定辐亮度 Le 时，放大矩形会增加覆盖立体角/直接能量；不是“面积变大但亮度自动不变”。
  RectLight small=light; small.hu=.5; small.hv=.5;
  double small_ref=rect_reference(small,x,n,rho2,nullptr,512,512);
  check(ref>small_ref&&small_ref>0,"fixed-radiance area change affects direct energy");

  std::printf("PT.5 Direct lighting: %s\n",failures?"FAIL":"PASS");
  return failures?1:0;
}
