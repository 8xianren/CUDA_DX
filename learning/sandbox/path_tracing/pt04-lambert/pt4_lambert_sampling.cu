// PT.4：Lambert BRDF + 完整三维半球方向 + 世界空间切线基。
// 这是 CPU 参考验收（用 nvcc -std=c++17 编译，但没有 CUDA kernel/GPU 计时）。
// 用 PCG32 与 PT.3 保持一致。仅测试单次反射积分；不发射阴影射线、不做 NEE/MIS。
#include <cmath>
#include <cstdint>
#include <cstdio>

namespace {
constexpr double pi = 3.14159265358979323846;
struct Vec3 { double x, y, z; };
Vec3 add(Vec3 a, Vec3 b) { return {a.x+b.x, a.y+b.y, a.z+b.z}; }
Vec3 mul(Vec3 a, double s) { return {a.x*s, a.y*s, a.z*s}; }
double dot(Vec3 a, Vec3 b) { return a.x*b.x+a.y*b.y+a.z*b.z; }
Vec3 cross(Vec3 a, Vec3 b) { return {a.y*b.z-a.z*b.y, a.z*b.x-a.x*b.z, a.x*b.y-a.y*b.x}; }
Vec3 normalize(Vec3 v) { return mul(v, 1.0/std::sqrt(dot(v,v))); }

// PCG32：64-bit state + 64-bit odd increment。Rng 由调用者拥有，不使用全局状态。
// 相同 (initstate, stream, 调用顺序) 产生相同序列；不同 stream 不保证严格统计独立。
struct Rng { uint64_t state, inc; };
uint32_t next_u32(Rng* r) {
  uint64_t old = r->state;
  r->state = old * 6364136223846793005ULL + r->inc;
  uint32_t x = static_cast<uint32_t>(((old >> 18U) ^ old) >> 27U);
  uint32_t rot = static_cast<uint32_t>(old >> 59U);
  return (x >> rot) | (x << ((-rot) & 31U));
}
Rng make_rng(uint64_t seed, uint64_t stream) {
  Rng r{0, (stream << 1U) | 1ULL};
  next_u32(&r); r.state += seed; next_u32(&r);
  return r;
}
// 整数格点的中点 -> (0,1)，避开余弦 PDF 为零的 z=0。
double uniform01(Rng* r) { return (static_cast<double>(next_u32(r))+0.5)/4294967296.0; }

// 正交局部基：N=法线，T/B 是切线/副切线。选不平行的参考轴避免叉积退化。
// 单位正交基仅旋转方向，不产生立体角 Jacobian；负行列式也保持立体角大小。
struct Frame { Vec3 t, b, n; };
Frame make_frame(Vec3 normal) {
  Vec3 n = normalize(normal); // 调用者须保证法线非零且有限
  Vec3 ref = std::fabs(n.z) < 0.999 ? Vec3{0,0,1} : Vec3{0,1,0};
  Vec3 t = normalize(cross(ref,n));
  return {t, cross(n,t), n};
}
Vec3 to_world(Frame f, Vec3 local) {
  return add(add(mul(f.t,local.x), mul(f.b,local.y)),mul(f.n,local.z));
}

enum class Strategy { Uniform, Cosine };
struct Sample { Vec3 wi; double pdf_omega; }; // pdf 相对于 dω，单位 1/sr
// u1/u2 独立均匀。设 z=cosθ，dω=dz dφ（取正向的面积量）。
// 均匀：z=u1, pω=1/(2π)；余弦：z=sqrt(u1), pz=2z, pφ=1/(2π), pω=z/π。
Sample sample_local(Strategy strategy, double u1, double u2) {
  double z = strategy == Strategy::Cosine ? std::sqrt(u1) : u1;
  double phi = 2*pi*u2;
  double r = std::sqrt(1.0-z*z);
  return {{r*std::cos(phi),r*std::sin(phi),z},
          strategy == Strategy::Cosine ? z/pi : 1.0/(2*pi)};
}

// Lambert f_r = rho/π，rho 在 [0,1]；出射积分 Lo=∫Li f_r max(0,N·wi)dω。
// 对输入 Li 的一个方向样本，只计算 Li*f_r*cos/pdf；不会把 PDF 当作概率质量。
// 无效 PDF、法线背面、非有限输入都必须拒绝，避免除零/错误能量。
bool contribution(Frame f, Vec3 wi, double pdf, double rho, double li, double* out) {
  double c = dot(f.n,wi);
  if (!(pdf > 0 && std::isfinite(pdf) && c > 0 && std::isfinite(c) &&
        rho >= 0 && rho <= 1 && std::isfinite(rho) && li >= 0 && std::isfinite(li))) return false;
  *out = li * (rho/pi) * c / pdf;
  return std::isfinite(*out);
}

struct Stats { double mean=0, m2=0; int n=0; };
void push(Stats* s, double x) { ++s->n; double d=x-s->mean; s->mean+=d/s->n; s->m2+=d*(x-s->mean); }
double variance(Stats s) { return s.n>1 ? s.m2/(s.n-1) : 0; }

int failures=0;
void check(bool ok, const char* label) { std::printf("  %s: %s\n",label, ok?"PASS":"FAIL"); if(!ok) ++failures; }
bool near(double a, double b, double tol=1e-11) { return std::fabs(a-b)<=tol; }
// K 次独立 run，每次 N SPP；测量的是各 run 积分估计值的方差，不是同一 run 内单枪方差。
// Li=1+0.5cosθ 有已知解析积分：E_cos[cosθ]=2/3 -> Lo=rho*(1+1/3)。
Stats repeated(Strategy strategy, Frame frame, double rho, bool shaped_li, int k, int spp) {
  Stats runs;
  for (int rep=0; rep<k; ++rep) {
    Rng rng=make_rng(20260921ULL+static_cast<uint64_t>(rep)*7919,
                     strategy==Strategy::Cosine ? 11 : 7);
    double sum=0;
    for (int j=0; j<spp; ++j) {
      Sample s=sample_local(strategy,uniform01(&rng),uniform01(&rng));
      Vec3 world=to_world(frame,s.wi);
      double li=shaped_li ? 1+0.5*dot(frame.n,world) : 1;
      double y=0;
      if (!contribution(frame,world,s.pdf_omega,rho,li,&y)) { ++failures; return runs; }
      sum+=y;
    }
    push(&runs,sum/spp);
  }
  return runs;
}
} // namespace

int main() {
  std::puts("PT.4 Lambert / hemisphere sampling (CPU reference; PCG32)");
  const Frame f=make_frame({0.31,-0.70,0.64});
  const Frame pole=make_frame({0,0,1});
  const Frame south=make_frame({0,0,-1});
  check(near(dot(f.t,f.n),0)&&near(dot(f.b,f.n),0)&&near(dot(f.t,f.b),0)&&
        near(dot(f.t,f.t),1)&&near(dot(f.b,f.b),1),"tilted orthonormal TBN");
  check(near(dot(pole.t,pole.n),0)&&near(dot(south.b,south.n),0),"polar normals stable");
  Rng rng=make_rng(42,54), replay=make_rng(42,54);
  bool replay_ok=true, hemisphere_ok=true;
  for (int i=0;i<65536;++i) {
    double u1=uniform01(&rng), u2=uniform01(&rng);
    replay_ok &= (u1==uniform01(&replay) && u2==uniform01(&replay));
    for (Strategy st: {Strategy::Uniform,Strategy::Cosine}) {
      Sample s=sample_local(st,u1,u2);
      Vec3 w=to_world(f,s.wi);
      double c=dot(f.n,w);
      hemisphere_ok &= c>0 && near(dot(w,w),1,2e-15) &&
                       near(c,s.wi.z,2e-15) &&
                       near(s.pdf_omega,st==Strategy::Cosine?c/pi:1/(2*pi),1e-14);
    }
  }
  check(replay_ok,"PCG32 replay");
  check(hemisphere_ok,"65536 directions per sampler in tilted world hemisphere; unit length and PDF");
  // 用 z,φ 中点求积，直接验证 ∫ pω dω=1（非拿采样器自己验证自己）。
  double mass_uniform=0, mass_cosine=0;
  const int nz=2048, nphi=16;
  for (int iz=0;iz<nz;++iz) for(int ip=0;ip<nphi;++ip) {
    double z=(iz+0.5)/nz, phi=(ip+0.5)*2*pi/nphi;
    double domega=(1.0/nz)*(2*pi/nphi);
    (void)phi;
    mass_uniform+=domega/(2*pi);
    mass_cosine+=domega*z/pi;
  }
  std::printf("  integrated PDF uniform=%.12f cosine=%.12f\n",mass_uniform,mass_cosine);
  check(near(mass_uniform,1,1e-10)&&near(mass_cosine,1,1e-10),"PDF solid-angle normalization");
  double y=0;
  check(!contribution(f,f.n,0,0.7,1,&y)&&!contribution(f,mul(f.n,-1),1,0.7,1,&y),
        "reject zero PDF and below-surface direction");
  const double rho=0.7;
  Stats furnace_u=repeated(Strategy::Uniform,f,rho,false,64,256);
  Stats furnace_c=repeated(Strategy::Cosine,f,rho,false,64,256);
  std::printf("  white furnace: target=%.9f uniform mean=%.9f var_runs=%.9g cosine mean=%.9f var_runs=%.9g\n",
              rho,furnace_u.mean,variance(furnace_u),furnace_c.mean,variance(furnace_c));
  check(near(furnace_u.mean,rho,0.012)&&near(furnace_c.mean,rho,1e-12)&&
        variance(furnace_u)>1e-5&&variance(furnace_c)<1e-24,"white furnace energy + variance");
  Stats shaped_u=repeated(Strategy::Uniform,f,rho,true,64,256);
  Stats shaped_c=repeated(Strategy::Cosine,f,rho,true,64,256);
  double exact=rho*4/3;
  std::printf("  Li=1+0.5*cos: target=%.9f uniform mean=%.9f var_runs=%.9g cosine mean=%.9f var_runs=%.9g\n",
              exact,shaped_u.mean,variance(shaped_u),shaped_c.mean,variance(shaped_c));
  check(near(shaped_u.mean,exact,0.014)&&near(shaped_c.mean,exact,0.007)&&
        variance(shaped_c)<variance(shaped_u),"nonconstant Li correct mean + lower cosine variance");
  // 若余弦采样却错报 uniform PDF，白炉的期望为 rho*2 E_cos[z]=4rho/3，而非 rho。
  std::printf("  deliberate wrong-PDF white-furnace limit=%.9f (correct=%.9f)\n",4*rho/3,rho);
  std::printf("PT.4 Lambert: %s\n",failures?"FAIL":"PASS");
  return failures?1:0;
}
