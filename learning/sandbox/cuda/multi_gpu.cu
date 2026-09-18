#include <cstdio>
#include <cuda_runtime.h>

__global__ void scale(float* a, int n, float k) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) a[i] *= k;
}

int main() {
    int ndev = 0;
    cudaGetDeviceCount(&ndev);
    printf("检测到 %d 块 GPU\n\n", ndev);

    // 1) 枚举每块 GPU 的信息
    for (int d = 0; d < ndev; ++d) {
        cudaDeviceProp p; cudaGetDeviceProperties(&p, d);
        printf("GPU %d: %s  (sm_%d%d, %d 个 SM, %.1f GB)\n",
               d, p.name, p.major, p.minor, p.multiProcessorCount,
               p.totalGlobalMem / 1e9);
    }
    printf("\n");

    // 2) P2P：查询任意两块 GPU 能否直接互访显存（不经过 CPU）
    printf("--- P2P 直连能力矩阵 ---\n");
    for (int i = 0; i < ndev; ++i)
        for (int j = 0; j < ndev; ++j) if (i != j) {
            int can = 0; cudaDeviceCanAccessPeer(&can, i, j);
            printf("GPU %d -> GPU %d : %s\n", i, j, can ? "可直连(P2P)" : "不可");
        }
    if (ndev < 2) printf("(只有 1 块 GPU，无 P2P 可演示)\n");
    printf("\n");

    // 3) 多 GPU 编程范式：用 cudaSetDevice 切换“当前设备”，把工作分给各卡
    const int n = 1 << 20;
    printf("--- 把 %d 个元素切成 %d 份，每块 GPU 处理一份 ---\n", n, ndev);
    int chunk = (n + ndev - 1) / ndev;
    float** dptr = (float**)malloc(ndev * sizeof(float*));
    cudaStream_t* streams = (cudaStream_t*)malloc(ndev * sizeof(cudaStream_t));

    for (int d = 0; d < ndev; ++d) {
        cudaSetDevice(d);                 // ！关键：之后的分配/启动都作用在第 d 块 GPU
        int sz = (d == ndev-1) ? (n - chunk*(ndev-1)) : chunk;
        cudaMalloc(&dptr[d], sz * sizeof(float));   // 显存分配在“当前设备”上
        cudaStreamCreate(&streams[d]);
        cudaMemsetAsync(dptr[d], 0, sz*sizeof(float), streams[d]);
        scale<<<(sz+255)/256, 256, 0, streams[d]>>>(dptr[d], sz, 2.0f); // 在第 d 块上跑
        printf("GPU %d: 分到 %d 个元素，已启动 kernel\n", d, sz);
    }

    // 4) 分别同步每块 GPU
    for (int d = 0; d < ndev; ++d) {
        cudaSetDevice(d);
        cudaStreamSynchronize(streams[d]);
        cudaFree(dptr[d]); cudaStreamDestroy(streams[d]);
    }
    printf("\n全部 GPU 完成。\n");

    free(dptr); free(streams);
    return 0;
}
