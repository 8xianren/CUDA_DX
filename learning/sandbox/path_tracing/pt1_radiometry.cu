// PT.1 辐射度量学、立体角与渲染方程的 CPU 数值验收。
//
// 本节不画图、不求交、不采样路径。目标只有一件事：用双精度黎曼和证明
// 渲染方程里每一项的单位能够闭合，并且三个解析积分成立：
//
//   1. 上半球立体角            ∫_H dω            = 2π
//   2. 上半球投影立体角        ∫_H cosθ dω       = π
//   3. Lambert + 均匀入射辐亮度 Lo = ∫ (ρ/π) Li cosθ dω = ρ Li
//
// 用 nvcc 编译只是为了走 learning/sandbox/build.ps1；本文件没有任何
// CUDA kernel。PT.2 才开始射线，PT.3 才开始蒙特卡洛。

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr double kTwoPi = 2.0 * kPi;

// 半球积分网格。θ 从法线到地平线，φ 绕法线一周。
// 格子越细，黎曼和越接近解析值；本课用固定细网格做验收，不自适应。
constexpr int kThetaBins = 2048;
constexpr int kPhiBins = 4096;

// 相对误差阈值。双精度 + 两千级网格，三个积分都应远小于 1e-6。
constexpr double kRelTol = 1.0e-6;

struct HemisphereSums {
  double solid_angle;           // ∫ dω
  double projected_solid_angle; // ∫ cosθ dω
  double forgotten_sine;        // 故意丢掉 sinθ 的错误测度，用来对照
};

static double relative_error(double estimated, double exact) {
  return std::fabs(estimated - exact) / std::fabs(exact);
}

static bool close_enough(double estimated, double exact) {
  return relative_error(estimated, exact) < kRelTol;
}

// 球面坐标下，单位方向 ω = (sinθ cosφ, sinθ sinφ, cosθ)。
// 立体角微元不是 dθ dφ，而是：
//
//     dω = sinθ dθ dφ
//
// sinθ 来自纬度圈的周长：靠近极点（θ=0，法线方向）的一圈很短，
// 靠近地平线（θ=π/2）的一圈最长。丢掉 sinθ，等于把北极附近的方向
// 算得过重。这不是“近似”，而是量错了测度。
static HemisphereSums integrate_hemisphere() {
  const double d_theta = (kPi / 2.0) / static_cast<double>(kThetaBins);
  const double d_phi = kTwoPi / static_cast<double>(kPhiBins);

  HemisphereSums sums = {};
  for (int it = 0; it < kThetaBins; ++it) {
    // 取每个 θ 格子的中点，避免端点 θ=0 处 sinθ=0 把整行权值吃掉。
    const double theta = (static_cast<double>(it) + 0.5) * d_theta;
    const double sin_theta = std::sin(theta);
    const double cos_theta = std::cos(theta);
    for (int ip = 0; ip < kPhiBins; ++ip) {
      const double d_omega = sin_theta * d_theta * d_phi;
      sums.solid_angle += d_omega;
      sums.projected_solid_angle += cos_theta * d_omega;
      sums.forgotten_sine += d_theta * d_phi;
    }
  }
  return sums;
}

// Lambert BRDF：f_r(ωi, ωo) = ρ / π ，单位 1/sr。
// ρ 是半球反射率，无量纲，能量守恒要求 0 ≤ ρ ≤ 1。
//
// 均匀入射辐亮度 Li（单位 W/(m^2 sr)）从整个上半球打过来时：
//
//     Lo(ωo) = ∫_H (ρ/π) Li cosθi dωi
//            = (ρ/π) Li ∫_H cosθi dωi
//            = (ρ/π) Li · π
//            = ρ Li
//
// 出射辐亮度与观察方向无关，这正是“理想漫反射”的定义。
// 如果有人把立体角积分写成 2π 而忘掉余弦，结果会变成 2ρ Li，能量翻倍。
static double lambert_exitant_radiance(double reflectance, double incoming_radiance,
                                       double projected_solid_angle) {
  const double brdf = reflectance / kPi;
  return brdf * incoming_radiance * projected_solid_angle;
}

static void print_check(const char* name, double estimated, double exact) {
  const double rel = relative_error(estimated, exact);
  std::printf("  %-28s estimated=%.12f  exact=%.12f  rel_err=%.3e  %s\n",
              name, estimated, exact, rel,
              close_enough(estimated, exact) ? "PASS" : "FAIL");
}

}  // namespace

int main() {
  std::printf("PT.1 radiometry / solid angle / rendering equation\n");
  std::printf("grid: theta_bins=%d  phi_bins=%d  rel_tol=%.1e\n",
              kThetaBins, kPhiBins, kRelTol);
  std::printf("dω = sinθ dθ dφ   (not dθ dφ)\n\n");

  const HemisphereSums sums = integrate_hemisphere();

  std::printf("1) hemisphere integrals\n");
  print_check("solid angle ∫ dω", sums.solid_angle, kTwoPi);
  print_check("projected  ∫ cosθ dω", sums.projected_solid_angle, kPi);
  std::printf("  %-28s estimated=%.12f  (wrong measure; not 2π)\n",
              "forgotten sinθ ∫ dθ dφ", sums.forgotten_sine);

  // 故意丢掉 sinθ 时，∫ dθ dφ = (π/2) * 2π = π^2 ≈ 9.87，既不是 2π 也不是 π。
  const bool sine_is_wrong_measure =
      !close_enough(sums.forgotten_sine, kTwoPi) &&
      !close_enough(sums.forgotten_sine, kPi);

  constexpr double kRho = 0.6;
  constexpr double kLi = 2.5;  // 均匀入射辐亮度，任意正数即可。
  const double lo_numeric =
      lambert_exitant_radiance(kRho, kLi, sums.projected_solid_angle);
  const double lo_analytic = kRho * kLi;
  const double lo_forgot_cosine =
      (kRho / kPi) * kLi * sums.solid_angle;  // 用 2π 代替 π，错误。

  std::printf("\n2) Lambert + uniform incoming radiance\n");
  std::printf("  rho=%.3f  Li=%.3f W/(m^2 sr)  analytic Lo=rho*Li=%.6f\n",
              kRho, kLi, lo_analytic);
  print_check("Lo = (rho/pi) Li ∫ cosθ dω", lo_numeric, lo_analytic);
  std::printf("  %-28s estimated=%.12f  analytic=%.12f  (2x energy; FAIL on purpose)\n",
              "forgot cosine, used ∫ dω", lo_forgot_cosine, lo_analytic);

  // 单位闭合检查：把每一项的单位乘起来，必须得到辐亮度。
  //   BRDF [1/sr] * Li [W/(m^2 sr)] * cosθ [1] * dω [sr] = W/(m^2 sr)
  std::printf("\n3) unit closure\n");
  std::printf("  Phi  flux              [W]\n");
  std::printf("  I    intensity         [W/sr]\n");
  std::printf("  E    irradiance        [W/m^2]      = ∫ L cosθ dω\n");
  std::printf("  L    radiance          [W/(m^2 sr)]\n");
  std::printf("  f_r  BRDF              [1/sr]\n");
  std::printf("  dω   solid angle       [sr]\n");
  std::printf("  rendering equation: Lo = Le + ∫ f_r Li cosθ dω\n");
  std::printf("  [W/(m^2 sr)] = [W/(m^2 sr)] + [1/sr]*[W/(m^2 sr)]*[1]*[sr]\n");

  const bool hemisphere_ok =
      close_enough(sums.solid_angle, kTwoPi) &&
      close_enough(sums.projected_solid_angle, kPi);
  const bool lambert_ok = close_enough(lo_numeric, lo_analytic);
  const bool forgot_cosine_is_wrong =
      relative_error(lo_forgot_cosine, lo_analytic) > 0.5;

  if (!hemisphere_ok || !lambert_ok || !sine_is_wrong_measure ||
      !forgot_cosine_is_wrong) {
    std::printf("\nPT.1 radiometry: FAIL\n");
    return EXIT_FAILURE;
  }

  std::printf("\nPT.1 radiometry: PASS\n");
  return EXIT_SUCCESS;
}
