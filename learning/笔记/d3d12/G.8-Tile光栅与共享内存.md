# G.8：共享候选高斯，并行计算每个像素的前到后合成

[课程工程](../../sandbox/d3d12/neural-rendering/README.md) · [splatKernel](../../sandbox/d3d12/neural-rendering/src/gaussian/gaussian.cu) · [CPU 合成参考](../../sandbox/d3d12/neural-rendering/src/gaussian/gaussian_cpu.cpp) · [验证脚本](../../sandbox/d3d12/neural-rendering/tests/gaussian/verify.ps1)

本节把已经正确排序的高斯引用变成线性预乘 RGBA。核心问题不是“画一个点”，而是同一个 tile 的 256 个像素如何复用候选参数，并在不同像素提前终止时仍保证 block 同步安全。

## 1. 从像素公式开始，先确定合成顺序

对像素位置 p 和投影中心 μ，令 d=p−μ，G.6 给出 `G(p)=exp(−0.5 dᵀΣ⁻¹d)`。本课的覆盖 Alpha 定义为 `a=min(0.99,opacity·G)`，若 G 的指数小于 −4.5（3σ 椭圆外）或 a<1/255，则忽略该项。

0.99 上限避免单个元素把透射率直接压成零；1/255 与 3σ 是效率/近似选择，不是物理常数。opacity 是该高斯的峰值 Alpha 参数，不是 G.1 的单位长度密度；同样使用前到后递推，不代表两个表示在物理意义上完全相同。

设到达当前高斯前剩余透射率 T，已积累预乘颜色 C，按深度由近到远更新：

```text
weight = T * a
Cnext  = C + weight * RGB
Tnext  = T * (1−a)
```

初始 C=0,T=1，最终输出 A=1−T。颜色已经乘过贡献权重，消费者应使用 `C + T*background`，不能再把 C 乘一次 A，否则边缘会变暗。这里输出的是线性空间颜色；sRGB 编码只在最终显示阶段进行，不能在 sRGB 空间直接做这条加法。

顺序会影响结果。例如近红与远蓝都 a=.5：红贡献 .5，蓝贡献 .25；交换顺序就交换这两个权重。因此 3DGS 不是天然的顺序无关透明 OIT。即使普通光栅 BlendState 能执行相似的 Alpha 公式，也不会替我们完成高斯投影、tile 候选、确定排序与分批参数复用。

## 2. 一个 block 对应 tile，一个线程对应像素

核的实际接口是：

```cpp
__global__ void splatKernel(
    const Projected* projected, const uint32_t* indices,
    const uint2* ranges, float4* out, float* depth,
    const float* mesh, Camera camera);
```

`projected` 是每高斯投影参数；`indices` 是 G.7 排好序的高斯索引；`ranges[tile]` 给出 `[begin,end)`；`out` 是调用者分配的 width×height 行主序 `float4`；`depth` 可为空；`mesh` 可为空，存在时必须是相同相机下的线性 Z，不能直接传 D3D 的非线性 depth buffer 数值。Camera 按值传入，不依赖一个会被 CPU 立刻修改的宿主指针。

grid 是 `(ceil(width/16),ceil(height/16))`，block 是 `(16,16)`。`lane=threadIdx.y*16+threadIdx.x` 唯一标识 0..255 线程；像素坐标等于 block 起点加本地坐标。每个线程只写一个 RGBA，没有 framebuffer 原子竞争。

如果每个像素都从 global memory 读取同一批候选参数，会重复读取。我们每次让 256 个线程各载入一个候选到 `__shared__ SharedGaussian shared[256]`，然后 block 中全部像素复用它们。SharedGaussian 只保留中心、z、三个 conic 元素、RGB 和 opacity，共 10 个 float=40 bytes，整个批次 10,240 bytes。

这是静态分配大小，不是实测 bandwidth 或 achieved occupancy。shared memory 可减少 global 重复读取，但也占用每 SM 的资源；实际收益还取决于缓存、寄存器、候选数量、活跃 warp 和分支。不能仅凭用了 shared 就宣称一定更快。

## 3. 早停与 barrier：为什么不能直接 return

T<1e-4 时，这个像素剩余未被遮挡的比例很小，可以停止累积。本课把线程标为 `done=true`。注意“某像素无需继续合成”不等于“该线程可以退出 block”。它仍可能需要帮助加载下一批高斯，也必须参加后面的 barrier。

循环开头执行 `__syncthreads_count(done)`。它既同步 block，也统计 done 为真的线程数；只有计数等于 256 时，所有线程才共同 break。否则各线程按 lane 加载最多一个候选，再 `__syncthreads()` 保证共享写入对所有线程可见；没有完成的像素按顺序消费这一批；下一轮计数 barrier 保证大家读完之后才可覆盖 shared。

边缘 tile 的无效像素从一开始就 done，但不能提前 return。131×97 验证专门覆盖最后一行/列不满 16 的情况。这样 sanitizer 才能实际走到不完整 tile 的同步路径，而不是只验证每边恰好整除 16 的图像。

T 的早停只界定剩余权重。若 RGB 可为很大的 HDR 值，绝对颜色误差还取决于剩余颜色上界；因此不能无条件承诺“误差永远小于 1e-4”。本课以实际 CPU/GPU误差验证实现一致性，并公开近似阈值。

## 4. 深度、网格遮挡与它的简化边界

可选输出深度为 `sum(weight*z)/sum(weight)`，空像素写 +inf。这是有贡献高斯均值深度的归一化加权平均，不是最近表面深度，也不是能无条件写入硬件深度缓冲的几何表面。

若输入 meshLinearZ，则跳过 `gaussianCenterZ>=meshLinearZ[pixel]` 的高斯。这个契约能让前方网格遮住后方高斯，但只按中心深度判断：跨越网格表面的巨大高斯不能得到精确体积裁切。G.10 集成必须保留这个说明，不能把演示遮挡称为完整物理混合渲染。

所有权与同步由 `Renderer::render(Camera,float4*,float*,const float*,cudaStream_t)` 管理：内部资源属于 Renderer，输出/mesh 由外部持有；所有核排进调用者的 stream。当前教学实现返回前同步，因为需要计数检查和时间统计。G.10 仍需在 CUDA/D3D12 边界等待和通知 External Fence；CPU 返回保证不能代替跨 API 资源状态与队列所有权契约。

## 5. CPU 参考、打乱输入和内存验证

从仓库根运行：

```powershell
& learning/sandbox/d3d12/neural-rendering/tests/gaussian/verify.ps1 -Build -Sanitizer
```

独立 CPU 合成按 tile 列表逐像素循环，没有 CUDA shared 组织。128×96、128 高斯测试得到线性 RGBA 最大绝对差 `1.788139343e-7`。前方 mesh 遮挡左半图时最大差同为 `1.788139343e-7`，被遮挡区域 Alpha 全零。输入 shuffle 后 GPU 图像逐 bit 一致，空场景完全透明；重复 id、非刚体相机、NaN 内参和引用预算超限均显式拒绝。

详细结果：[splat.json](../../sandbox/d3d12/neural-rendering/results/g8/splat.json)、[memcheck.log](../../sandbox/d3d12/neural-rendering/results/g8/memcheck.log)、[synccheck.log](../../sandbox/d3d12/neural-rendering/results/g8/synccheck.log)。Sanitizer 使用 `--check-only` 跑功能/失败路径/边缘 tile，不会把插桩后的慢时间覆盖正式性能报告。两种工具都以 `--error-exitcode 99` 将真实错误变成脚本失败。

100,000 高斯的正式时序包含预热，640×360 的 splat 约 0.169 ms，完整阶段详见 G.7。低分辨率、密集候选、较高遮挡导致早停较多；不能把此数字直接外推为 1080p 大场景帧率。

## 6. Nsight Compute 的真实状态

2026-10-22 已实际请求 LaunchStats、Occupancy、MemoryWorkloadAnalysis、SourceCounters，驱动返回 `ERR_NVGPUCTRPERM`，日志保留在 [ncu.csv](../../sandbox/d3d12/neural-rendering/results/g8/ncu.csv)。用户随后明确授权本轮跳过硬件计数器分析。

因此本节保留了真实 CUDA event 计时和两类 sanitizer 验收，**没有宣称测得 shared 吞吐、achieved occupancy、分支效率或访存瓶颈**。10 KiB shared/256 线程来自代码定义。未来权限可用后执行 `verify.ps1 -Counters` 即可采集；不需要为了完成课程擅自修改驱动全局权限。

自测答案：已 done 的线程仍参加 barrier，是因为 block 协作加载和共享数组复用需要全体同步；bitwise shuffle 一致来自唯一 stable id 与稳定排序，不能归因于 Alpha 公式具有交换律；预乘颜色直接与剩余透射率乘背景相加，不能重复乘 Alpha。

商业渲染器可能进一步压缩特征、改善大 tile 列表调度、融合阶段或做更精细深度处理。本课重点是可验证的投影→分桶→稳定排序→共享内存前到后合成，尚未实现完整可微反向与资产训练；训练与格式责任在 G.9。
