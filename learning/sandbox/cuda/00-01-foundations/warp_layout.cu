#include <cstdio>
#include <cuda_runtime.h>

// 揭示：二维/三维的 threadIdx 在硬件里会被“线性化”成一维，再按 32 个切成 warp
__global__ void show_layout() {
    // 硬件线性化公式：x 变化最快，然后 y，最后 z
    int linear = threadIdx.x
               + threadIdx.y * blockDim.x
               + threadIdx.z * blockDim.x * blockDim.y;
    int warp = linear / warpSize;   // 第几个 warp
    int lane = linear % warpSize;   // 在 warp 内的第几号（lane）
    printf("(x=%d,y=%d) -> linear=%2d -> warp=%d lane=%2d\n",
           threadIdx.x, threadIdx.y, linear, warp, lane);
}

int main() {
    dim3 block(8, 8);   // 逻辑上 8x8=64 个线程的“二维方块”
    show_layout<<<1, block>>>();
    cudaDeviceSynchronize();
    return 0;
}
