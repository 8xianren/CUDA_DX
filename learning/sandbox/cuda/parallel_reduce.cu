#include <cstdio>
#include <thrust/host_vector.h>
#include <thrust/device_vector.h>
#include <thrust/reduce.h>
#include <thrust/scan.h>
#include <thrust/sequence.h>
#include <thrust/execution_policy.h>

int main() {
    const int n = 1'000'000;

    // 在 device 上放 1..n
    thrust::device_vector<long long> d(n);
    thrust::sequence(d.begin(), d.end(), 1LL);   // 1,2,3,...,n

    // ---- reduce：把整个数组“归约”成一个值（求和）。一行搞定，全并行 ----
    long long sum = thrust::reduce(d.begin(), d.end(), 0LL);
    printf("reduce 求和 1..%d = %lld  (期望 %lld)\n", n, sum, (long long)n * (n + 1) / 2);

    // ---- scan：前缀和（每个位置 = 它及之前所有元素之和）----
    thrust::device_vector<long long> prefix(n);
    thrust::inclusive_scan(d.begin(), d.end(), prefix.begin());
    printf("scan 前缀和: prefix[0]=%lld prefix[3]=%lld (期望 1, 10=1+2+3+4)\n",
           (long long)prefix[0], (long long)prefix[3]);

    return 0;
}
