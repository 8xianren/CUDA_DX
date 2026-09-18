#include <cooperative_groups.h>
#include <cuda_runtime.h>

#include <cstdio>
#include <cstdlib>

namespace cg = cooperative_groups;

#define CUDA_CHECK(call)                                                        \
  do {                                                                          \
    cudaError_t error = (call);                                                  \
    if (error != cudaSuccess) {                                                  \
      std::fprintf(stderr, "%s failed: %s\n", #call, cudaGetErrorString(error)); \
      std::exit(EXIT_FAILURE);                                                   \
    }                                                                            \
  } while (0)

constexpr int kBlocksPerCluster = 2;
constexpr int kThreadsPerBlock = 32;

__global__ void __cluster_dims__(kBlocksPerCluster, 1, 1)
cluster_dsm_kernel(int* sums, int* observed_owner, int* cluster_sizes) {
  __shared__ int local_value;
  cg::cluster_group cluster = cg::this_cluster();

  const unsigned int rank = cluster.block_rank();
  if (threadIdx.x == 0) {
    local_value = static_cast<int>((rank + 1) * 100);
  }

  // All blocks must exist, and their shared-memory initialization must be
  // visible, before any block maps a remote shared-memory address.
  cluster.sync();

  if (threadIdx.x == 0) {
    const unsigned int peer_rank = 1 - rank;
    int* peer_value = cluster.map_shared_rank(&local_value, peer_rank);

    sums[rank] = local_value + *peer_value;
    observed_owner[rank] =
        static_cast<int>(cluster.query_shared_rank(peer_value));
    cluster_sizes[rank] = static_cast<int>(cluster.num_blocks());
  }

  // A block may not exit while another block can still access its shared
  // memory through DSM.
  cluster.sync();
}

int main() {
  int* d_sums = nullptr;
  int* d_observed_owner = nullptr;
  int* d_cluster_sizes = nullptr;
  CUDA_CHECK(cudaMalloc(&d_sums, kBlocksPerCluster * sizeof(int)));
  CUDA_CHECK(cudaMalloc(&d_observed_owner,
                        kBlocksPerCluster * sizeof(int)));
  CUDA_CHECK(cudaMalloc(&d_cluster_sizes,
                        kBlocksPerCluster * sizeof(int)));

  cluster_dsm_kernel<<<kBlocksPerCluster, kThreadsPerBlock>>>(
      d_sums, d_observed_owner, d_cluster_sizes);
  CUDA_CHECK(cudaGetLastError());
  CUDA_CHECK(cudaDeviceSynchronize());

  int sums[kBlocksPerCluster]{};
  int observed_owner[kBlocksPerCluster]{};
  int cluster_sizes[kBlocksPerCluster]{};
  CUDA_CHECK(cudaMemcpy(sums, d_sums, sizeof(sums), cudaMemcpyDeviceToHost));
  CUDA_CHECK(cudaMemcpy(observed_owner, d_observed_owner,
                        sizeof(observed_owner), cudaMemcpyDeviceToHost));
  CUDA_CHECK(cudaMemcpy(cluster_sizes, d_cluster_sizes,
                        sizeof(cluster_sizes), cudaMemcpyDeviceToHost));

  int mismatches = 0;
  for (int rank = 0; rank < kBlocksPerCluster; ++rank) {
    const int expected_peer = 1 - rank;
    std::printf(
        "block %d: local=%d, peer_rank=%d, local+peer=%d, cluster_blocks=%d\n",
        rank, (rank + 1) * 100, observed_owner[rank], sums[rank],
        cluster_sizes[rank]);
    if (sums[rank] != 300 || observed_owner[rank] != expected_peer ||
        cluster_sizes[rank] != kBlocksPerCluster) {
      ++mismatches;
    }
  }
  std::printf("mismatches: %d\n", mismatches);

  CUDA_CHECK(cudaFree(d_cluster_sizes));
  CUDA_CHECK(cudaFree(d_observed_owner));
  CUDA_CHECK(cudaFree(d_sums));
  return mismatches == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
