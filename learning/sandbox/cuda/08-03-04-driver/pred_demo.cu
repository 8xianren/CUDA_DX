#include <cuda_runtime.h>

// ① 短 if：body 很轻 —— 编译器倾向“谓词化”(无跳转)
__global__ void shortIf(float* a, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) {
        if (a[i] > 0.f) a[i] = a[i] * 2.f;
    }
}

// ② 三元选择：a = cond ? x : y —— 编译器倾向单条“条件选择”指令(SEL)
__global__ void selIf(float* a, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) {
        float v = a[i];
        a[i] = (v > 0.f) ? (v * 2.f) : (v - 1.f);
    }
}

// ③ 长 if：两条“重”路径 —— 编译器倾向真跳转(BRA)+ warp 内发散
__global__ void longIf(float* a, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float v = a[i];
    if (v > 0.f) { for (int k = 0; k < 64; ++k) v = sinf(v + k); }
    else         { for (int k = 0; k < 64; ++k) v = cosf(v * k + 1); }
    a[i] = v;
}
