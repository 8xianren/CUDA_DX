#include <cstdio>
#include <cuda_runtime.h>

// 子 kernel：处理一个“任务块”里的元素
__global__ void child(float* data, int begin, int end, float k) {
    int i = begin + blockIdx.x * blockDim.x + threadIdx.x;
    if (i < end) data[i] = data[i] * k + 1.0f;
}

// 父 kernel：每个线程负责一个“任务”，任务大小不一 —— 谁的活多，谁就自己再启动子 kernel
// 这就是动态并行：GPU 上的 kernel 自己给自己派活，无需回到 CPU
__global__ void parent(float* data, const int* task_begin, const int* task_end, int ntasks) {
    int t = blockIdx.x * blockDim.x + threadIdx.x;
    if (t >= ntasks) return;

    int begin = task_begin[t], end = task_end[t];
    int n = end - begin;
    if (n <= 0) return;

    // 运行时才知道这个任务多大 -> 动态决定子 kernel 的规模
    int block = 128;
    int grid  = (n + block - 1) / block;
    child<<<grid, block>>>(data, begin, end, 2.0f);   // ！在 device 端启动 kernel
}

int main() {
    const int ntasks = 8;
    // 任务大小故意悬殊：从 10 到 100000，体现“负载不均、运行时才知道规模”
    int sizes[ntasks] = {10, 50, 200, 1000, 5000, 20000, 60000, 100000};
    int begins[ntasks], ends[ntasks], total = 0;
    for (int i = 0; i < ntasks; ++i) { begins[i]=total; total+=sizes[i]; ends[i]=total; }

    float* h = (float*)malloc(total*sizeof(float));
    for (int i = 0; i < total; ++i) h[i] = 1.0f;

    float* d; cudaMalloc(&d, total*sizeof(float));
    cudaMemcpy(d, h, total*sizeof(float), cudaMemcpyHostToDevice);
    int *d_b, *d_e; cudaMalloc(&d_b, ntasks*sizeof(int)); cudaMalloc(&d_e, ntasks*sizeof(int));
    cudaMemcpy(d_b, begins, ntasks*sizeof(int), cudaMemcpyHostToDevice);
    cudaMemcpy(d_e, ends,   ntasks*sizeof(int), cudaMemcpyHostToDevice);

    // 父 kernel 一次启动，内部按需再派生子 kernel
    parent<<<1, ntasks>>>(d, d_b, d_e, ntasks);
    cudaError_t err = cudaDeviceSynchronize();   // 等父+所有子 kernel 全部完成
    if (err) { printf("错误: %s\n", cudaGetErrorString(err)); return 1; }

    cudaMemcpy(h, d, total*sizeof(float), cudaMemcpyDeviceToHost);
    // 校验：每个元素应从 1.0 -> 1.0*2+1 = 3.0
    int wrong = 0; for (int i = 0; i < total; ++i) if (h[i] != 3.0f) wrong++;
    printf("%d 个任务，共 %d 元素；结果错误 %d 个（应为 0，每个值应=3.0）\n",
           ntasks, total, wrong);
    printf("示例 h[0]=%.1f  h[%d]=%.1f\n", h[0], total-1, h[total-1]);

    cudaFree(d); cudaFree(d_b); cudaFree(d_e); free(h);
    return 0;
}
