#include <cstdio>
#include <cuda/std/mdspan>
#include <cuda/std/array>

int main() {
    // 一块“扁平”的一维数据（行主序存放 2 行 3 列）
    cuda::std::array<int, 6> flat{ 0, 1, 2, 3, 4, 5 };

    // mdspan：给这块一维数据套一个“2 行 x 3 列”的二维视图（不拷贝数据）
    cuda::std::mdspan md(flat.data(), 2, 3);

    // 直接用 (行, 列) 访问，不用再手写 row*width + col
    printf("md(0,0)=%d  md(1,2)=%d  (期望 0, 5)\n", md(0, 0), md(1, 2));
    printf("size=%zu height=extent(0)=%zu width=extent(1)=%zu\n",
           md.size(), md.extent(0), md.extent(1));

    // 对比：手写一维下标得到同样的 md(1,2)
    int row = 1, col = 2, width = 3;
    printf("手写下标 flat[row*width+col] = %d (应等于 md(1,2))\n", flat[row * width + col]);
    return 0;
}
