#include <cuda_runtime.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <numeric>
#include <vector>

// 所有 CUDA Runtime API 都通过这个宏检查返回值。
// kernel 启动本身是异步的，所以启动后用 cudaGetLastError 检查配置错误，
// 最后再用 cudaDeviceSynchronize 暴露执行期间发生的越界等异步错误。
#define CUDA_CHECK(call)                                                        \
  do {                                                                          \
    const cudaError_t error = (call);                                            \
    if (error != cudaSuccess) {                                                  \
      std::fprintf(stderr, "%s failed: %s\n", #call,                          \
                   cudaGetErrorString(error));                                   \
      std::exit(EXIT_FAILURE);                                                   \
    }                                                                            \
  } while (0)

// 为了只观察“时间步长与碰撞响应”这一件事，实验把三维粒子简化成一维。
// 三维 AABB 碰撞只是分别对 x/y/z 三个轴应用同样的逻辑；数学本质不变。
struct Particle1D {
  float position;
  float velocity;
};

static_assert(sizeof(Particle1D) == 8,
              "Particle1D should contain exactly two floats");

// 处理点粒子与一维封闭区间 [lower_bound, upper_bound] 的离散碰撞。
//
// restitution 是恢复系数 e：
//   e = 1：完全弹性碰撞，法线方向速度大小不变；
//   e = 0：完全非弹性碰撞，法线方向速度变为 0；
//   0 < e < 1：每次碰撞损失一部分动能。
//
// 一维墙面的碰撞公式是 v_after = -e * v_before。
// 因为动能与 v^2 成正比，所以碰撞后的法向动能是碰撞前的 e^2 倍。
__device__ __forceinline__ void resolve_bounds(Particle1D& particle,
                                                float lower_bound,
                                                float upper_bound,
                                                float restitution) {
  if (particle.position < lower_bound) {
    // 位置修正：积分后已经落到边界外，先投影回合法区域。
    // 这是离散碰撞的“穿透修正”，并没有求精确碰撞时刻 TOI。
    particle.position = lower_bound;

    // 只有仍朝向下边界运动时才反弹。
    // 如果粒子已经向区间内部运动，就不应再次翻转速度，否则会产生抖动。
    if (particle.velocity < 0.0f) {
      particle.velocity = -restitution * particle.velocity;
    }
  } else if (particle.position > upper_bound) {
    particle.position = upper_bound;
    if (particle.velocity > 0.0f) {
      particle.velocity = -restitution * particle.velocity;
    }
  }
}

// 每个 CUDA 线程独立负责一个粒子。
// 本实验的粒子之间没有相互作用，因此不需要原子操作、共享内存或线程同步。
//
// substep_count 允许一次 kernel 启动执行多个固定子步。例如一帧耗时 1/40 秒，
// 固定物理步长为 1/120 秒时，该帧可以在一个 kernel 内连续执行 3 个子步。
// 这对“互不依赖的粒子 + 静态边界”是安全的，也能减少 kernel 启动次数。
// 如果粒子之间会碰撞或每个子步都要建立空间网格，则通常必须拆成多个 kernel，
// 用 kernel 边界作为全 grid 同步点，不能简单地让单个线程私自循环全部子步。
__global__ void simulate_substeps(Particle1D* particles, int particle_count,
                                  int substep_count, float dt,
                                  float lower_bound, float upper_bound,
                                  float restitution) {
  const int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index >= particle_count) {
    return;
  }

  // 只在 kernel 开始时从 global memory 读取一次，所有子步在寄存器中完成，
  // 最后再统一写回。这比每个子步都读写 global memory 更省带宽。
  Particle1D particle = particles[index];

  for (int substep = 0; substep < substep_count; ++substep) {
    // 本节暂时不加重力，只研究匀速粒子与墙面的碰撞。
    // 有重力时可先做半隐式 Euler：velocity += gravity * dt，
    // 再执行下面的位置更新与边界处理。
    particle.position += particle.velocity * dt;
    resolve_bounds(particle, lower_bound, upper_bound, restitution);
  }

  particles[index] = particle;
}

enum class StepMode {
  // 错误但常见的做法：每个渲染帧只模拟一步，并把 frame_delta 直接作为 dt。
  VariableFrameDelta,

  // 推荐做法：渲染帧时间先进入 accumulator，再兑换成固定大小的物理子步。
  FixedAccumulator,
};

struct RunResult {
  std::vector<Particle1D> particles;
  int physics_step_count = 0;
  double accumulator_remainder = 0.0;
  bool exceeded_substep_limit = false;
};

// 根据一组“渲染帧间隔”驱动 CUDA 粒子模拟。
// frame_deltas 表示真实应用中由高精度时钟测得的每帧耗时。
RunResult run_schedule(const std::vector<Particle1D>& initial_particles,
                       const std::vector<double>& frame_deltas,
                       StepMode mode, double fixed_dt, float lower_bound,
                       float upper_bound, float restitution) {
  constexpr int threads_per_block = 256;
  constexpr int max_substeps_per_frame = 8;
  constexpr double comparison_epsilon = 1.0e-12;

  const int particle_count = static_cast<int>(initial_particles.size());
  const int block_count =
      (particle_count + threads_per_block - 1) / threads_per_block;
  const std::size_t bytes = initial_particles.size() * sizeof(Particle1D);

  Particle1D* device_particles = nullptr;
  CUDA_CHECK(cudaMalloc(&device_particles, bytes));
  CUDA_CHECK(cudaMemcpy(device_particles, initial_particles.data(), bytes,
                        cudaMemcpyHostToDevice));

  RunResult result{};
  result.particles.resize(initial_particles.size());
  double accumulator = 0.0;

  for (double frame_delta : frame_deltas) {
    int substep_count = 0;
    float simulation_dt = 0.0f;

    if (mode == StepMode::VariableFrameDelta) {
      // 渲染一帧就推进一次物理，而且 dt 会随帧率抖动。
      // 两台机器即使模拟相同总时长，只要帧时间切分不同，碰撞时刻和结果
      // 就可能不同。这一路径保留在 demo 中，是为了构造反例。
      substep_count = 1;
      simulation_dt = static_cast<float>(frame_delta);
    } else {
      // accumulator 像一个“尚未消费的模拟时间余额”。
      // 每积攒 fixed_dt，就兑换成一个完全相同的物理子步。
      accumulator += frame_delta;
      while (accumulator + comparison_epsilon >= fixed_dt &&
             substep_count < max_substeps_per_frame) {
        accumulator -= fixed_dt;
        ++substep_count;
      }

      // 二进制浮点无法精确表示 1/120。容差比较可能留下极小负余数，
      // 将其归零可避免输出 -0.000000，但不会增加或删除真实物理子步。
      if (std::abs(accumulator) < comparison_epsilon) {
        accumulator = 0.0;
      }

      // 如果一帧卡顿过久，accumulator 可能需要几十个子步才能追上。
      // 限制每帧最多 8 步可避免“越追赶越卡、越卡欠步越多”的死亡螺旋。
      // 本实验的最大帧间隔只需要 3 步，因此触发限制会被视为测试失败。
      if (accumulator + comparison_epsilon >= fixed_dt) {
        result.exceeded_substep_limit = true;
      }
      simulation_dt = static_cast<float>(fixed_dt);
    }

    if (substep_count > 0) {
      simulate_substeps<<<block_count, threads_per_block>>>(
          device_particles, particle_count, substep_count, simulation_dt,
          lower_bound, upper_bound, restitution);
      CUDA_CHECK(cudaGetLastError());
      result.physics_step_count += substep_count;
    }
  }

  // 默认 stream 中的 kernel 按提交顺序执行；这里只在整个日程结束后同步一次。
  // 实际 CUDA + D3D12 程序会用 external fence 把最终结果交给图形队列，
  // 不需要在每个渲染帧或物理子步后调用 cudaDeviceSynchronize。
  CUDA_CHECK(cudaDeviceSynchronize());
  CUDA_CHECK(cudaMemcpy(result.particles.data(), device_particles, bytes,
                        cudaMemcpyDeviceToHost));
  CUDA_CHECK(cudaFree(device_particles));

  result.accumulator_remainder = accumulator;
  return result;
}

struct DifferenceStats {
  float maximum_position_difference = 0.0f;
  float maximum_velocity_difference = 0.0f;
  int bitwise_mismatch_count = 0;
};

DifferenceStats compare_results(const std::vector<Particle1D>& first,
                                const std::vector<Particle1D>& second) {
  DifferenceStats stats{};
  for (std::size_t index = 0; index < first.size(); ++index) {
    stats.maximum_position_difference = std::max(
        stats.maximum_position_difference,
        std::abs(first[index].position - second[index].position));
    stats.maximum_velocity_difference = std::max(
        stats.maximum_velocity_difference,
        std::abs(first[index].velocity - second[index].velocity));

    // bitwise 比较比 epsilon 比较更严格。固定步长的两次运行执行相同数量、
    // 相同顺序的 FP32 运算，因此本实验期望所有粒子逐位一致。
    if (std::memcmp(&first[index], &second[index], sizeof(Particle1D)) != 0) {
      ++stats.bitwise_mismatch_count;
    }
  }
  return stats;
}

// 验证碰撞响应没有把粒子留在边界外，也没有在 e <= 1 时凭空增加速度。
bool validate_physics(const std::vector<Particle1D>& initial,
                      const std::vector<Particle1D>& actual,
                      float lower_bound, float upper_bound) {
  constexpr float epsilon = 1.0e-5f;
  for (std::size_t index = 0; index < actual.size(); ++index) {
    if (actual[index].position < lower_bound - epsilon ||
        actual[index].position > upper_bound + epsilon ||
        std::abs(actual[index].velocity) >
            std::abs(initial[index].velocity) + epsilon) {
      return false;
    }
  }
  return true;
}

double total_time(const std::vector<double>& frame_deltas) {
  return std::accumulate(frame_deltas.begin(), frame_deltas.end(), 0.0);
}

int main() {
  constexpr int particle_count = 4096;
  constexpr float lower_bound = 0.0f;
  constexpr float upper_bound = 10.0f;
  constexpr float restitution = 0.8f;
  constexpr double fixed_dt = 1.0 / 120.0;

  std::vector<Particle1D> initial_particles(particle_count);
  for (int index = 0; index < particle_count; ++index) {
    // 位置均匀铺在区间内部；速度大小约为 [1, 8]，方向左右交替。
    // 最大渲染帧为 1/40 秒，所以单帧最大位移约 8/40 = 0.2，
    // 远小于区间宽度 10，不会在一个子步中连续跨越两面墙。
    const float position_fraction =
        static_cast<float>(index % 257) / 256.0f;
    const float speed_fraction =
        static_cast<float>((index * 13) % 97) / 96.0f;
    const float speed = 1.0f + 7.0f * speed_fraction;

    initial_particles[index].position =
        0.25f + position_fraction * 9.5f;
    initial_particles[index].velocity =
        (index & 1) == 0 ? speed : -speed;
  }

  // 日程 A：稳定 60 FPS，总时长 600 / 60 = 10 秒。
  std::vector<double> stable_60_fps(600, 1.0 / 60.0);

  // 日程 B：帧时间在 1/120、1/40、1/60 秒之间循环。
  // 每三个渲染帧总计 0.05 秒，循环 200 次同样是 10 秒。
  // 两个日程总时间与渲染帧数量相同，区别只有时间被怎样切分。
  std::vector<double> jittered_fps;
  jittered_fps.reserve(600);
  for (int cycle = 0; cycle < 200; ++cycle) {
    jittered_fps.push_back(1.0 / 120.0);
    jittered_fps.push_back(1.0 / 40.0);
    jittered_fps.push_back(1.0 / 60.0);
  }

  // 先运行反例：直接使用可变 frame delta。
  const RunResult variable_stable = run_schedule(
      initial_particles, stable_60_fps, StepMode::VariableFrameDelta, fixed_dt,
      lower_bound, upper_bound, restitution);
  const RunResult variable_jittered = run_schedule(
      initial_particles, jittered_fps, StepMode::VariableFrameDelta, fixed_dt,
      lower_bound, upper_bound, restitution);

  // 再运行固定步长版本：两个渲染日程都应兑换出 1200 个 1/120 秒子步。
  const RunResult fixed_stable = run_schedule(
      initial_particles, stable_60_fps, StepMode::FixedAccumulator, fixed_dt,
      lower_bound, upper_bound, restitution);
  const RunResult fixed_jittered = run_schedule(
      initial_particles, jittered_fps, StepMode::FixedAccumulator, fixed_dt,
      lower_bound, upper_bound, restitution);

  const DifferenceStats variable_difference =
      compare_results(variable_stable.particles, variable_jittered.particles);
  const DifferenceStats fixed_difference =
      compare_results(fixed_stable.particles, fixed_jittered.particles);

  // 中文字符后紧跟反斜杠时，Windows 上旧式多字节代码页可能干扰转义解析；
  // 在换行转义前放一个 ASCII 空格，可让 nvcc/MSVC 的各编译阶段稳定识别 \n。
  std::printf("边界=[%.1f, %.1f]，恢复系数 e=%.2f，固定 dt=1/120 秒 \n",
              lower_bound, upper_bound, restitution);
  std::printf("日程 A：%zu 帧，总时长=%.9f 秒；日程 B：%zu 帧，总时长=%.9f 秒 \n",
              stable_60_fps.size(), total_time(stable_60_fps),
              jittered_fps.size(), total_time(jittered_fps));
  std::printf(
      "可变 dt：物理步数=%d/%d，最大位置差=%.9f，最大速度差=%.9f, "
      "逐位不同粒子=%d\n",
      variable_stable.physics_step_count,
      variable_jittered.physics_step_count,
      variable_difference.maximum_position_difference,
      variable_difference.maximum_velocity_difference,
      variable_difference.bitwise_mismatch_count);
  std::printf(
      "固定 dt：物理步数=%d/%d，最大位置差=%.9f，最大速度差=%.9f, "
      "逐位不同粒子=%d，accumulator 余数=%.12f/%.12f\n",
      fixed_stable.physics_step_count, fixed_jittered.physics_step_count,
      fixed_difference.maximum_position_difference,
      fixed_difference.maximum_velocity_difference,
      fixed_difference.bitwise_mismatch_count,
      fixed_stable.accumulator_remainder,
      fixed_jittered.accumulator_remainder);
  std::printf(
      "样本 particle[0]：初始=(x=%.6f,v=%.6f)，可变 A/B=(%.6f,%.6f)/(%.6f,%.6f), "
      "固定 A/B=(%.6f,%.6f)/(%.6f,%.6f)\n",
      initial_particles[0].position, initial_particles[0].velocity,
      variable_stable.particles[0].position,
      variable_stable.particles[0].velocity,
      variable_jittered.particles[0].position,
      variable_jittered.particles[0].velocity,
      fixed_stable.particles[0].position,
      fixed_stable.particles[0].velocity,
      fixed_jittered.particles[0].position,
      fixed_jittered.particles[0].velocity);

  const bool all_runs_physically_valid =
      validate_physics(initial_particles, variable_stable.particles,
                       lower_bound, upper_bound) &&
      validate_physics(initial_particles, variable_jittered.particles,
                       lower_bound, upper_bound) &&
      validate_physics(initial_particles, fixed_stable.particles, lower_bound,
                       upper_bound) &&
      validate_physics(initial_particles, fixed_jittered.particles,
                       lower_bound, upper_bound);

  const bool passed =
      std::abs(total_time(stable_60_fps) - total_time(jittered_fps)) <
          1.0e-10 &&
      variable_difference.maximum_position_difference > 1.0e-3f &&
      fixed_difference.bitwise_mismatch_count == 0 &&
      fixed_stable.physics_step_count == 1200 &&
      fixed_jittered.physics_step_count == 1200 &&
      !fixed_stable.exceeded_substep_limit &&
      !fixed_jittered.exceeded_substep_limit && all_runs_physically_valid;

  std::printf("检查结果：%s\n", passed ? "PASS" : "FAIL");
  return passed ? EXIT_SUCCESS : EXIT_FAILURE;
}
