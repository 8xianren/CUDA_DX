#include <cstdio>
#include <thrust/universal_vector.h>
#include <thrust/transform.h>
#include <thrust/execution_policy.h>

// __host__ __device__：这个 lambda 既能在 CPU 编译执行，也能在 GPU
// 物理冷却：每步把温度朝环境温度拉近 k 倍
int main() {
    float k = 0.5f, ambient = 20.0f;
    thrust::universal_vector<float> temp{42, 24, 50};
    auto cool = [=] __host__ __device__ (float t) { return t + k * (ambient - t); };

    // 第 1 步：在 HOST(CPU) 上执行同一个算法
    thrust::transform(thrust::host, temp.begin(), temp.end(), temp.begin(), cool);
    printf("host   一步后: %.2f %.2f %.2f\n", (float)temp[0], (float)temp[1], (float)temp[2]);

    // 第 2 步：仅把第一个参数换成 thrust::device，就改在 GPU 上执行（代码其余不变）
    thrust::transform(thrust::device, temp.begin(), temp.end(), temp.begin(), cool);
    printf("device 再一步: %.2f %.2f %.2f\n", (float)temp[0], (float)temp[1], (float)temp[2]);

    return 0;
}
