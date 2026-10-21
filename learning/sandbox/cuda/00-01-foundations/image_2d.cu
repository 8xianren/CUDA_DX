#include <cstdio>
#include <cuda_runtime.h>

// 把一维数组当成二维图像： index = y * width + x  （行主序 row-major）
__global__ void make_gradient(unsigned char* img, int width, int height) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;  // 列
    int y = blockIdx.y * blockDim.y + threadIdx.y;  // 行

    // 边界判断：图像宽高通常不是 block 的整数倍，多出来的线程要剔除
    if (x >= width || y >= height) return;

    int idx = y * width + x;                        // 二维 -> 一维 偏移
    img[idx] = (unsigned char)((x + y) & 0xFF);     // 简单的对角渐变
}

int ceil_div(int a, int b) { return (a + b - 1) / b; }

int main() {
    const int W = 1920, H = 1080;
    const size_t bytes = (size_t)W * H;

    unsigned char *d_img, *h_img = (unsigned char*)malloc(bytes);
    cudaMalloc(&d_img, bytes);

    // 二维线程组织：每个 block 16x16=256 线程；grid 覆盖整张图
    dim3 block(16, 16);
    dim3 grid(ceil_div(W, block.x), ceil_div(H, block.y));
    printf("image %dx%d | block=%dx%d | grid=%dx%d (=%d blocks)\n",
           W, H, block.x, block.y, grid.x, grid.y, grid.x * grid.y);

    make_gradient<<<grid, block>>>(d_img, W, H);
    cudaMemcpy(h_img, d_img, bytes, cudaMemcpyDeviceToHost);

    // 抽查几个像素，验证 (x+y)&0xFF
    auto px = [&](int x, int y){ return (int)h_img[(size_t)y * W + x]; };
    printf("px(0,0)=%d  px(10,5)=%d  px(W-1,H-1)=%d (期望 (x+y)&255)\n",
           px(0,0), px(10,5), px(W-1,H-1));

    cudaFree(d_img); free(h_img);
    return 0;
}
