# P.4.2 D3D12 静态 SoA 粒子

## 一句话目标

先不让 CUDA 更新粒子，只验证 D3D12 能否把最终规划的 SoA Buffer 正确解释成 4096 个圆形粒子。下一节只需把这块静态 Buffer 换成 CUDA External Memory 动态写入，而不必重写绘制管线。

## 直觉：先搭好“显存数据的显示器”

可以把 CUDA 看成粒子数据的生产者，把 D3D12 看成消费者：

```text
本节：CPU 初始化 SoA → D3D12 Vertex Shader 读取 → Rasterizer/Pixel Shader → 窗口
下节：CUDA kernel 更新 SoA → D3D12 Vertex Shader 读取 → Rasterizer/Pixel Shader → 窗口
```

本节没有 CUDA 粒子 kernel，只有 CUDA/DXGI LUID 配对。它的价值是单独验证“消费者”一侧：如果下一节动态粒子出错，就能更有把握地把问题定位到 External Memory、CUDA kernel 或跨 API Fence，而不是同时怀疑 HLSL、PSO 和绘制命令。

## 1. 单 Buffer、三段 SoA、两个 SRV

GPU 上只创建一块连续的 `ID3D12Resource` Buffer：

```text
float4 element index

0                 N                2N                3N
| position[N]     | velocity[N]    | color[N]        |
| D3D12 SRV t0    | 暂不渲染       | D3D12 SRV t1    |
```

本节 `N = 4096`，每个 `float4` 为 16 bytes，所以总大小为：

```text
4096 × 3 × 16 = 196,608 bytes
```

两个 SRV 都把元素解释为 `float4`，但窗口不同：

```cpp
// position：查看 Buffer 的第 [0, N) 个 float4
FirstElement = 0;
NumElements = N;
StructureByteStride = 16;

// color：查看 Buffer 的第 [2N, 3N) 个 float4
FirstElement = 2 * N;
NumElements = N;
StructureByteStride = 16;
```

`FirstElement` 的单位是结构化元素，不是 byte。因此 color 写 `2*N`，不是 `2*N*16`。

## 2. Root Signature：着色器资源接口契约

HLSL 声明：

```hlsl
StructuredBuffer<float4> gPositions : register(t0);
StructuredBuffer<float4> gColors    : register(t1);
```

CPU 端创建一个连续 SRV Range：

```cpp
RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
NumDescriptors = 2;
BaseShaderRegister = 0;
```

它表示从 `t0` 开始连续提供两个 SRV，即 `t0`、`t1`。随后把该 Range 放入一个 Descriptor Table Root Parameter，并限制为 Vertex Shader 可见。

三层对象不要混淆：

- Root Signature：声明 shader 可以接收什么资源接口。
- Descriptor Heap：实际存放 SRV 描述符。
- Root Descriptor Table：逐次录制时，让某个根参数指向 heap 中的具体起点。

类似 C++：Root Signature 像函数签名，Descriptor Heap 像保存真实对象地址的表，SetGraphicsRootDescriptorTable 像本次调用传入实参。

## 3. HLSL 为什么不需要 Vertex Buffer

一次调用：

```cpp
DrawInstanced(
    6,      // 每个实例 6 个顶点，即两个三角形
    4096,   // 4096 个粒子实例
    0,
    0);
```

Vertex Shader 自动收到两个系统值：

- `SV_VertexID`：当前实例内选择 0 到 5 的 quad 角点。
- `SV_InstanceID`：选择第几个粒子，即索引 position/color SoA。

因此无需为所有粒子复制 quad 顶点。六个局部角点直接写在 HLSL 常量数组中，粒子中心和颜色才从 Buffer 读取。

完整映射为：

```text
SV_InstanceID
  ├─ gPositions[instanceId] → 中心、深度、半径
  └─ gColors[instanceId]    → 颜色

SV_VertexID → 六个局部角点之一 → 把粒子中心扩展成 quad
```

## 4. quad 如何变成圆

Vertex Shader 还向 Pixel Shader 插值局部坐标 `localPosition ∈ [-1, 1]²`。Pixel Shader 计算：

```hlsl
float radiusSquared = dot(localPosition, localPosition);
clip(1.0 - radiusSquared);
```

若 `x²+y² > 1`，则 `1-(x²+y²) < 0`，`clip` 丢弃像素；留下的区域就是单位圆。

注意：数学上的 NDC 圆不一定是屏幕像素中的圆。1280×720 窗口里：

```text
1 NDC-x = 640 pixels
1 NDC-y = 360 pixels
```

所以 x 半径必须乘 `height/width = 720/1280`：

```text
xPixels = radius × (height/width) × width/2
        = radius × height/2
        = yPixels
```

本节窗口固定，HLSL 使用编译期常量。以后支持 Resize 时，应通过 Constant Buffer 或 Root Constants 传入当前 viewport 尺寸。

## 5. Graphics PSO 固化了什么

`ID3D12PipelineState` 把一次绘制所需的大部分状态预先组合：

- 编译后的 VS/PS bytecode。
- Root Signature。
- 空 Input Layout。
- Triangle primitive topology type。
- Rasterizer：solid、关闭 culling。
- Blend：关闭，像素直接覆盖 Render Target。
- Depth/Stencil：关闭，本节没有深度缓冲。
- RTV 格式：`DXGI_FORMAT_R8G8B8A8_UNORM`。
- Sample count：1，即无 MSAA。

D3D12 不鼓励像旧 API 那样在 draw 前零散切换大量隐式状态；PSO 让驱动能提前验证、编译和缓存相互兼容的管线组合。

## 6. 为什么要 Default Heap + Upload Heap

Default Heap 适合 GPU 读取，但 CPU 不能直接 Map；Upload Heap 可以由 CPU Map 写入，但通常不是长期高带宽读取的最终位置。因此初始化链条是：

```text
CPU vector<float4>
  → Map/ memcpy 到 Upload Heap
  → CopyBufferRegion 到 Default Heap（COPY_DEST）
  → ResourceBarrier
  → Default Heap（NON_PIXEL_SHADER_RESOURCE）
```

上传结束后 CPU 等 Fence 一次，确保临时 Upload Buffer 可以安全销毁。这个等待不在逐帧循环内。

这里的 Resource Barrier 只管理 D3D12 资源使用状态；它不是 CUDA/D3D12 的跨 API 所有权交接。下一节仍需 External Semaphore/Fence 明确规定谁先写、谁后读。

## 7. 每帧真正提交的命令

```text
等待当前 FrameResources 可复用
→ Reset allocator/list
→ Back Buffer: PRESENT → RENDER_TARGET
→ ClearRenderTargetView
→ 绑定 viewport/scissor、Root Signature、SRV heap/table
→ IASetPrimitiveTopology(TRIANGLELIST)
→ DrawInstanced(6, 4096, 0, 0)
→ Back Buffer: RENDER_TARGET → PRESENT
→ ExecuteCommandLists
→ Present
→ Queue Signal 帧资源 Fence
```

## 8. 代码与运行

- C++/D3D12 主程序：`learning/sandbox/particles/p04-p05-renderer/d3d12_static_particles.cu`
- HLSL：`learning/sandbox/particles/p04-p05-renderer/d3d12_static_particles.hlsl`
- 实拍结果：`learning/sandbox/particles/p04-p05-renderer/results/history/d3d12_static_particles_validation.png`

```powershell
.\learning\sandbox\build.ps1 `
  -Source .\learning\sandbox\particles\p04-p05-renderer\d3d12_static_particles.cu `
  -Libraries dxgi,d3d12,user32,d3dcompiler
```

默认运行 180 帧后退出。持续观察：

```powershell
.\learning\sandbox\particles\p04-p05-renderer\d3d12_static_particles.exe --frames 0
```

RTX 5070 / sm_120 真机输出：

```text
matched CUDA/D3D12 adapter: NVIDIA GeForce RTX 5070
uploaded static SoA buffer: 196608 bytes, 4096 particles
rendered frames: 180
frame-resource CPU waits: 176
particles per frame: 4096
D3D12 static SoA particles: PASS
```

`frame-resource CPU waits` 会随桌面合成、VSync 和运行时机略有变化；它不是渲染错误计数。

## 9. 官方资料

- [D3D12 Root Signatures](https://learn.microsoft.com/windows/win32/direct3d12/root-signatures)
- [D3D12 Pipeline State](https://learn.microsoft.com/windows/win32/direct3d12/managing-graphics-pipeline-state-in-direct3d-12)
- [ID3D12GraphicsCommandList::DrawInstanced](https://learn.microsoft.com/windows/win32/api/d3d12/nf-d3d12-id3d12graphicscommandlist-drawinstanced)
- [D3DCompileFromFile](https://learn.microsoft.com/windows/win32/api/d3dcompiler/nf-d3dcompiler-d3dcompilefromfile)

## 自测题

1. color SRV 为什么使用 `FirstElement = 2*N`，而不是 `2*N*16`？
2. 既然没有 Vertex Buffer，4096 个粒子的几何形状和粒子索引分别从哪里来？
3. 为什么 `ResourceBarrier` 不能替代下一节的 CUDA External Semaphore/Fence？
