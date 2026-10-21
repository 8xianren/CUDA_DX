#include <cstdio>
#include <cuda_runtime.h>

// 向上取整除法：保证 block 数量足够覆盖所有元素
int ceil_div(int a, int b) { return (a + b - 1) / b; }

// 核函数：c[i] = a[i] + b[i]
// 用 grid-stride loop，使代码不依赖具体的 grid/block 配置
__global__ void vector_add(const float* a, const float* b, float* c, int n) {
    int idx    = blockIdx.x * blockDim.x + threadIdx.x;  // 全局唯一编号
    int stride = blockDim.x * gridDim.x;                 // grid 内总线程数
    for (int i = idx; i < n; i += stride) {
        c[i] = a[i] + b[i];
    }
}

int main() {
    const int n = 1'000'000;
    const size_t bytes = n * sizeof(float);

    // 1) 主机端(host)数据
    float *ha = (float*)malloc(bytes);
    float *hb = (float*)malloc(bytes);
    float *hc = (float*)malloc(bytes);
    for (int i = 0; i < n; ++i) { ha[i] = i * 1.0f; hb[i] = i * 2.0f; }

    // 2) 设备端(device)显存
    float *da, *db, *dc;
    cudaMalloc(&da, bytes);
    cudaMalloc(&db, bytes);
    cudaMalloc(&dc, bytes);

    // 3) host -> device 拷贝
    cudaMemcpy(da, ha, bytes, cudaMemcpyHostToDevice);
    cudaMemcpy(db, hb, bytes, cudaMemcpyHostToDevice);

    // 4) 配置并启动 kernel：block 取 256(=8*32)，grid 由问题规模推导
    int block_size = 256;
    int grid_size  = ceil_div(n, block_size);
    printf("n=%d, grid=%d blocks, block=%d threads, total=%d threads\n",
           n, grid_size, block_size, grid_size * block_size);
    vector_add<<<grid_size, block_size>>>(da, db, dc, n);

    // 5) device -> host 取回结果
    cudaMemcpy(hc, dc, bytes, cudaMemcpyDeviceToHost);

    // 6) 抽查几个结果（应满足 c[i] = 3*i）
    printf("c[0]=%.1f  c[100]=%.1f  c[%d]=%.1f  (期望 3*i)\n",
           hc[0], hc[100], n - 1, hc[n - 1]);

    cudaFree(da); cudaFree(db); cudaFree(dc);
    free(ha); free(hb); free(hc);
    return 0;
}
