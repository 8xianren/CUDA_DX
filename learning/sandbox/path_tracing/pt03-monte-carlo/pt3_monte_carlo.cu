// PT.3 蒙特卡洛积分、随机变量与 PDF 的 CPU 验收。
//
// 本节仍然没有 BRDF、没有路径、没有 CUDA kernel。目标是把 PT.1 已经用
// 黎曼和证明过的积分，改写成随机估计，并证明四件事：
//
//   1. 估计量 F = f(X)/p(X) 无偏：E[F] = ∫ f(x) dx
//   2. PDF 必须和采样方式配套；积分为 1；单位是 1/测度
//   3. 方差随 1/N 降，误差按 1/sqrt(N) 收敛；“随机”不是“随便取点”
//   4. 同一种子逐样本可复现；换种子结果不同但均值仍围着解析值
//
// 对照积分（都有闭式答案）：
//
//   ∫_0^1 x^2 dx              = 1/3
//   ∫_H cosθ dω               = π     （PT.1 投影立体角）
//
// 用 nvcc 编译只是为了走 learning/sandbox/build.ps1。

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr double kTwoPi = 2.0 * kPi;
constexpr double kOneThird = 1.0 / 3.0;

// ---------------------------------------------------------------------------
// PCG32：可复现、无全局状态的 32 位 RNG。
//
// 不用 rand()/srand()：全局种子、跨平台序列不同、多线程会打架。
// 不用 std::mt19937 当本节主 RNG：接口对，但引擎/GPU 路径追踪常用
// 的是“每像素一个计数器 + 哈希/序列”，PCG 的 state/inc 更接近那种模型。
//
// 论文：Melissa O'Neill, PCG: A Family of Simple Fast Space-Efficient
// Statistically Good Algorithms for Random Number Generation, 2014.
// 参考实现：https://www.pcg-random.org/download.html
//
// 状态：
//   state  64 位内部计数，每次乘-加前进
//   inc    64 位流选择器，必须为奇数；不同 inc 是不同的独立序列
//
// 所有权：调用方持有 Rng。没有进程级全局种子。
// 失败路径：没有。这是纯整数运算。种子为 0 也合法。
// ---------------------------------------------------------------------------
struct Rng {
  uint64_t state;
  uint64_t inc;
};

static uint32_t pcg32(Rng* rng) {
  const uint64_t old = rng->state;
  rng->state = old * 6364136223846793005ULL + (rng->inc | 1ULL);
  const uint32_t xorshifted = static_cast<uint32_t>(((old >> 18U) ^ old) >> 27U);
  const uint32_t rot = static_cast<uint32_t>(old >> 59U);
  return (xorshifted >> rot) | (xorshifted << ((static_cast<uint32_t>(-static_cast<int32_t>(rot))) & 31U));
}

// initstate = 序列起点，initseq = 流编号。
// 两次 warmup 调用是 PCG 参考实现的约定，保证 state 被彻底搅开。
static Rng make_rng(uint64_t initstate, uint64_t initseq) {
  Rng rng;
  rng.state = 0;
  rng.inc = (initseq << 1U) | 1ULL;
  pcg32(&rng);
  rng.state += initstate;
  pcg32(&rng);
  return rng;
}

// (0, 1) 开区间。用 32 位整数的中点，避开 0 和 1：
//   逆变换 x=sqrt(u)、x=u^(1/3) 在 0 处 PDF 为 0，除零；
//   log(1-u) 一类变换在 1 处爆炸。
// 单位：无量纲。这还不是 PDF，只是均匀随机变量的一次实现。
static double uniform01(Rng* rng) {
  return (static_cast<double>(pcg32(rng)) + 0.5) * (1.0 / 4294967296.0);
}

// ---------------------------------------------------------------------------
// 一维被积函数与三种 PDF。
//
//   f(x) = x^2                         定义在 [0,1]
//   I    = ∫_0^1 f(x) dx = 1/3
//
// PDF 的定义域必须盖住 f≠0 的地方，且 ∫ p = 1，单位 1/x（这里 x 无量纲）。
// 估计量：F = f(X)/p(X)。p 选得越像 |f|，Var(F) 越小。
// ---------------------------------------------------------------------------
static double f_x2(double x) { return x * x; }

static double pdf_uniform_01(double /*x*/) { return 1.0; }

// p(x)=2x，CDF=x^2，逆变换 X=sqrt(U)。比均匀更靠近 x^2 的质量。
static double pdf_linear(double x) { return 2.0 * x; }

static double sample_linear(Rng* rng) { return std::sqrt(uniform01(rng)); }

// p(x)=3x^2，恰好正比于 f。F = x^2/(3x^2)=1/3，方差精确为 0。
static double pdf_perfect(double x) { return 3.0 * x * x; }

static double sample_perfect(Rng* rng) { return std::cbrt(uniform01(rng)); }

// ---------------------------------------------------------------------------
// 半球。方向用立体角测度 dω = sinθ dθ dφ，PDF 单位 1/sr。
//
// 均匀半球：
//   p(ω) = 1/(2π)
//   采样：cosθ = U1 ∈ (0,1)，φ = 2π U2
//   因为 dω = d(cosθ) dφ，cosθ 均匀 ⇒ 立体角均匀。
//
// 余弦加权半球（PT.4 会当 Lambert 采样用，这里只当重要性采样）：
//   p(ω) = cosθ / π
//   采样：cosθ = sqrt(U1)，φ = 2π U2
//
// 被积函数 g(ω)=cosθ 时：
//   均匀     F = cosθ / (1/2π) = 2π cosθ          E[F]=π，有方差
//   余弦加权 F = cosθ / (cosθ/π) = π              每个样本都是 π
// ---------------------------------------------------------------------------
struct DirSample {
  double cos_theta;
  double pdf;  // 1/sr
};

static DirSample sample_uniform_hemisphere(Rng* rng) {
  DirSample s;
  s.cos_theta = uniform01(rng);
  (void)uniform01(rng);  // φ，本课被积函数不依赖 φ，但仍要消耗随机数保持维度配套
  s.pdf = 1.0 / kTwoPi;
  return s;
}

static DirSample sample_cosine_hemisphere(Rng* rng) {
  DirSample s;
  s.cos_theta = std::sqrt(uniform01(rng));
  (void)uniform01(rng);
  s.pdf = s.cos_theta / kPi;
  return s;
}

// ---------------------------------------------------------------------------
// Welford 在线均值/方差。单次估计量的样本方差：
//   var = Σ (F_i - mean)^2 / (N-1)
// 若样本 i.i.d.，均值的标准误差 se = sqrt(var/N)。
// 分层采样的 N 个贡献独立但不同分布，se 公式只作参考；正式比方差用多次独立重复。
// ---------------------------------------------------------------------------
struct Acc {
  int n;
  double mean;
  double m2;
};

static void acc_add(Acc* a, double x) {
  a->n += 1;
  const double d = x - a->mean;
  a->mean += d / static_cast<double>(a->n);
  a->m2 += d * (x - a->mean);
}

static double acc_variance(const Acc& a) {
  return a.n > 1 ? a.m2 / static_cast<double>(a.n - 1) : 0.0;
}

static double acc_se(const Acc& a) {
  return a.n > 0 ? std::sqrt(acc_variance(a) / static_cast<double>(a.n)) : 0.0;
}

struct RunResult {
  double mean;
  double variance;
  double se;
  double abs_err;
  double rel_err;
};

static RunResult finish_run(const Acc& a, double exact) {
  RunResult r;
  r.mean = a.mean;
  r.variance = acc_variance(a);
  r.se = acc_se(a);
  r.abs_err = std::fabs(a.mean - exact);
  r.rel_err = r.abs_err / std::fabs(exact);
  return r;
}

static void print_run(const char* name, const RunResult& r, double exact) {
  std::printf("  %-28s mean=%.10f  exact=%.10f  abs_err=%.3e  se=%.3e  var=%.3e\n",
              name, r.mean, exact, r.abs_err, r.se, r.variance);
}

static bool within_k_se(const RunResult& r, double k) {
  // 零方差估计量：每个样本都等于解析值，se=0，只看绝对误差。
  if (r.se == 0.0) {
    return r.abs_err < 1.0e-12;
  }
  return r.abs_err < k * r.se;
}

// 均匀采样 ∫ x^2 dx。p=1，F=x^2。
static RunResult mc_uniform_x2(uint64_t seed, int n) {
  Rng rng = make_rng(seed, 1);
  Acc acc = {};
  for (int i = 0; i < n; ++i) {
    const double x = uniform01(&rng);
    acc_add(&acc, f_x2(x) / pdf_uniform_01(x));
  }
  return finish_run(acc, kOneThird);
}

// 分层：把 [0,1] 切成 n 个等宽格子，每格抽 1 个点。
// 仍然无偏（每格内部是均匀，再按格子宽度加权；宽度=1/n，F 仍是 f/p 的平均）。
// 点不再扎堆，方差通常低于纯均匀。这不是“另一种积分”，只是改了 PDF 的
// 联合分布：样本之间不再独立同分布，但边际仍然盖住 [0,1]。
static RunResult mc_stratified_x2(uint64_t seed, int n) {
  Rng rng = make_rng(seed, 2);
  Acc acc = {};
  const double inv_n = 1.0 / static_cast<double>(n);
  for (int i = 0; i < n; ++i) {
    const double x = (static_cast<double>(i) + uniform01(&rng)) * inv_n;
    acc_add(&acc, f_x2(x) / pdf_uniform_01(x));
  }
  return finish_run(acc, kOneThird);
}

static RunResult mc_linear_x2(uint64_t seed, int n) {
  Rng rng = make_rng(seed, 3);
  Acc acc = {};
  for (int i = 0; i < n; ++i) {
    const double x = sample_linear(&rng);
    acc_add(&acc, f_x2(x) / pdf_linear(x));
  }
  return finish_run(acc, kOneThird);
}

static RunResult mc_perfect_x2(uint64_t seed, int n) {
  Rng rng = make_rng(seed, 4);
  Acc acc = {};
  for (int i = 0; i < n; ++i) {
    const double x = sample_perfect(&rng);
    acc_add(&acc, f_x2(x) / pdf_perfect(x));
  }
  return finish_run(acc, kOneThird);
}

static RunResult mc_uniform_cos(uint64_t seed, int n) {
  Rng rng = make_rng(seed, 5);
  Acc acc = {};
  for (int i = 0; i < n; ++i) {
    const DirSample s = sample_uniform_hemisphere(&rng);
    acc_add(&acc, s.cos_theta / s.pdf);
  }
  return finish_run(acc, kPi);
}

static RunResult mc_cosine_cos(uint64_t seed, int n) {
  Rng rng = make_rng(seed, 6);
  Acc acc = {};
  for (int i = 0; i < n; ++i) {
    const DirSample s = sample_cosine_hemisphere(&rng);
    acc_add(&acc, s.cos_theta / s.pdf);
  }
  return finish_run(acc, kPi);
}

// 故意用错：均匀半球抽方向，却把 PDF 当成 1（忘掉 1/sr）。
// E[cosθ] = ∫ cosθ * (1/2π) dω = 1/2，不是 π。这是量纲都对不上的偏差，不是噪声。
static RunResult mc_forgot_pdf_cos(uint64_t seed, int n) {
  Rng rng = make_rng(seed, 7);
  Acc acc = {};
  for (int i = 0; i < n; ++i) {
    const DirSample s = sample_uniform_hemisphere(&rng);
    acc_add(&acc, s.cos_theta);  // 没除 pdf
  }
  return finish_run(acc, kPi);
}

// 用均匀测度估计 ∫ p(x) dx 是否为 1。
static double integrate_pdf_uniform_1d(double (*pdf)(double), uint64_t seed, int n) {
  Rng rng = make_rng(seed, 8);
  Acc acc = {};
  for (int i = 0; i < n; ++i) {
    const double x = uniform01(&rng);
    acc_add(&acc, pdf(x) / 1.0);
  }
  return acc.mean;
}

// ∫_H p_cosine(ω) dω ，用均匀半球做 MIS 式的“另一种采样”：
//   p_cosine / p_uniform = (cosθ/π) / (1/2π) = 2 cosθ
// 期望为 1。这就是“PDF 数值归一化”。
static double integrate_cosine_pdf(uint64_t seed, int n) {
  Rng rng = make_rng(seed, 9);
  Acc acc = {};
  for (int i = 0; i < n; ++i) {
    const DirSample s = sample_uniform_hemisphere(&rng);
    const double p_cosine = s.cos_theta / kPi;
    acc_add(&acc, p_cosine / s.pdf);
  }
  return acc.mean;
}

// 独立重复 K 次、每次 N 样本，看估计量本身的经验方差。
static double replication_variance(RunResult (*fn)(uint64_t, int), int k, int n, uint64_t seed0) {
  Acc acc = {};
  for (int i = 0; i < k; ++i) {
    const RunResult r = fn(seed0 + static_cast<uint64_t>(i) * 17ULL, n);
    acc_add(&acc, r.mean);
  }
  return acc_variance(acc);
}

}  // namespace

int main() {
  std::printf("PT.3 Monte Carlo / random variables / PDF\n");
  std::printf("estimator F = f(X)/p(X)    E[F] = ∫ f\n");
  std::printf("RNG = PCG32, u = (u32+0.5)/2^32 ∈ (0,1)\n\n");

  bool ok = true;

  // ------------------------------------------------------------------
  // 1) 同一种子逐样本可复现；不同种子必须分叉。
  // ------------------------------------------------------------------
  std::printf("1) reproducible RNG\n");
  constexpr int kReplay = 16;
  uint32_t first[kReplay];
  {
    Rng a = make_rng(42, 54);
    for (int i = 0; i < kReplay; ++i) {
      first[i] = pcg32(&a);
    }
  }
  {
    Rng b = make_rng(42, 54);
    for (int i = 0; i < kReplay; ++i) {
      const uint32_t v = pcg32(&b);
      if (v != first[i]) {
        std::printf("  FAIL replay mismatch at i=%d\n", i);
        ok = false;
      }
    }
  }
  int differ = 0;
  {
    Rng c = make_rng(43, 54);
    for (int i = 0; i < kReplay; ++i) {
      if (pcg32(&c) != first[i]) {
        ++differ;
      }
    }
  }
  std::printf("  seed 42 replay 16 uint32: %s\n", ok ? "identical" : "BROKEN");
  std::printf("  seed 43 vs 42: %d/%d values differ\n", differ, kReplay);
  if (differ < kReplay / 2) {
    std::printf("  FAIL different seeds too similar\n");
    ok = false;
  }

  std::printf("  first 8 u32 of seed(42,54):");
  for (int i = 0; i < 8; ++i) {
    std::printf(" %08x", first[i]);
  }
  std::printf("\n");

  // ------------------------------------------------------------------
  // 2) 一维 ∫ x^2 dx = 1/3：均匀 / 分层 / 线性重要性 / 完美重要性。
  // ------------------------------------------------------------------
  std::printf("\n2) 1D  ∫_0^1 x^2 dx = 1/3\n");
  const int ns[] = {256, 1024, 4096, 16384};
  RunResult uniform_runs[4];
  for (int i = 0; i < 4; ++i) {
    char name[64];
    std::snprintf(name, sizeof(name), "uniform N=%d", ns[i]);
    uniform_runs[i] = mc_uniform_x2(2026, ns[i]);
    print_run(name, uniform_runs[i], kOneThird);
    if (!within_k_se(uniform_runs[i], 5.0)) {
      std::printf("  FAIL %s outside 5 se\n", name);
      ok = false;
    }
  }

  // i.i.d. 时 se ∝ 1/sqrt(N)。N 放大 64 倍（256→16384），se 应约 1/8。
  const double se_ratio = uniform_runs[3].se / uniform_runs[0].se;
  const double se_expected = std::sqrt(256.0 / 16384.0);  // 0.125
  std::printf("  se(16384)/se(256)=%.4f  expected=%.4f  (1/sqrt(N))\n", se_ratio, se_expected);
  if (se_ratio < 0.08 || se_ratio > 0.20) {
    std::printf("  FAIL se did not scale like 1/sqrt(N)\n");
    ok = false;
  }

  const RunResult strat = mc_stratified_x2(2026, 4096);
  const RunResult linear = mc_linear_x2(2026, 4096);
  const RunResult perfect = mc_perfect_x2(2026, 64);
  print_run("stratified N=4096", strat, kOneThird);
  print_run("importance p=2x N=4096", linear, kOneThird);
  print_run("perfect p=3x^2 N=64", perfect, kOneThird);
  if (!within_k_se(strat, 5.0) || !within_k_se(linear, 5.0) || !within_k_se(perfect, 5.0)) {
    std::printf("  FAIL stratified/importance/perfect mean\n");
    ok = false;
  }
  if (perfect.variance > 1.0e-24) {
    std::printf("  FAIL perfect estimator is not zero-variance\n");
    ok = false;
  }

  constexpr int kRep = 48;
  constexpr int kRepN = 256;
  const double var_u = replication_variance(mc_uniform_x2, kRep, kRepN, 1000);
  const double var_s = replication_variance(mc_stratified_x2, kRep, kRepN, 2000);
  const double var_l = replication_variance(mc_linear_x2, kRep, kRepN, 3000);
  std::printf("  replication K=%d N=%d  var uniform=%.3e  stratified=%.3e  p=2x=%.3e\n",
              kRep, kRepN, var_u, var_s, var_l);
  if (!(var_s < var_u)) {
    std::printf("  FAIL stratified variance should beat crude MC\n");
    ok = false;
  }
  if (!(var_l < var_u)) {
    std::printf("  FAIL p=2x variance should beat uniform\n");
    ok = false;
  }

  // ------------------------------------------------------------------
  // 3) 多组种子：均值围着 1/3，序列互不相同。
  // ------------------------------------------------------------------
  std::printf("\n3) multiple seeds, N=4096 uniform\n");
  double seed_means[5];
  const uint64_t seeds[] = {1, 2, 3, 7, 99};
  for (int i = 0; i < 5; ++i) {
    const RunResult r = mc_uniform_x2(seeds[i], 4096);
    seed_means[i] = r.mean;
    char name[32];
    std::snprintf(name, sizeof(name), "seed %llu", static_cast<unsigned long long>(seeds[i]));
    print_run(name, r, kOneThird);
    if (!within_k_se(r, 5.0)) {
      std::printf("  FAIL seed %llu outside 5 se\n", static_cast<unsigned long long>(seeds[i]));
      ok = false;
    }
  }
  int unique_pairs = 0;
  for (int i = 0; i < 5; ++i) {
    for (int j = i + 1; j < 5; ++j) {
      if (seed_means[i] != seed_means[j]) {
        ++unique_pairs;
      }
    }
  }
  std::printf("  distinct means: %d/10 pairs\n", unique_pairs);
  if (unique_pairs < 10) {
    std::printf("  FAIL different seeds produced identical means\n");
    ok = false;
  }

  // ------------------------------------------------------------------
  // 4) 半球 ∫ cosθ dω = π。接 PT.1 的解析值。
  // ------------------------------------------------------------------
  std::printf("\n4) hemisphere  ∫ cosθ dω = π\n");
  const RunResult uni_h = mc_uniform_cos(11, 16384);
  const RunResult cos_h = mc_cosine_cos(11, 64);
  const RunResult bad_h = mc_forgot_pdf_cos(11, 16384);
  print_run("uniform hemi N=16384", uni_h, kPi);
  print_run("cosine hemi N=64", cos_h, kPi);
  print_run("FORGOT pdf, avg cosθ", bad_h, kPi);
  std::printf("  forgot-pdf converges to 0.5, not π  (got mean=%.6f)\n", bad_h.mean);
  if (!within_k_se(uni_h, 5.0)) {
    std::printf("  FAIL uniform hemisphere\n");
    ok = false;
  }
  if (cos_h.variance > 1.0e-24 || cos_h.abs_err > 1.0e-12) {
    std::printf("  FAIL cosine-weighted estimator is not identically π\n");
    ok = false;
  }
  if (std::fabs(bad_h.mean - 0.5) > 0.05 || bad_h.rel_err < 0.5) {
    std::printf("  FAIL forgotten pdf should be biased toward 0.5, far from π\n");
    ok = false;
  }

  // ------------------------------------------------------------------
  // 5) PDF 数值归一化。
  // ------------------------------------------------------------------
  std::printf("\n5) PDF integrates to 1\n");
  const double z_u = integrate_pdf_uniform_1d(pdf_uniform_01, 13, 65536);
  const double z_l = integrate_pdf_uniform_1d(pdf_linear, 13, 65536);
  const double z_p = integrate_pdf_uniform_1d(pdf_perfect, 13, 65536);
  const double z_c = integrate_cosine_pdf(13, 65536);
  std::printf("  ∫_0^1 1 dx          = %.8f\n", z_u);
  std::printf("  ∫_0^1 2x dx         = %.8f\n", z_l);
  std::printf("  ∫_0^1 3x^2 dx       = %.8f\n", z_p);
  std::printf("  ∫_H (cosθ/π) dω     = %.8f\n", z_c);
  auto near1 = [](double z) { return std::fabs(z - 1.0) < 0.02; };
  if (!near1(z_u) || !near1(z_l) || !near1(z_p) || !near1(z_c)) {
    std::printf("  FAIL PDF normalization\n");
    ok = false;
  }

  std::printf("\nunits:\n");
  std::printf("  1D p(x)              [1/x]   ∫ p dx = 1\n");
  std::printf("  hemisphere p(ω)      [1/sr]  ∫ p dω = 1\n");
  std::printf("  F = f/p              same unit as ∫ f\n");
  std::printf("  forgetting p breaks both the number and the unit\n");

  if (!ok) {
    std::printf("\nPT.3 Monte Carlo: FAIL\n");
    return EXIT_FAILURE;
  }
  std::printf("\nPT.3 Monte Carlo: PASS\n");
  return EXIT_SUCCESS;
}
