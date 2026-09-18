# P.5.1 双缓冲粒子流水线

## 一句话目标

用两份独立的 shared 粒子状态消除“CUDA 更新”和“D3D12 绘制”对同一 Resource 的读写冲突，使 D3D12 绘制 A 时 CUDA 可以推进 B，下一帧再交换角色。

## 1. 先区分两种“双缓冲”

程序现在有两套互相独立的轮换对象：

```text
SwapChain Back Buffer 0/1
用途：D3D12 当前渲染哪张最终窗口图像

Particle State Buffer A/B
用途：CUDA 当前更新哪份模拟状态、D3D12 当前读取哪份模拟状态
```

它们都恰好是两份，但 index 没有必然相等关系：

```cpp
frameIndex = swapChain->GetCurrentBackBufferIndex();
renderStateIndex = renderer.render_state_index;
```

把它们混成同一个 index 会把“显示系统何时轮换图像”和“模拟流水线何时交换状态”错误绑定在一起。

## 2. 单 Buffer 为什么不能重叠

P.4.3 只有一份粒子 Resource：

```text
D3D12 draw Buffer A
→ signal 读完
→ CUDA update Buffer A
→ signal 写完
→ 下一次 D3D12 draw Buffer A
```

D3D12 读取和 CUDA 写入同一个 allocation，必须严格串行。这不是调度器保守，而是真实的数据竞争约束。

## 3. 两份状态的角色交换

双缓冲后：

```text
帧 N：
  D3D12 draw A
  CUDA  update B

帧 N+1：
  D3D12 draw B
  CUDA  update A
```

每份状态都是独立的 D3D12 committed shared Resource：

```text
Particle A：position[N] | velocity[N] | color[N]
Particle B：position[N] | velocity[N] | color[N]
```

因此同一时刻可以满足：

```text
A：NON_PIXEL_SHADER_RESOURCE，由 D3D12 读取
B：COMMON，由 CUDA 写入
```

两项工作不访问同一 Resource，数据依赖图允许它们重叠。注意“允许重叠”不等于“硬件一定实际重叠”；后者还取决于 GPU 调度、engine、SM/带宽占用与工作大小。

## 4. 为什么要从一条 Fence 拆成两条

单 Buffer 版可以用一条 timeline，因为所有工作本来就严格交替：

```text
CUDA signal 1
→ D3D12 signal 2
→ CUDA signal 3
→ D3D12 signal 4
```

双缓冲中 CUDA 与 D3D12 可能并行完成。如果仍从两个独立队列 signal 同一条 timeline：

```text
D3D12 准备 signal 2，但 draw 较慢
CUDA   signal 3 先完成
```

timeline 的语义是完成较大的 value 代表此前 value 都已完成。让 3 先于 2 完成会破坏应用建立的总顺序；之后再 signal 较小值也不是可靠设计。

所以拆成两条单生产者 timeline：

```text
cuda_ready_fence
  唯一 signal 方：CUDA stream
  唯一 wait 方：D3D12 queue

d3d_done_fence
  唯一 signal 方：D3D12 queue
  唯一 wait 方：CUDA stream
```

每条 Fence 内部仍严格单调，但两条 Fence 之间不强行建立无意义的总完成顺序。

## 5. 每个 Buffer 单独记录进度

```cpp
struct SharedParticleState {
    ID3D12Resource* resource;
    cudaExternalMemory_t externalMemory;
    float4* cudaBase;

    uint64_t cudaReadyValue;
    uint64_t d3dDoneValue;
    uint64_t simulatedStep;
};
```

含义：

- `cudaReadyValue`：这份 Buffer 最近一次 CUDA 写完的时间点。
- `d3dDoneValue`：这份 Buffer 最近一次 D3D12 读完的时间点。
- `simulatedStep`：这份状态目前已经推进到第几个固定 `1/120 s` 子步。

D3D12 只等待即将绘制的 Buffer：

```cpp
queue->Wait(cudaReadyFence, renderState.cudaReadyValue);
```

CUDA 只等待即将覆盖的 Buffer：

```cpp
cudaWaitExternalSemaphoresAsync(
    d3dDoneSemaphore,
    updateState.d3dDoneValue,
    stream);
```

CUDA 不等待当前正在绘制的另一份 Buffer，所以交叉依赖不会把流水线重新串行化。

## 6. 为什么每份状态需要“追赶”多个子步

两份状态都从 step 0 初始化。为简化示意，假设进入帧 0 前目标已经增加
2 个固定子步，之后每帧再增加 2：

```text
初始：A=0，B=0

帧 0：draw A(0)，update B：0 → 2
帧 1：draw B(2)，update A：0 → 4
帧 2：draw A(4)，update B：2 → 6
帧 3：draw B(6)，update A：4 → 8
```

一份 Buffer 隔帧才更新一次，因此通常要执行约两帧累计的固定子步。kernel 仍然逐个执行 `dt=1/120 s`，不是把多个子步粗暴合成一个大 dt。

当前实现为了保证 CUDA 完全不读取 D3D12 正在绘制的 Resource，让 A/B 各自保存完整状态并独立追赶。因此会产生额外计算：

```text
全局目标模拟 step：351
两份 Buffer 实际执行的追赶子步总数：700
```

也就是接近两倍的积分工作。这是本教学实现用计算换取清晰资源所有权与并行条件的代价。

更接近产品的另一种设计是保留一份 CUDA-private 权威模拟状态，每帧只积分一次，再把渲染所需 position/color 写入两份轮换的共享输出 Buffer；这样不会重复完整物理计算，但多了一层“模拟状态”和“渲染输出”的布局设计。后续性能分析后再决定是否值得改造。

## 7. 一帧的完整依赖

假设当前 `render=A`、`update=B`：

```text
D3D12 queue：
  wait A.cudaReady
  → A: COMMON → SRV
  → DrawInstanced(A)
  → A: SRV → COMMON
  → signal d3dDone(A)

CUDA stream：
  wait B.d3dDone
  → simulate(B, targetStep - B.simulatedStep)
  → signal cudaReady(B)
```

帧末只交换 CPU 端角色 index：

```cpp
render_state_index = update_state_index;
```

数据没有被 CPU 交换或复制，变化的只是“下一帧哪个描述符表被绑定”。

## 8. SRV Descriptor Heap

四个连续描述符：

```text
slot 0：A position → t0
slot 1：A color    → t1
slot 2：B position → t0
slot 3：B color    → t1
```

绘制 B 时，Root Descriptor Table 的 GPU handle 向后偏移两个 descriptor：

```cpp
table.ptr += renderStateIndex * 2 * descriptorIncrement;
SetGraphicsRootDescriptorTable(0, table);
```

Root Signature 和 HLSL 完全不变；着色器仍然只看到 `t0/t1`，不知道背后当前绑定的是 A 还是 B。

## 9. 真机验证

编译：

```powershell
.\learning\sandbox\build.ps1 `
  -Source .\learning\sandbox\particles\d3d12_cuda_particles_double_buffered.cu `
  -Libraries dxgi,d3d12,user32,d3dcompiler
```

RTX 5070 / sm_120 默认 180 帧：

```text
double-buffered SoA: 2 x 196608 useful bytes, allocation=196608 bytes each
rendered frames: 180
target simulation step (dt=1/120 s): 351
executed catch-up substeps across both buffers: 700
maximum substeps in one buffer catch-up: 5
particle state 0: rendered=90, simulated_step=351, cuda_ready=181, d3d_done=179
particle state 1: rendered=90, simulated_step=349, cuda_ready=180, d3d_done=180
completed cuda-ready fence: 181
completed d3d-done fence: 181
CUDA/D3D12 intermediate CPU waits: 0
CUDA + D3D12 double-buffered particles: PASS
```

Memcheck 30 帧：

```text
CUDA + D3D12 double-buffered particles: PASS
ERROR SUMMARY: 0 errors
```

## 10. 重要结论边界

本节已经证明：

- 两份 Resource 的所有权和状态转换正确。
- 两条 timeline 没有死锁并保持单生产者单调性。
- A/B 各绘制一半帧并独立推进模拟 step。
- CUDA memcheck 没有发现越界访问。
- 依赖图允许当前 draw 与另一 Buffer 的 update 并行。

本节尚未证明：

- CUDA kernel 与 D3D12 draw 在硬件时间线上实际重叠了多少。
- 双缓冲是否比单 Buffer 更快。
- 额外一份显存和近两倍积分计算是否值得。

这些结论必须在 P.5.2 用 Nsight Systems 时间线和单/双缓冲对照测量，不能仅凭代码结构推断。

## 11. 文件

- 双缓冲完整程序：`learning/sandbox/particles/d3d12_cuda_particles_double_buffered.cu`
- 实拍：`learning/sandbox/particles/d3d12_cuda_particles_double_buffered.png`

## 自测题

1. 为什么双缓冲允许并行后，反而不适合继续让 CUDA 和 D3D12 signal 同一条 timeline Fence？
2. 为什么目标模拟 step 是 351，两份 Buffer 实际执行的追赶子步总数却接近 700？
3. 双缓冲已经消除了资源依赖，为什么仍不能直接断言性能一定提升？
