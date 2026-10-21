#include <cstdio>
#include <thrust/host_vector.h>
#include <thrust/device_vector.h>
#include <thrust/sort.h>
#include <thrust/transform_reduce.h>
#include <thrust/functional.h>

int main() {
    const int n = 1'000'000;

    // 造一些乱序数据：n, n-1, ..., 1
    thrust::host_vector<float> h(n);
    for (int i = 0; i < n; ++i) h[i] = (float)(n - i);
    thrust::device_vector<float> d = h;   // 一句话 host->device 拷贝

    // ---- sort：百万元素排序，一行（内部是高度优化的并行 radix sort）----
    thrust::sort(d.begin(), d.end());
    printf("sort 后: d[0]=%.0f d[1]=%.0f ... d[n-1]=%.0f (期望 1 2 ... %d)\n",
           (float)d[0], (float)d[1], (float)d[n - 1], n);

    // ---- transform_reduce：融合 “每个元素平方” + “求和” 为一趟，避免中间数组 ----
    //   sum_of_squares = Σ x^2
    double ss = thrust::transform_reduce(
        d.begin(), d.end(),
        [] __host__ __device__ (float x) { return (double)x * x; },  // 变换：平方
        0.0,                                                          // 初值
        thrust::plus<double>());                                      // 归约：加
    printf("transform_reduce 平方和 = %.0f\n", ss);

    return 0;
}
