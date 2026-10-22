# G.7：把高斯分配给 tile，再建立确定的前后顺序

[课程工程](../../sandbox/d3d12/neural-rendering/README.md) · [GPU 管线](../../sandbox/d3d12/neural-rendering/src/gaussian/gaussian.cu) · [CPU 列表参考](../../sandbox/d3d12/neural-rendering/src/gaussian/gaussian_cpu.cpp) · [G.8](G.8-Tile光栅与共享内存.md)

本节解决两个不同问题：哪些高斯可能影响这个屏幕小块，以及应该按什么前后顺序合成。前者是空间分桶，后者是排序；分桶本身不会自动提供正确透明顺序。

## 1. 从每像素遍历全部高斯推导分桶

假设 640×360 图像有 100,000 个高斯。每像素检查全部元素需要约 230 亿次候选检查，而且绝大多数斑点离该像素很远。游戏引擎的 tiled/clustered lighting 也先给局部区域建立候选列表；这里复用的是“局部候选”的思想，候选类型与最终合成规则不同。

将屏幕切成 16×16 tile。640×360 对应 `ceil(640/16)×ceil(360/16)=40×23=920` 块，最后一行只有 8 个有效像素。投影矩形使用半开区间 `[min,max)`，所以 tile 范围为 `min/16` 到 `ceil(max/16)`，不包含末端。覆盖数 `ni=(tileMaxX−tileMinX)(tileMaxY−tileMinY)`。

一个高斯可能覆盖多块，因此不能用一个固定槽保存它的 tile。我们需要重复引用，而不是重复整份 Gaussian。引用保存一个 64-bit key 和一个 32-bit 高斯数组索引，几何参数仍只有一份。

## 2. 为什么 prefix sum 可以消除原子分配

假设三个高斯覆盖数为 `[2,0,3]`。inclusive sum 是 `[2,2,5]`，它们的输出区间分别是 `[0,2)`、`[2,2)`、`[2,5)`。一般地，第 i 个高斯拥有：

```text
start_i = (i == 0 ? 0 : prefix[i−1])
end_i   = prefix[i]
```

这些区间连续且不重叠，所以每个高斯的一个线程可以独立向自己区间写 tile 引用，不需要每写一条就 atomicAdd 一个全局游标。scan 把“多少个”变成了“从哪里开始”。

本课计数和 prefix 都使用 uint64。不能先在 uint32 中加到溢出，再把结果转成 uint64 假装安全。窗口最大 16384²、输入最多 4,000,000 个，高斯覆盖 tile 总量的理论上界在 uint64 可表达范围内；实际总引用硬性限制为 8,000,000，检查后才缩为 uint32 并分配双缓冲。

真实失败路径测试构造 9,000 个覆盖 512² 全屏的高斯，得到 9,216,000 引用，必须在 duplicate kernel 启动前抛出带上限的异常。这是预算策略，不是声称 GPU 只能处理 8M 引用。

## 3. CUB API 的两次调用与资源所有权

CUDA 13.3 随附头文件中使用的签名如下（省略 CUDA 修饰宏）：

```cpp
template<class InputIteratorT, class OutputIteratorT, class NumItemsT>
static cudaError_t cub::DeviceScan::InclusiveSum(
    void* d_temp_storage, size_t& temp_storage_bytes,
    InputIteratorT d_in, OutputIteratorT d_out,
    NumItemsT num_items, cudaStream_t stream = 0);
```

`d_in` 指向 n 个 uint64 覆盖数，`d_out` 指向 n 个 uint64 前缀；`num_items` 是元素数而非字节数；`stream` 指定在哪条 CUDA 流排队。先传 `d_temp_storage=nullptr` 查询需求，CUB 把所需字节数写回引用参数 `temp_storage_bytes`；再由 Renderer 分配 scratch，并传真实指针执行。返回值不是前缀和，而是 `cudaError_t`，失败要抛出可读错误。

排序使用：

```cpp
template<class KeyT, class ValueT, class NumItemsT>
static cudaError_t cub::DeviceRadixSort::SortPairs(
    void* d_temp_storage, size_t& temp_storage_bytes,
    const KeyT* d_keys_in, KeyT* d_keys_out,
    const ValueT* d_values_in, ValueT* d_values_out,
    NumItemsT num_items, int begin_bit=0,
    int end_bit=sizeof(KeyT)*8, cudaStream_t stream=0);
```

key 的类型为 uint64，value 为 uint32 索引。输入与输出数组不可重叠；`begin_bit=0,end_bit=64` 处理完整 key，end 是不包含的末位。sort 也先查询 scratch。scan 已完成之后，同一 Renderer 的 scratch 可重新用于 sort；保留两者需求最大值，不能在 scan 尚未结束时释放或覆盖。

这些数组和 scratch 全由 Renderer 的 RAII Buffer 管理。调用者只拥有最终 RGBA、可选深度和只读网格深度。所有 CUDA 核、CUB 操作、异步复制都传同一个 stream，顺序依赖由流保证。计数读回后显式 `cudaStreamSynchronize(stream)`，以便 CPU 根据实际引用数检查上限和分配内存；返回 Stats 前再同步读取事件和剔除统计。`cudaMemcpyAsync` 的名称并不保证这条教学接口无 CPU 等待。

## 4. 排序键如何编码深度，平局为什么必须处理

键定义为：

```text
key = (uint64(tileId) << 32) | floatBits(positiveCameraZ)
```

高 32 位首先按 tile 排列；相同 tile 内，低 32 位按深度升序。对正有限 IEEE754 float，位模式的无符号升序与数值升序一致。本课在 G.6 已排除非正/近裁剪后侧深度以及非法值；不能把这个结论推广到负数 float。

仍有一个陷阱：两个高斯的深度完全相同，颜色不同，交换合成顺序通常会改变图像。不能说“已经按深度排了，所以任意输入顺序都等价”。本课先在 `setScene` 按唯一 stable id 排输入，重复 id 报错；duplicate 按该顺序写引用；CUB 的 radix sort 是稳定的，因此相同 `(tile,z)` 的元素保留 stable id 升序。没有牺牲深度精度去腾出 id 位数。

这也解释了为什么单纯 `sort(key)` 未必足够：若某个排序实现不稳定，又没有显式 tie-break，等深度的顺序仍可能变化。[NVIDIA CUB 源码文档](https://github.com/NVIDIA/cccl/blob/main/cub/cub/device/device_radix_sort.cuh)明确说明了稳定性与不允许输入/输出重叠。

## 5. 排好序以后怎样形成 tile range

排序后同一个 tile 的引用连续。每个引用线程比较自己与前后邻居的 tileId：若与前一个不同，写 `ranges[tile].x=i`；若与后一个不同，写 `ranges[tile].y=i+1`。空 tile 的 range 预先清零，得到 `[0,0)`。

只在边界写两个字段，不需要遍历所有 tile 做二分查找。每个 tile 的起点/终点各有唯一写者，不存在多个线程争抢同一字段。最后一项不读 `keys[n]`，第一项不读 `keys[-1]`，边界分支不能省略。

## 6. 验收结果、性能口径与答案

命令从仓库根执行：

```powershell
& learning/sandbox/d3d12/neural-rendering/tests/gaussian/verify.ps1 -Build
```

CPU 用 `push_back` 与比较排序独立构造列表，逐条核对 tile、深度 key、stable id。小场景特意放入 12 个等深度重叠高斯，再 shuffle 输入；排序 key/id 列表完全相同，后续图像逐 bit 相同。不是只比较列表长度，也不是“看起来差不多”。

大场景结果保存于 [binning.json](../../sandbox/d3d12/neural-rendering/results/g7/binning.json)：RTX 5070、sm_120、CUDA 13.3；640×360；100,000 输入且全部可见；987,538 个重复引用；920 tile。Renderer 持久分配约 59.3 MB，CUB scratch 约 12.0 MB（十进制字节，另外还需调用方图像等资源）。

经过 3 次预热，10 次独占 GPU 测量的阶段均值写在 JSON：投影约 0.138 ms，scan 约 0.011 ms，复制约 0.067 ms，排序约 0.217 ms，range 约 0.015 ms，splat 约 0.169 ms。以最终 JSON 为精确数字；这些 CUDA event 区间不包括 CPU canonical 排序、上传、计数读回等待与动态分配，不能用总和代替端到端帧时间。

自测答案：prefix 解决输出位置分配，不解决透明顺序；stable sort 只保持输入平局次序，因此还需要 canonical stable id；把每个高斯复制十次不等于把整份 SH/协方差复制十次，本实现复制的是 key 与索引。

生产渲染器通常预留容量、用 GPU 驱动调度/更少读回，以及更适合带宽的数据组织。本课保留同步计数检查，便于观察溢出、内存预算与每步结果；排序机制与所有权原则相同。
