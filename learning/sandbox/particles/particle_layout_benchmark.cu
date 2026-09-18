#include <cuda_runtime.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

// CUDA kernel 启动是异步的：cudaGetLastError 负责发现启动配置错误，
// cudaEventSynchronize / cudaDeviceSynchronize 负责暴露执行期间的错误。
#define CUDA_CHECK(call)                                                        \
  do {                                                                          \
    const cudaError_t error = (call);                                            \
    if (error != cudaSuccess) {                                                  \
      std::fprintf(stderr, "%s failed: %s\n", #call,                          \
                   cudaGetErrorString(error));                                   \
      std::exit(EXIT_FAILURE);                                                   \
    }                                                                            \
  } while (0)

// AoS（Array of Structures）：数组中的每个元素都是一个完整粒子。
// 内存顺序为：
//   [P0: position | velocity | color]
//   [P1: position | velocity | color]
//   [P2: position | velocity | color] ...
//
// 这种布局非常直观，也能直接对应一个 stride=48 的 HLSL StructuredBuffer。
// 但 CUDA warp 同时读取 32 个粒子的 position 时，相邻线程地址相差 48 字节，
// 中间夹着其他字段，不能像连续 float4 数组那样充分利用内存事务。
struct ParticleAoS {
  float4 position_mass;
  float4 velocity_life;
  float4 color;
};

static_assert(sizeof(ParticleAoS) == 48,
              "ParticleAoS must match three consecutive float4 values");

// SoA（Structure of Arrays）在本实验中放进同一个连续 allocation：
//
//   [N 个 position_mass][N 个 velocity_life][N 个 color]
//
// 它仍然只需要一个 cudaMalloc；将来同样可以只创建一个 D3D12 共享 Buffer，
// CUDA 映射一次后按偏移得到三个指针。D3D12 则可以为同一个 Resource 创建
// 多个 SRV，用 FirstElement 分别指向 position 与 color 区段。
struct ParticleSoAView {
  float4* position_mass;
  float4* velocity_life;
  float4* color;
};

ParticleSoAView make_soa_view(float4* storage, int particle_count) {
  ParticleSoAView view{};
  view.position_mass = storage;
  view.velocity_life = storage + particle_count;
  view.color = storage + 2 * particle_count;
  return view;
}

// 两种布局必须从完全相同的初始数据开始，否则性能或正确性对比没有意义。
// 初始化单独放在 kernel 中，避免先在 CPU 创建数百 MB 数组再通过 PCIe 上传。
__global__ void initialize_aos(ParticleAoS* particles, int particle_count) {
  const int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index >= particle_count) {
    return;
  }

  const float i = static_cast<float>(index);
  ParticleAoS particle{};
  particle.position_mass =
      make_float4(i * 1.0e-6f, i * 2.0e-6f, -i * 1.0e-6f, 1.0f);
  particle.velocity_life = make_float4(
      1.0f + static_cast<float>(index % 7) * 0.01f,
      2.0f + static_cast<float>(index % 11) * 0.01f,
      3.0f + static_cast<float>(index % 13) * 0.01f, 10.0f);
  particle.color = make_float4(
      static_cast<float>(index % 17) / 16.0f,
      static_cast<float>(index % 23) / 22.0f, 0.75f, 1.0f);
  particles[index] = particle;
}

__global__ void initialize_soa(ParticleSoAView particles,
                               int particle_count) {
  const int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index >= particle_count) {
    return;
  }

  const float i = static_cast<float>(index);
  particles.position_mass[index] =
      make_float4(i * 1.0e-6f, i * 2.0e-6f, -i * 1.0e-6f, 1.0f);
  particles.velocity_life[index] = make_float4(
      1.0f + static_cast<float>(index % 7) * 0.01f,
      2.0f + static_cast<float>(index % 11) * 0.01f,
      3.0f + static_cast<float>(index % 13) * 0.01f, 10.0f);
  particles.color[index] = make_float4(
      static_cast<float>(index % 17) / 16.0f,
      static_cast<float>(index % 23) / 22.0f, 0.75f, 1.0f);
}

// AoS 版本故意只读取和写回 position/velocity 两个字段。
// 不使用 `ParticleAoS particle = particles[index]` 再整体写回，是为了防止编译器
// 连不变的 color 也一起搬运；否则比较的将是“多做无用工作”和 SoA，而不是
// 单纯比较两种布局在相同逻辑字节数下的访存合并效率。
__global__ void integrate_aos(ParticleAoS* particles, int particle_count,
                              float dt, float3 gravity) {
  const int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index >= particle_count) {
    return;
  }

  float4 position_mass = particles[index].position_mass;
  float4 velocity_life = particles[index].velocity_life;

  // 半隐式 Euler：先更新速度，再用新速度更新位置。
  // position_mass.w（质量）和 color 本帧不变；velocity_life.w 表示寿命。
  velocity_life.x += gravity.x * dt;
  velocity_life.y += gravity.y * dt;
  velocity_life.z += gravity.z * dt;
  velocity_life.w -= dt;

  position_mass.x += velocity_life.x * dt;
  position_mass.y += velocity_life.y * dt;
  position_mass.z += velocity_life.z * dt;

  particles[index].position_mass = position_mass;
  particles[index].velocity_life = velocity_life;
}

// SoA 版本执行与 AoS 完全相同的浮点运算，唯一变化是地址布局。
// 一个 warp 的 32 个线程读取 position_mass[index] 时会访问连续的 512 字节；
// velocity_life 同理，因此更容易形成利用率高的合并内存事务。
__global__ void integrate_soa(ParticleSoAView particles, int particle_count,
                              float dt, float3 gravity) {
  const int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index >= particle_count) {
    return;
  }

  float4 position_mass = particles.position_mass[index];
  float4 velocity_life = particles.velocity_life[index];

  velocity_life.x += gravity.x * dt;
  velocity_life.y += gravity.y * dt;
  velocity_life.z += gravity.z * dt;
  velocity_life.w -= dt;

  position_mass.x += velocity_life.x * dt;
  position_mass.y += velocity_life.y * dt;
  position_mass.z += velocity_life.z * dt;

  particles.position_mass[index] = position_mass;
  particles.velocity_life[index] = velocity_life;
}

struct LaunchConfig {
  int particle_count;
  int block_count;
  int threads_per_block;
  int measured_iterations;
  float dt;
  float3 gravity;
};

void launch_initialize_aos(ParticleAoS* particles,
                           const LaunchConfig& config) {
  initialize_aos<<<config.block_count, config.threads_per_block>>>(
      particles, config.particle_count);
  CUDA_CHECK(cudaGetLastError());
}

void launch_initialize_soa(ParticleSoAView particles,
                           const LaunchConfig& config) {
  initialize_soa<<<config.block_count, config.threads_per_block>>>(
      particles, config.particle_count);
  CUDA_CHECK(cudaGetLastError());
}

// 返回一次 AoS 基准的总毫秒数。初始化在计时区间之外：我们只测每帧积分。
float measure_aos_once(ParticleAoS* particles, const LaunchConfig& config,
                       cudaEvent_t start, cudaEvent_t stop) {
  launch_initialize_aos(particles, config);
  CUDA_CHECK(cudaDeviceSynchronize());

  CUDA_CHECK(cudaEventRecord(start));
  for (int iteration = 0; iteration < config.measured_iterations; ++iteration) {
    integrate_aos<<<config.block_count, config.threads_per_block>>>(
        particles, config.particle_count, config.dt, config.gravity);
  }
  CUDA_CHECK(cudaGetLastError());
  CUDA_CHECK(cudaEventRecord(stop));
  CUDA_CHECK(cudaEventSynchronize(stop));

  float elapsed_ms = 0.0f;
  CUDA_CHECK(cudaEventElapsedTime(&elapsed_ms, start, stop));
  return elapsed_ms;
}

float measure_soa_once(ParticleSoAView particles, const LaunchConfig& config,
                       cudaEvent_t start, cudaEvent_t stop) {
  launch_initialize_soa(particles, config);
  CUDA_CHECK(cudaDeviceSynchronize());

  CUDA_CHECK(cudaEventRecord(start));
  for (int iteration = 0; iteration < config.measured_iterations; ++iteration) {
    integrate_soa<<<config.block_count, config.threads_per_block>>>(
        particles, config.particle_count, config.dt, config.gravity);
  }
  CUDA_CHECK(cudaGetLastError());
  CUDA_CHECK(cudaEventRecord(stop));
  CUDA_CHECK(cudaEventSynchronize(stop));

  float elapsed_ms = 0.0f;
  CUDA_CHECK(cudaEventElapsedTime(&elapsed_ms, start, stop));
  return elapsed_ms;
}

float median(std::vector<float> values) {
  std::sort(values.begin(), values.end());
  return values[values.size() / 2];
}

bool float4_bitwise_equal(const float4& first, const float4& second) {
  return std::memcmp(&first, &second, sizeof(float4)) == 0;
}

int main(int argc, char** argv) {
  // compute-sanitizer 会对每次显存访问做插桩，不适合直接运行数百次大型基准。
  // `--verify-only` 使用较小数据和较少迭代，只验证地址与结果正确性；
  // 不带参数时才运行足够大的正式性能基准。
  const bool verify_only =
      argc > 1 && std::strcmp(argv[1], "--verify-only") == 0;

  // 正式模式使用 8,388,608 个粒子，让 position+velocity 工作集远大于缓存，
  // 测到的主要是显存访问而不是 L2 cache 命中。
  const int particle_count = verify_only ? (1 << 16) : (1 << 23);
  constexpr int threads_per_block = 256;
  const int measured_iterations = verify_only ? 2 : 50;
  const int measurement_rounds = verify_only ? 1 : 7;
  constexpr float dt = 1.0f / 60.0f;
  const float3 gravity = make_float3(0.0f, -9.8f, 0.0f);

  const LaunchConfig config{
      particle_count,
      (particle_count + threads_per_block - 1) / threads_per_block,
      threads_per_block,
      measured_iterations,
      dt,
      gravity,
  };

  // 两种布局都占 48*N 字节：AoS 是 N 个 48-byte struct；
  // SoA 是三个 N*16-byte 区段。这里没有通过减少总容量来让 SoA 获利。
  const std::size_t aos_bytes =
      static_cast<std::size_t>(particle_count) * sizeof(ParticleAoS);
  const std::size_t soa_bytes =
      static_cast<std::size_t>(particle_count) * 3 * sizeof(float4);

  ParticleAoS* aos_particles = nullptr;
  float4* soa_storage = nullptr;
  CUDA_CHECK(cudaMalloc(&aos_particles, aos_bytes));
  CUDA_CHECK(cudaMalloc(&soa_storage, soa_bytes));
  const ParticleSoAView soa_particles =
      make_soa_view(soa_storage, particle_count);

  cudaEvent_t start = nullptr;
  cudaEvent_t stop = nullptr;
  CUDA_CHECK(cudaEventCreate(&start));
  CUDA_CHECK(cudaEventCreate(&stop));

  // 预热 CUDA context、页表与时钟状态，避免首次启动成本污染正式结果。
  launch_initialize_aos(aos_particles, config);
  launch_initialize_soa(soa_particles, config);
  integrate_aos<<<config.block_count, config.threads_per_block>>>(
      aos_particles, particle_count, dt, gravity);
  integrate_soa<<<config.block_count, config.threads_per_block>>>(
      soa_particles, particle_count, dt, gravity);
  CUDA_CHECK(cudaGetLastError());
  CUDA_CHECK(cudaDeviceSynchronize());

  std::vector<float> aos_times;
  std::vector<float> soa_times;
  aos_times.reserve(measurement_rounds);
  soa_times.reserve(measurement_rounds);

  // 奇偶轮交换先后顺序，降低“总是后测者享受更高时钟或热缓存”的顺序偏差。
  for (int round = 0; round < measurement_rounds; ++round) {
    if ((round & 1) == 0) {
      aos_times.push_back(
          measure_aos_once(aos_particles, config, start, stop));
      soa_times.push_back(
          measure_soa_once(soa_particles, config, start, stop));
    } else {
      soa_times.push_back(
          measure_soa_once(soa_particles, config, start, stop));
      aos_times.push_back(
          measure_aos_once(aos_particles, config, start, stop));
    }
  }

  const float aos_total_ms = median(aos_times);
  const float soa_total_ms = median(soa_times);
  const float aos_per_iteration_ms =
      aos_total_ms / static_cast<float>(measured_iterations);
  const float soa_per_iteration_ms =
      soa_total_ms / static_cast<float>(measured_iterations);

  // 每步逻辑流量：position 读16+写16，velocity 读16+写16，共64字节。
  // 这里计算的是 effective bandwidth；AoS 因空洞导致的额外内存事务不计入
  // 分子，所以它会直接表现为较低的有效带宽。
  constexpr double logical_bytes_per_particle = 64.0;
  const double logical_bytes_per_iteration =
      logical_bytes_per_particle * static_cast<double>(particle_count);
  const double aos_effective_gb_per_second =
      logical_bytes_per_iteration /
      (static_cast<double>(aos_per_iteration_ms) * 1.0e-3) / 1.0e9;
  const double soa_effective_gb_per_second =
      logical_bytes_per_iteration /
      (static_cast<double>(soa_per_iteration_ms) * 1.0e-3) / 1.0e9;

  // 正确性检查抽取首、中、尾三个粒子。两种 kernel 的浮点运算顺序完全相同，
  // 因而在本机同一次编译中应逐位一致；同时检查 color 未被积分 kernel 改写。
  const int sample_indices[] = {0, particle_count / 2, particle_count - 1};
  int mismatches = 0;
  for (int index : sample_indices) {
    ParticleAoS aos_sample{};
    float4 soa_position{};
    float4 soa_velocity{};
    float4 soa_color{};
    CUDA_CHECK(cudaMemcpy(&aos_sample, aos_particles + index,
                          sizeof(ParticleAoS), cudaMemcpyDeviceToHost));
    CUDA_CHECK(cudaMemcpy(&soa_position, soa_particles.position_mass + index,
                          sizeof(float4), cudaMemcpyDeviceToHost));
    CUDA_CHECK(cudaMemcpy(&soa_velocity, soa_particles.velocity_life + index,
                          sizeof(float4), cudaMemcpyDeviceToHost));
    CUDA_CHECK(cudaMemcpy(&soa_color, soa_particles.color + index,
                          sizeof(float4), cudaMemcpyDeviceToHost));

    if (!float4_bitwise_equal(aos_sample.position_mass, soa_position) ||
        !float4_bitwise_equal(aos_sample.velocity_life, soa_velocity) ||
        !float4_bitwise_equal(aos_sample.color, soa_color)) {
      ++mismatches;
    }

    std::printf(
        "sample[%d]: position=(%.6f, %.6f, %.6f), "
        "velocity=(%.6f, %.6f, %.6f), life=%.6f\n",
        index, soa_position.x, soa_position.y, soa_position.z,
        soa_velocity.x, soa_velocity.y, soa_velocity.z, soa_velocity.w);
  }

  std::printf("particles: %d, allocation: AoS %.1f MiB, SoA %.1f MiB\n",
              particle_count, static_cast<double>(aos_bytes) / (1024.0 * 1024.0),
              static_cast<double>(soa_bytes) / (1024.0 * 1024.0));
  std::printf(
      "AoS median: %.3f ms / %d iterations = %.6f ms/step, "
      "effective bandwidth %.1f GB/s\n",
      aos_total_ms, measured_iterations, aos_per_iteration_ms,
      aos_effective_gb_per_second);
  std::printf(
      "SoA median: %.3f ms / %d iterations = %.6f ms/step, "
      "effective bandwidth %.1f GB/s\n",
      soa_total_ms, measured_iterations, soa_per_iteration_ms,
      soa_effective_gb_per_second);
  std::printf("SoA speedup over AoS: %.3fx\n",
              aos_total_ms / soa_total_ms);
  std::printf("sample mismatches: %d\n", mismatches);

  // 小规模 sanitizer 模式的数据可能完全留在缓存中，计时不代表真实 DRAM 带宽，
  // 因此该模式只要求结果正确；正式模式才要求 SoA 实测快于 AoS。
  const bool passed =
      mismatches == 0 && (verify_only || soa_total_ms < aos_total_ms);
  std::printf("checks: %s\n", passed ? "PASS" : "FAIL");

  CUDA_CHECK(cudaEventDestroy(stop));
  CUDA_CHECK(cudaEventDestroy(start));
  CUDA_CHECK(cudaFree(soa_storage));
  CUDA_CHECK(cudaFree(aos_particles));
  return passed ? EXIT_SUCCESS : EXIT_FAILURE;
}
