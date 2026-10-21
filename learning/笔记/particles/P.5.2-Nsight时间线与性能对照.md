# P.5.2 Nsight Systems 时间线与单/双缓冲性能对照

## 一句话目标

学会用 Nsight Systems 把“代码结构上允许并行”和“GPU 时间线上真的重叠”区分开，并用同等模拟工作量对照单缓冲与双缓冲的代价。

## 1. 先建立直觉：像看渲染帧调度器

把一帧想成游戏引擎提交的一组工作：

```text
CPU 线程：记录命令、提交 D3D12、向 CUDA stream 排 wait/kernel/signal
D3D12 GPU：ExecuteCommandLists / DrawInstanced
CUDA GPU：external wait / simulate_particle_soa / external signal
```

NVTX 是 CPU 线程上的“路标”，类似在 RenderDoc/Nsight 中给一段录制代码起名字；它本身不是 GPU 同步，也不延长或缩短 kernel。Nsight 的 CUDA activity 和 DX12 workload 才是 GPU 时间线上实际开始/结束的区间。

因此要回答两个不同问题：

1. **依赖是否允许重叠？** 看 Fence/Queue::Wait 是否只等待另一份 Resource。
2. **硬件是否真的重叠？** 看 CUDA kernel 区间与 `DX12_WORKLOAD` 区间是否有相交时间。

## 2. 为何必须有 NVTX，而不能只看函数耗时

`cudaLaunchKernel` 的 API 耗时是 CPU 把 kernel 放入 stream 的耗时，不是 kernel 在 GPU 上执行的耗时；`cudaStreamSynchronize` 则可能把此前积累的大量 GPU 工作全部算进一个 CPU 调用。D3D12 的 `ExecuteCommandLists` 也主要表示提交调用，真正的 GPU workload 要看 DX12 GPU activity。

本节在两个程序中加入了同样结构的标记：

```text
P5.2.single.* / P5.2.double.*
  frame                 整个一帧的 CPU 提交范围
  d3d12_record_submit  Queue::Wait、录制、Execute、D3D12 signal
  cuda_schedule        调用 schedule_cuda_update 的外层范围
  cuda_update_enqueue  CUDA stream wait、kernel launch、signal
  present               Present 调用
```

实现使用 `nvtxRangePushA/Pop`，并提供一个详细注释的 RAII 包装器：

```cpp
struct NvtxRange {
  explicit NvtxRange(const char* name) noexcept { nvtxRangePushA(name); }
  ~NvtxRange() noexcept { nvtxRangePop(); }
  NvtxRange(const NvtxRange&) = delete;
  NvtxRange& operator=(const NvtxRange&) = delete;
};
```

RAII 的作用只是保证区间成对结束；它不替代 CUDA external semaphore，也不替代 D3D12 resource barrier。

代码位置：

- 单缓冲：`learning/sandbox/particles/p04-p05-renderer/d3d12_cuda_particles.cu:30`、`:699`、`:734`
- 双缓冲：`learning/sandbox/particles/p04-p05-renderer/d3d12_cuda_particles_double_buffered.cu:29`、`:758`、`:808`

## 3. 第一个陷阱：VSync 会掩盖真正的工作量

默认 `Present(1, 0)` 会等待垂直同步。120 帧采集的 NVTX 结果如下：

| 模式 | frame 中位数 | frame 总范围 | CUDA simulate GPU 总时长 | DX12 workload 总时长 |
|---|---:|---:|---:|---:|
| 单缓冲，VSync=1 | 16.682 ms | 1.963 s | 0.1256 ms | 0.9437 ms |
| 双缓冲，VSync=1 | 16.660 ms | 1.966 s | 0.1431 ms | 0.9719 ms |

两者都被 60 Hz 的 Present 节奏主导；不能用约 1.96 s 的总时间断言双缓冲更快。代码保留默认 VSync 以方便观察粒子，同时加入：

```powershell
--vsync 0
```

它只把 `Present` 的 sync interval 设为 0，不改变 GPU 依赖图。

## 4. 第二个陷阱：无 VSync 时实时 accumulator 工作量不固定

如果直接用 `--vsync 0`，CPU 很快提交完 120 帧，墙钟时间只推进很少，实时 accumulator 可能只产生几个固定子步。此时单/双缓冲做的积分工作不同，比较没有意义。

因此增加了基准专用参数：

```powershell
--fixed-substeps 256
```

非负值表示每帧强制提交 256 个 `dt=1/120 s` 子步；不提供该参数时仍使用原来的墙钟 accumulator。双缓冲仍会让两份状态分别追赶目标，所以它的完整模拟工作约为单缓冲两倍，这个代价正是我们要测量的内容。

## 5. 可复现实验命令

编译（两个程序都必须链接 D3D12/Win32 库，并面向本机 `sm_120`）：

```powershell
cd C:\xf\Cuda\accelerated-computing-hub\learning\sandbox
.\build.ps1 particles\p04-p05-renderer\d3d12_cuda_particles.cu `
  -Libraries dxgi,d3d12,user32,d3dcompiler -NoRun
.\build.ps1 particles\p04-p05-renderer\d3d12_cuda_particles_double_buffered.cu `
  -Libraries dxgi,d3d12,user32,d3dcompiler -NoRun
```

Nsight Systems 2026.3.1 采集（`--sample=none` 避免 CPU 采样干扰；`--export=sqlite` 便于脚本查询；`--dx12-gpu-workload=individual` 记录每个 DX12 workload）：

```powershell
$nsys = 'C:\Program Files\NVIDIA Corporation\Nsight Systems 2026.3.1\target-windows-x64\nsys.exe'

& $nsys profile `
  --trace=cuda,dx12,nvtx `
  --dx12-gpu-workload=individual `
  --cuda-event-trace=true `
  --stats=true --sample=none --export=sqlite --force-overwrite=true `
  -o p52_single_fixed256 `
  .\particles\p04-p05-renderer\d3d12_cuda_particles.exe --frames 120 --vsync 0 --fixed-substeps 256

& $nsys profile `
  --trace=cuda,dx12,nvtx `
  --dx12-gpu-workload=individual `
  --cuda-event-trace=true `
  --stats=true --sample=none --export=sqlite --force-overwrite=true `
  -o p52_double_fixed256 `
  .\particles\p04-p05-renderer\d3d12_cuda_particles_double_buffered.exe --frames 120 --vsync 0 --fixed-substeps 256
```

每次采集会生成 `.nsys-rep`（GUI 时间线）和 `.sqlite`（可查询数据）。本机没有管理员权限时，Nsight 会提示 CPU context-switch trace 被禁用；这不影响本节的 CUDA/DX12/NVTX activity，但不能据此分析操作系统线程切换。

## 6. RTX 5070 真机结果

测试条件：RTX 5070 / `sm_120`，120 帧，VSync=0，每帧固定 256 子步，Nsight Systems 2026.3.1。GPU activity 时间来自报告中的 `CUPTI_ACTIVITY_KIND_KERNEL` 与 `DX12_WORKLOAD`，单位原始为纳秒。

| 指标 | 单缓冲 | 双缓冲 | 解读 |
|---|---:|---:|---|
| 目标 step | 30,720 | 30,720 | 两者逻辑模拟时刻相同 |
| 实际积分子步 | 30,720 | 61,184 | 双缓冲两份状态各自追赶，约 1.99× |
| `simulate_particle_soa` kernel 数 | 120 | 120 | 每帧一个 kernel；双缓冲不是 kernel 数翻倍，而是每次循环子步更多 |
| simulate GPU 总时长 | 1.5869 ms | 3.0364 ms | 约 1.91×，与额外积分工作一致 |
| simulate kernel 中位数 | 12.128 µs | 23.440 µs | 双缓冲单次 kernel 更长 |
| DX12 workload 总时长 | 0.9302 ms | 0.9174 ms | 绘制工作量基本相同 |
| DX12 workload 中位数 | 7.616 µs | 7.520 µs | 不是主要差异来源 |
| CUDA/DX12 相交区间 | 0 对 | 0 对 | 本次小 workload 上未观察到硬件重叠 |
| NVTX frame 中位数 | 255.594 µs | 230.904 µs | CPU 提交区间受 WDDM/启动顺序影响，不能单独代表 GPU 吞吐 |

报告中还能看到：

- 单缓冲有 120 次 external wait、121 次 external signal；双缓冲有 119 次 wait、121 次 signal。双缓冲第一帧更新从未被 D3D12 读取的 Buffer，因此不需要等待其 `d3d_done_value=0`。
- 单缓冲的 `simulate` 区间总和 1.5869 ms，双缓冲为 3.0364 ms；D3D12 workload 仍约 0.92 ms。
- 用区间相交判断时，固定基准的所有 CUDA kernel 与 DX12 workload 均没有时间重叠；时间线上更像“一个完成后另一个开始”，而不是并行执行。

这里的“0 对”只描述这个粒子数量、kernel 粒度、驱动和 WDDM 调度条件。它不能推出 RTX 5070 永远不能让 CUDA 与图形 workload 重叠；换成更大的粒子系统、不同队列/引擎占用或不同驱动，结果可能改变。

## 7. CPU 墙钟对照为什么只能作为辅助

在未启用 VSync 的固定 256 子步模式下，重复运行 5 次得到（包含进程创建和 D3D12 初始化）：

```text
single: 696.18, 489.86, 482.56, 484.82, 487.16 ms
double: 492.37, 489.25, 509.67, 494.70, 472.88 ms
```

第一次单缓冲明显是冷启动离群值；去掉冷启动后，中位数约为单缓冲 484.82 ms、双缓冲 492.37 ms，差异约 1.6%，落在 WDDM/窗口调度噪声量级。这个结果与 GPU activity 的结论一致：双缓冲没有获得可观测的硬件重叠，却承担了约两倍积分工作，所以不能宣称性能提升。

更可靠的做法是：

1. 用 Nsight GPU activity 统计 kernel/DX12 实际区间；
2. 用多个重复样本报告中位数或置信区间；
3. 关闭 VSync，并固定每帧工作量；
4. 另行记录显存占用和实际帧率，不把 Present 等待算成 GPU 算法速度。

## 8. 如何阅读 `.sqlite`

最关键的查询关系是：

```sql
-- CUDA kernel 的 GPU 起止时间
SELECT start, end, end - start AS duration_ns, demangledName
FROM CUPTI_ACTIVITY_KIND_KERNEL
ORDER BY start;

-- D3D12 GPU workload 的起止时间
SELECT start, end, end - start AS duration_ns, nameId
FROM DX12_WORKLOAD
ORDER BY start;

-- 把 nameId/demangledName 映射到可读字符串
SELECT id, value FROM StringIds;
```

两个区间 `[a.start, a.end)` 与 `[b.start, b.end)` 相交，当且仅当：

```text
a.start < b.end && b.start < a.end
```

相交长度为：

```text
min(a.end, b.end) - max(a.start, b.start)
```

这比只看 NVTX `cuda_schedule` 和 `d3d12_record_submit` 更严格，因为后两者是 CPU 提交区间，不是 GPU 执行区间。

## 9. 结论边界

本节已经实测证明：

- NVTX 能把单/双缓冲的 CPU 提交路径对齐到 Nsight 时间线。
- VSync 会完全掩盖这个小 demo 的工作量差异；固定子步模式能构造可复现的公平基准。
- 双缓冲确实消除了同一粒子 Resource 的直接依赖，但在本机这组小 workload 上没有观察到 CUDA kernel 与 DX12 workload 的硬件重叠。
- 双缓冲为两份状态执行了约 1.99× 的积分子步，simulate GPU 时间约 1.91×。

本节没有证明：

- 所有 GPU/驱动/队列组合都不能重叠；
- 双缓冲在更大粒子系统上一定更慢；
- CPU NVTX 区间中位数可以替代 GPU activity 作为性能结论。

## 10. 文件

- 单缓冲程序：`learning/sandbox/particles/p04-p05-renderer/d3d12_cuda_particles.cu`
- 双缓冲程序：`learning/sandbox/particles/p04-p05-renderer/d3d12_cuda_particles_double_buffered.cu`
- 单缓冲报告：[p52_single_fixed256.nsys-rep](../../sandbox/particles/p04-p05-renderer/results/history/p52_single_fixed256.nsys-rep) / `p52_single_fixed256.sqlite`
- 双缓冲报告：[p52_double_fixed256.nsys-rep](../../sandbox/particles/p04-p05-renderer/results/history/p52_double_fixed256.nsys-rep) / `p52_double_fixed256.sqlite`
- Nsight Systems 官方文档：https://docs.nvidia.com/nsight-systems/
- NVTX 官方说明：https://docs.nvidia.com/cuda/profiler-users-guide/index.html#nvtx

## 自测题

1. 为什么 `cudaLaunchKernel` 的 API 时间和 `simulate_particle_soa` 的 GPU 时间必须分开看？
2. 为什么无 VSync 的实时 accumulator 不能直接拿来比较单缓冲和双缓冲？`--fixed-substeps 256` 解决了哪一个变量？
3. 本次报告显示 CUDA/DX12 相交区间为 0 对，这是否证明双缓冲设计无效？还需要哪些条件才可能看到重叠？
