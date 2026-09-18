# P.4.3 CUDA + D3D12 动态粒子

## 一句话目标

让 CUDA kernel 每帧直接更新 D3D12 正在渲染的同一块 SoA 显存，并通过 shared timeline Fence 在 GPU 端完成所有权交接，CUDA 与 D3D12 中间不做 CPU 阻塞等待。

## 直觉：同一块场地，两支队伍交接

共享 Buffer 像同一块粒子训练场：

- CUDA 队伍负责写入下一时刻的 position/velocity。
- D3D12 队伍负责读取 position/color 并绘制。
- External Memory 保证双方进入的是同一块场地。
- External Fence 像号码不断增加的交接牌，保证一方离场后另一方才进入。
- Resource Barrier 像 D3D12 队伍内部切换场地用途的标牌。

External Memory 解决“是不是同一块内存”；External Fence 解决“谁先谁后”；Resource Barrier 解决“D3D12 接下来怎样使用”。三者不是同一机制。

## 1. SoA allocation 没有发生逐帧复制

布局继续保持：

```text
float4 element index

0                 N                 2N                3N
| position[N]     | velocity[N]     | color[N]        |
| CUDA 读写       | CUDA 读写       | CUDA 初始化     |
| D3D12 SRV t0    | 无 D3D12 view   | D3D12 SRV t1    |
```

`N=4096`，有效数据大小：

```text
4096 × 3 × sizeof(float4)
= 4096 × 3 × 16
= 196,608 bytes
```

D3D12 和 CUDA 看到的是同一 allocation：

```text
ID3D12Resource particle_buffer
             │
             ├─ D3D12 SRV t0/t1 读取
             │
             └─ shared NT handle
                    ↓ import
               cudaExternalMemory_t
                    ↓ map buffer
               float4* cuda_particle_base
```

不存在下面这种逐帧上传：

```text
CUDA 私有 Buffer → cudaMemcpy → D3D12 私有 Buffer
```

## 2. D3D12 shared Buffer 的创建

核心参数：

```cpp
CreateCommittedResource(
    &defaultHeap,
    D3D12_HEAP_FLAG_SHARED,
    &bufferDescription,
    D3D12_RESOURCE_STATE_COMMON,
    ...);
```

这里有两个容易混淆的 flags：

- `D3D12_HEAP_FLAG_SHARED`：allocation 可以导出 shared handle。
- `D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS`：资源允许 GPU 写用途；它不是共享开关。

初始状态使用 `COMMON`，作为 CUDA 获得资源时的 D3D12 侧交接状态。

## 3. D3D12 Resource 导入 CUDA

第一步，导出 Win32 shared handle：

```cpp
device->CreateSharedHandle(
    particleBuffer,
    nullptr,
    GENERIC_ALL,
    nullptr,
    &memoryHandle);
```

第二步，描述并导入 External Memory：

```cpp
cudaExternalMemoryHandleDesc desc{};
desc.type = cudaExternalMemoryHandleTypeD3D12Resource;
desc.handle.win32.handle = memoryHandle;
desc.size = allocation.SizeInBytes;
desc.flags = cudaExternalMemoryDedicated;

cudaImportExternalMemory(&externalMemory, &desc);
```

`desc.size` 使用 `GetResourceAllocationInfo` 返回的 allocation 大小，而不是想当然地使用有效数据大小。底层 allocation 可能按硬件粒度向上对齐。

第三步，只映射实际使用的数据范围：

```cpp
cudaExternalMemoryBufferDesc mapped{};
mapped.offset = 0;
mapped.size = 196608;

cudaExternalMemoryGetMappedBuffer(
    reinterpret_cast<void**>(&cudaBase),
    externalMemory,
    &mapped);
```

成功导入后即可关闭临时 Win32 handle。D3D12 Resource 与 CUDA External Memory 对象各自维护自己的生命周期引用；handle 本身不是之后逐帧访问的通道。

销毁时顺序为：

```text
确保 CUDA stream 已完成
→ cudaFree(mapped pointer)
→ cudaDestroyExternalMemory
→ 最后由 ComPtr 释放 ID3D12Resource
```

## 4. Shared D3D12 Fence 导入 CUDA

D3D12 创建可共享的 Fence：

```cpp
device->CreateFence(
    0,
    D3D12_FENCE_FLAG_SHARED,
    IID_PPV_ARGS(&sharedFence));
```

导出 shared handle 后，CUDA 将它导入成：

```cpp
cudaExternalSemaphoreHandleTypeD3D12Fence
```

虽然 CUDA API 名称是 External Semaphore，但它对应的是 D3D12 timeline Fence，携带一个 64-bit 单调 value，不是只能锁定/解锁的二值互斥量。

本例约定：

```text
奇数：CUDA 已写完，可以交给 D3D12
偶数：D3D12 已读完，可以交给 CUDA
```

## 5. 精确的单帧时间线

初始化：

```text
CUDA initialize kernel
→ CUDA signal Fence=1
```

第一帧和下一次模拟：

```text
D3D12 queue wait 1
→ particle Buffer: COMMON → NON_PIXEL_SHADER_RESOURCE
→ DrawInstanced 读取 position/color
→ particle Buffer: NON_PIXEL_SHADER_RESOURCE → COMMON
→ D3D12 signal 2

CUDA stream wait 2
→ simulate_particle_soa kernel
→ CUDA signal 3
```

下一帧：

```text
D3D12 queue wait 3
→ draw
→ D3D12 signal 4

CUDA stream wait 4
→ simulate
→ CUDA signal 5
```

因此 180 帧之后，最后一次帧内 CUDA signal 为 361；退出 flush 再由 D3D12 signal 362。

## 6. 为什么中间 CPU 等待为 0

CUDA 侧：

```cpp
cudaWaitExternalSemaphoresAsync(..., cudaStream);
kernel<<<..., cudaStream>>>(...);
cudaSignalExternalSemaphoresAsync(..., cudaStream);
```

D3D12 侧：

```cpp
commandQueue->Wait(sharedFence, cudaReadyValue);
commandQueue->ExecuteCommandLists(...);
commandQueue->Signal(sharedFence, d3d12DoneValue);
```

这些调用都是把依赖或工作排入 GPU 队列。CPU 负责提交，但不会停在 CUDA 与 D3D12 的交界处等待结果。

程序仍可能有两类 CPU 等待：

- 交换链 FrameResources 即将复用时，等待对应 allocator 的 D3D12 工作完成。
- 程序退出时，等待 CUDA stream 和 D3D12 queue 清空后安全析构资源。

因此“interop 中间等待为 0”不等于“整个程序的 CPU 永远不等待”。

## 7. Resource Barrier 与 External Fence 为什么都需要

每次 D3D12 使用 shared Buffer：

```text
COMMON
→ NON_PIXEL_SHADER_RESOURCE
→ DrawInstanced
→ COMMON
```

回到 `COMMON` 后 D3D12 才 signal 偶数完成值，CUDA 再 wait 这个值。

职责严格区分：

```text
External Fence：跨 CUDA/D3D12 的执行顺序与可见性
Resource Barrier：D3D12 内部的资源状态和访问方式
```

只做 Barrier：CUDA 不知道 D3D12 何时读完。

只做 Fence：跨 API 顺序正确，但 D3D12 仍缺少它要求的 SRV 使用状态转换。

## 8. CUDA kernel 与固定时间步

每个线程负责一个粒子：

```cpp
int index = blockIdx.x * blockDim.x + threadIdx.x;
```

SoA 指针：

```cpp
float4* positions  = base;
float4* velocities = base + N;
float4* colors     = base + 2 * N;
```

kernel 把一个粒子的 position/velocity 读入寄存器，执行若干个固定 `1/120 s` 子步，最后写回一次。粒子相互独立，所以无需原子操作或线程同步。

CPU 使用 `steady_clock + accumulator` 把不稳定的渲染帧时间转换成整数个固定子步，并限制单帧最多 8 个子步，避免窗口拖动或断点后的追赶风暴。

## 9. 真机验证

编译运行：

```powershell
.\learning\sandbox\build.ps1 `
  -Source .\learning\sandbox\particles\d3d12_cuda_particles.cu `
  -Libraries dxgi,d3d12,user32,d3dcompiler
```

RTX 5070 / sm_120 默认 180 帧结果：

```text
matched CUDA/D3D12 adapter: NVIDIA GeForce RTX 5070
shared SoA buffer: useful=196608 bytes, allocation=196608 bytes
rendered frames: 180
fixed simulation substeps (dt=1/120 s): 351
last completed shared fence value: 362
CUDA/D3D12 intermediate CPU waits: 0
frame-resource CPU waits: 176
CUDA + D3D12 dynamic particles: PASS
```

Memcheck：

```powershell
compute-sanitizer --tool memcheck --error-exitcode 1 `
  .\learning\sandbox\particles\d3d12_cuda_particles.exe --frames 30
```

结果：

```text
CUDA + D3D12 dynamic particles: PASS
ERROR SUMMARY: 0 errors
```

两张间隔实拍分别保存在：

- `learning/sandbox/particles/d3d12_cuda_particles_a.png`
- `learning/sandbox/particles/d3d12_cuda_particles_b.png`

## 10. 代码入口

- 动态粒子完整程序：`learning/sandbox/particles/d3d12_cuda_particles.cu`
- 复用的粒子 HLSL：`learning/sandbox/particles/d3d12_static_particles.hlsl`

## 11. 官方资料

- [CUDA Runtime API: External Resource Interoperability](https://docs.nvidia.com/cuda/cuda-runtime-api/group__CUDART__EXTRES__INTEROP.html)
- [CUDA C++ Programming Guide: External Resource Interoperability](https://docs.nvidia.com/cuda/cuda-c-programming-guide/index.html#external-resource-interoperability)
- [ID3D12Device::CreateSharedHandle](https://learn.microsoft.com/windows/win32/api/d3d12/nf-d3d12-id3d12device-createsharedhandle)
- [ID3D12CommandQueue::Wait](https://learn.microsoft.com/windows/win32/api/d3d12/nf-d3d12-id3d12commandqueue-wait)

## 自测题

1. 为什么 `cudaExternalMemoryHandleDesc::size` 使用 allocation 大小，而映射 Buffer 时使用有效数据大小？
2. 如果删掉 D3D12 的 `queue->Wait(cudaReadyValue)`，即使 CUDA 最终会 signal，仍可能发生什么错误？
3. 为什么 D3D12 必须在 signal“读取完成”之前把 particle Buffer 从 SRV 状态转回 `COMMON`？
