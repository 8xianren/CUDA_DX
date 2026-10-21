#include <cuda_runtime.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

#define CUDA_CHECK(call)                                                        \
  do {                                                                          \
    const cudaError_t error = (call);                                            \
    if (error != cudaSuccess) {                                                  \
      std::fprintf(stderr, "%s failed: %s\n", #call,                          \
                   cudaGetErrorString(error));                                   \
      std::exit(EXIT_FAILURE);                                                   \
    }                                                                            \
  } while (0)

struct OscillatorState {
  float position;
  float velocity;
};

enum class Integrator {
  ExplicitEuler,
  SemiImplicitEuler,
  VelocityVerlet,
};

__device__ __forceinline__ void explicit_euler_step(
    OscillatorState& state, float dt, float omega_squared) {
  const float acceleration = -omega_squared * state.position;

  // Both updates use the state at time n.
  state.position += state.velocity * dt;
  state.velocity += acceleration * dt;
}

__device__ __forceinline__ void semi_implicit_euler_step(
    OscillatorState& state, float dt, float omega_squared) {
  const float acceleration = -omega_squared * state.position;

  // Position uses the newly updated velocity at time n + 1.
  state.velocity += acceleration * dt;
  state.position += state.velocity * dt;
}

__device__ __forceinline__ void velocity_verlet_step(
    OscillatorState& state, float dt, float omega_squared) {
  const float old_acceleration = -omega_squared * state.position;

  state.position += state.velocity * dt +
                    0.5f * old_acceleration * dt * dt;

  // A position-dependent force must be evaluated again at the new position.
  const float new_acceleration = -omega_squared * state.position;
  state.velocity += 0.5f * (old_acceleration + new_acceleration) * dt;
}

template <Integrator integrator>
__global__ void simulate_oscillators(OscillatorState* states, int count,
                                     int step_count, float dt,
                                     float omega_squared) {
  const int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index >= count) {
    return;
  }

  OscillatorState state = states[index];
  for (int step = 0; step < step_count; ++step) {
    if constexpr (integrator == Integrator::ExplicitEuler) {
      explicit_euler_step(state, dt, omega_squared);
    } else if constexpr (integrator == Integrator::SemiImplicitEuler) {
      semi_implicit_euler_step(state, dt, omega_squared);
    } else {
      velocity_verlet_step(state, dt, omega_squared);
    }
  }
  states[index] = state;
}

struct ErrorStats {
  double mean_relative_energy_error = 0.0;
  double maximum_relative_energy_error = 0.0;
  double root_mean_square_position_error = 0.0;
  double maximum_position_error = 0.0;
  bool all_finite = true;
};

double energy(const OscillatorState& state, double omega_squared) {
  const double position = state.position;
  const double velocity = state.velocity;
  return 0.5 * velocity * velocity +
         0.5 * omega_squared * position * position;
}

ErrorStats calculate_errors(const std::vector<OscillatorState>& initial,
                            const std::vector<OscillatorState>& actual,
                            double omega, double elapsed_time) {
  ErrorStats stats{};
  const double omega_squared = omega * omega;
  const double cosine = std::cos(omega * elapsed_time);
  const double sine = std::sin(omega * elapsed_time);
  double position_squared_error_sum = 0.0;

  for (std::size_t index = 0; index < initial.size(); ++index) {
    const double initial_energy = energy(initial[index], omega_squared);
    const double actual_energy = energy(actual[index], omega_squared);
    const double relative_energy_error =
        std::abs(actual_energy - initial_energy) / initial_energy;

    // Exact solution of x'' = -omega^2 x for the quantized FP32 initial state.
    const double exact_position =
        static_cast<double>(initial[index].position) * cosine +
        static_cast<double>(initial[index].velocity) * sine / omega;
    const double position_error =
        std::abs(static_cast<double>(actual[index].position) - exact_position);

    stats.mean_relative_energy_error += relative_energy_error;
    stats.maximum_relative_energy_error =
        std::max(stats.maximum_relative_energy_error, relative_energy_error);
    position_squared_error_sum += position_error * position_error;
    stats.maximum_position_error =
        std::max(stats.maximum_position_error, position_error);
    stats.all_finite =
        stats.all_finite && std::isfinite(actual_energy) &&
        std::isfinite(static_cast<double>(actual[index].position)) &&
        std::isfinite(static_cast<double>(actual[index].velocity));
  }

  const double inverse_count = 1.0 / static_cast<double>(initial.size());
  stats.mean_relative_energy_error *= inverse_count;
  stats.root_mean_square_position_error =
      std::sqrt(position_squared_error_sum * inverse_count);
  return stats;
}

void print_stats(const char* name, const ErrorStats& stats,
                 const OscillatorState& sample) {
  std::printf(
      "%-20s mean |dE|/E0 = %10.6f, max = %10.6f, "
      "position RMSE = %.6f, max = %.6f, sample=(x=% .6f, v=% .6f)\n",
      name, stats.mean_relative_energy_error,
      stats.maximum_relative_energy_error,
      stats.root_mean_square_position_error, stats.maximum_position_error,
      sample.position, sample.velocity);
}

int main() {
  constexpr int particle_count = 4096;
  constexpr int step_count = 600;
  constexpr float dt = 1.0f / 60.0f;
  constexpr float omega = 4.0f;
  constexpr float omega_squared = omega * omega;
  constexpr double pi = 3.14159265358979323846;
  constexpr std::size_t bytes =
      static_cast<std::size_t>(particle_count) * sizeof(OscillatorState);

  // Every particle starts at a different phase but with the same amplitude and
  // therefore the same exact total energy.
  std::vector<OscillatorState> initial(particle_count);
  for (int index = 0; index < particle_count; ++index) {
    const double phase =
        2.0 * pi * static_cast<double>(index) / particle_count;
    initial[index].position = static_cast<float>(std::cos(phase));
    initial[index].velocity =
        static_cast<float>(-static_cast<double>(omega) * std::sin(phase));
  }

  OscillatorState* explicit_states = nullptr;
  OscillatorState* semi_implicit_states = nullptr;
  OscillatorState* verlet_states = nullptr;
  CUDA_CHECK(cudaMalloc(&explicit_states, bytes));
  CUDA_CHECK(cudaMalloc(&semi_implicit_states, bytes));
  CUDA_CHECK(cudaMalloc(&verlet_states, bytes));

  CUDA_CHECK(cudaMemcpy(explicit_states, initial.data(), bytes,
                        cudaMemcpyHostToDevice));
  CUDA_CHECK(cudaMemcpy(semi_implicit_states, initial.data(), bytes,
                        cudaMemcpyHostToDevice));
  CUDA_CHECK(cudaMemcpy(verlet_states, initial.data(), bytes,
                        cudaMemcpyHostToDevice));

  constexpr int threads = 256;
  constexpr int blocks = (particle_count + threads - 1) / threads;
  simulate_oscillators<Integrator::ExplicitEuler><<<blocks, threads>>>(
      explicit_states, particle_count, step_count, dt, omega_squared);
  simulate_oscillators<Integrator::SemiImplicitEuler><<<blocks, threads>>>(
      semi_implicit_states, particle_count, step_count, dt, omega_squared);
  simulate_oscillators<Integrator::VelocityVerlet><<<blocks, threads>>>(
      verlet_states, particle_count, step_count, dt, omega_squared);
  CUDA_CHECK(cudaGetLastError());
  CUDA_CHECK(cudaDeviceSynchronize());

  std::vector<OscillatorState> explicit_result(particle_count);
  std::vector<OscillatorState> semi_implicit_result(particle_count);
  std::vector<OscillatorState> verlet_result(particle_count);
  CUDA_CHECK(cudaMemcpy(explicit_result.data(), explicit_states, bytes,
                        cudaMemcpyDeviceToHost));
  CUDA_CHECK(cudaMemcpy(semi_implicit_result.data(), semi_implicit_states,
                        bytes, cudaMemcpyDeviceToHost));
  CUDA_CHECK(cudaMemcpy(verlet_result.data(), verlet_states, bytes,
                        cudaMemcpyDeviceToHost));

  const double elapsed_time = static_cast<double>(dt) * step_count;
  const ErrorStats explicit_stats =
      calculate_errors(initial, explicit_result, omega, elapsed_time);
  const ErrorStats semi_implicit_stats =
      calculate_errors(initial, semi_implicit_result, omega, elapsed_time);
  const ErrorStats verlet_stats =
      calculate_errors(initial, verlet_result, omega, elapsed_time);

  const double exact_sample_position =
      static_cast<double>(initial[0].position) *
          std::cos(static_cast<double>(omega) * elapsed_time) +
      static_cast<double>(initial[0].velocity) *
          std::sin(static_cast<double>(omega) * elapsed_time) / omega;
  const double exact_sample_velocity =
      -static_cast<double>(initial[0].position) * omega *
          std::sin(static_cast<double>(omega) * elapsed_time) +
      static_cast<double>(initial[0].velocity) *
          std::cos(static_cast<double>(omega) * elapsed_time);

  std::printf("harmonic oscillator: x'' = -(%.1f^2) x\n", omega);
  std::printf("particles=%d, dt=%.9f s, steps=%d, elapsed=%.6f s\n",
              particle_count, dt, step_count, elapsed_time);
  std::printf("exact sample[0] after %.3f s: x=% .6f, v=% .6f\n",
              elapsed_time, exact_sample_position, exact_sample_velocity);
  print_stats("Explicit Euler", explicit_stats, explicit_result[0]);
  print_stats("Semi-implicit Euler", semi_implicit_stats,
              semi_implicit_result[0]);
  print_stats("Velocity Verlet", verlet_stats, verlet_result[0]);

  // Broad checks: the demo should expose energy explosion in explicit Euler,
  // bounded error in semi-implicit Euler, and the smaller error of Verlet.
  const bool passed =
      explicit_stats.all_finite && semi_implicit_stats.all_finite &&
      verlet_stats.all_finite &&
      explicit_stats.mean_relative_energy_error > 1.0 &&
      semi_implicit_stats.maximum_relative_energy_error < 0.1 &&
      verlet_stats.maximum_relative_energy_error < 0.01 &&
      verlet_stats.maximum_relative_energy_error <
          semi_implicit_stats.maximum_relative_energy_error;
  std::printf("checks: %s\n", passed ? "PASS" : "FAIL");

  CUDA_CHECK(cudaFree(verlet_states));
  CUDA_CHECK(cudaFree(semi_implicit_states));
  CUDA_CHECK(cudaFree(explicit_states));
  return passed ? EXIT_SUCCESS : EXIT_FAILURE;
}
