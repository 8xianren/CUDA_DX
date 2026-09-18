#include <cuda_runtime.h>
#include <cufft.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>

#define CUDA_CHECK(call)                                                        \
  do {                                                                          \
    const cudaError_t error = (call);                                            \
    if (error != cudaSuccess) {                                                  \
      std::fprintf(stderr, "%s failed: %s\n", #call, cudaGetErrorString(error)); \
      std::exit(EXIT_FAILURE);                                                   \
    }                                                                            \
  } while (0)

#define CUFFT_CHECK(call)                                                \
  do {                                                                   \
    const cufftResult result = (call);                                    \
    if (result != CUFFT_SUCCESS) {                                        \
      std::fprintf(stderr, "%s failed: cuFFT result %d\n", #call,       \
                   static_cast<int>(result));                             \
      std::exit(EXIT_FAILURE);                                            \
    }                                                                     \
  } while (0)

int main() {
  constexpr int sample_count = 16;
  constexpr int signal_frequency = 3;
  constexpr int spectrum_count = sample_count / 2 + 1;
  constexpr float pi = 3.14159265358979323846f;

  float h_signal[sample_count]{};
  for (int i = 0; i < sample_count; ++i) {
    h_signal[i] =
        std::sin(2.0f * pi * signal_frequency * i / sample_count);
  }

  float* d_signal = nullptr;
  float* d_reconstructed = nullptr;
  cufftComplex* d_spectrum = nullptr;
  CUDA_CHECK(cudaMalloc(&d_signal, sizeof(h_signal)));
  CUDA_CHECK(cudaMalloc(&d_reconstructed, sizeof(h_signal)));
  CUDA_CHECK(cudaMalloc(&d_spectrum,
                        spectrum_count * sizeof(cufftComplex)));
  CUDA_CHECK(cudaMemcpy(d_signal, h_signal, sizeof(h_signal),
                        cudaMemcpyHostToDevice));

  cufftHandle forward_plan{};
  cufftHandle inverse_plan{};
  CUFFT_CHECK(cufftPlan1d(&forward_plan, sample_count, CUFFT_R2C, 1));
  CUFFT_CHECK(cufftPlan1d(&inverse_plan, sample_count, CUFFT_C2R, 1));

  CUFFT_CHECK(cufftExecR2C(forward_plan, d_signal, d_spectrum));

  cufftComplex h_spectrum[spectrum_count]{};
  CUDA_CHECK(cudaMemcpy(h_spectrum, d_spectrum, sizeof(h_spectrum),
                        cudaMemcpyDeviceToHost));

  int peak_bin = 0;
  float peak_magnitude = 0.0f;
  std::puts("R2C spectrum (non-negative frequencies):");
  for (int bin = 0; bin < spectrum_count; ++bin) {
    const float real = h_spectrum[bin].x;
    const float imaginary = h_spectrum[bin].y;
    const float magnitude = std::hypot(real, imaginary);
    std::printf("  bin %d: (%8.4f, %8.4f), magnitude=%8.4f\n",
                bin, real, imaginary, magnitude);
    if (magnitude > peak_magnitude) {
      peak_magnitude = magnitude;
      peak_bin = bin;
    }
  }

  CUFFT_CHECK(cufftExecC2R(inverse_plan, d_spectrum, d_reconstructed));
  float h_reconstructed[sample_count]{};
  CUDA_CHECK(cudaMemcpy(h_reconstructed, d_reconstructed,
                        sizeof(h_reconstructed), cudaMemcpyDeviceToHost));

  float max_error_after_scaling = 0.0f;
  for (int i = 0; i < sample_count; ++i) {
    const float normalized = h_reconstructed[i] / sample_count;
    max_error_after_scaling = std::max(
        max_error_after_scaling, std::fabs(normalized - h_signal[i]));
  }

  std::printf("peak bin: %d (expected %d)\n", peak_bin,
              signal_frequency);
  std::printf("peak magnitude: %.4f (expected %.4f)\n", peak_magnitude,
              sample_count / 2.0f);
  std::printf("inverse raw/input at sample 1: %.4f (expected N=%d)\n",
              h_reconstructed[1] / h_signal[1], sample_count);
  std::printf("max error after dividing inverse by N: %.8f\n",
              max_error_after_scaling);

  const bool correct = peak_bin == signal_frequency &&
                       std::fabs(peak_magnitude - sample_count / 2.0f) < 1e-4f &&
                       max_error_after_scaling < 1e-5f;

  CUFFT_CHECK(cufftDestroy(inverse_plan));
  CUFFT_CHECK(cufftDestroy(forward_plan));
  CUDA_CHECK(cudaFree(d_spectrum));
  CUDA_CHECK(cudaFree(d_reconstructed));
  CUDA_CHECK(cudaFree(d_signal));
  return correct ? EXIT_SUCCESS : EXIT_FAILURE;
}
