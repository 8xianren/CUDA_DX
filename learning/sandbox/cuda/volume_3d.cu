#include <cstdio>
#include <cuda_runtime.h>

int ceil_div(int a, int b) { return (a + b - 1) / b; }

// 三维体数据：尺寸 W(宽) x H(高) x D(深)
// 内存是一维的，约定排布：先按 x 连续，再 y，再 z
// 线性偏移 idx = (z*H + y)*W + x = z*(W*H) + y*W + x
__global__ void fill_volume(int* vol, int W, int H, int D) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    int z = blockIdx.z * blockDim.z + threadIdx.z;
    if (x >= W || y >= H || z >= D) return;          // 三维边界判断

    int idx = (z * H + y) * W + x;
    vol[idx] = idx;          // 把每个体素的线性下标写进去，方便验证
}

int main() {
    const int W = 4, H = 3, D = 2;                   // 故意取小，便于打印
    const int N = W * H * D;                         // = 24 个体素
    const size_t bytes = N * sizeof(int);

    int *d_vol, *h_vol = (int*)malloc(bytes);
    cudaMalloc(&d_vol, bytes);

    dim3 block(2, 2, 2);                             // 每个 block 2x2x2 = 8 线程
    dim3 grid(ceil_div(W, block.x),
              ceil_div(H, block.y),
              ceil_div(D, block.z));
    printf("volume %dx%dx%d (N=%d) | block=%dx%dx%d | grid=%dx%dx%d\n",
           W, H, D, N, block.x, block.y, block.z, grid.x, grid.y, grid.z);

    fill_volume<<<grid, block>>>(d_vol, W, H, D);
    cudaMemcpy(h_vol, d_vol, bytes, cudaMemcpyDeviceToHost);

    // 按 z 切片、再按 y 行 打印，看清三维如何铺进一维内存
    for (int z = 0; z < D; ++z) {
        printf("---- z=%d 这一层(slice) ----\n", z);
        for (int y = 0; y < H; ++y) {
            for (int x = 0; x < W; ++x) {
                int idx = (z * H + y) * W + x;
                printf("%3d ", h_vol[idx]);          // 打印的是该体素的线性下标
            }
            printf("   <- y=%d 行\n", y);
        }
    }

    cudaFree(d_vol); free(h_vol);
    return 0;
}
