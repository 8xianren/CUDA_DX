#include <cstdio>
#include <cmath>
#include <thrust/universal_vector.h>
#include <thrust/reduce.h>
#include <thrust/tuple.h>
#include <thrust/iterator/zip_iterator.h>
#include <thrust/iterator/transform_iterator.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/execution_policy.h>

int main() {
    thrust::universal_vector<float> a{42, 24, 50, 10};
    thrust::universal_vector<float> b{20, 20, 20, 20};

    // counting_iterator：凭空生成 0,1,2,... 不占一个字节
    thrust::counting_iterator<int> cnt(0);
    printf("counting: %d %d %d (无存储)\n", cnt[0], cnt[1], cnt[2]);

    // zip_iterator：把 a、b 两条序列“拉链”成 (a[i], b[i]) 元组序列
    auto zip = thrust::make_zip_iterator(a.begin(), b.begin());

    // transform_iterator：在“解引用时”就地算出 |a[i]-b[i]|，不落地中间数组
    auto diff = thrust::make_transform_iterator(zip,
        [] __host__ __device__ (thrust::tuple<float,float> t) {
            return fabsf(thrust::get<0>(t) - thrust::get<1>(t));
        });

    // reduce 直接吃这个“虚拟”的差值序列，求最大值 —— 全程没有中间数组
    float max_change = thrust::reduce(thrust::device, diff, diff + a.size(),
                                      0.0f, thrust::maximum<float>{});
    printf("max |a-b| = %.1f (期望 30 = |50-20|)\n", max_change);
    return 0;
}
