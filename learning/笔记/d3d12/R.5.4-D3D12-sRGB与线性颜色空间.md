# R.5.4 D3D12 sRGB 与线性颜色空间

## 1. 本节目标

建立下面这条正确的颜色链：

```text
sRGB 编码的颜色纹理字节
    -> SRGB SRV 自动解码 RGB
    -> Shader 在线性空间做乘法/光照
    -> Blend Unit 在线性空间做 Alpha Blend
    -> SRGB RTV 自动编码 RGB
    -> 8-bit 交换链 Back Buffer
    -> Present
```

本节只处理 SDR sRGB 传递函数。HDR、色域映射、显示器 ICC 配置和 tone mapping
是后续离屏 HDR/后处理课程的内容，不能把它们混称为“打开 sRGB”。

## 2. 直觉：文件数值不是光的能量

颜色纹理通常把人眼更敏感的暗部安排得更细，把亮部安排得更稀，这样 8 bit 能
获得更好的主观质量。因此颜色文件中的 `128/255≈0.502` 不是“50.2% 光能”。

按标准 sRGB 解码后：

```text
sRGB 编码值 128/255 = 0.501961
线性值                 ≈ 0.215861
```

游戏类比：sRGB 像磁盘/网络上的压缩表示，线性 RGB 像渲染器内部真正参与物理
计算的工作值。这里的“压缩”是传递函数的非均匀编码，不是 BC7/JPEG 那种减少
存储字节的编码压缩；两者是正交概念。

## 3. sRGB 是分段函数，不是简单 gamma 2.2

对归一化 sRGB 通道 `S`，解码到线性通道 `L`：

```text
S <= 0.04045:
    L = S / 12.92

S > 0.04045:
    L = ((S + 0.055) / 1.055)^2.4
```

反向编码：

```text
L <= 0.0031308:
    S = 12.92 * L

L > 0.0031308:
    S = 1.055 * L^(1/2.4) - 0.055
```

“gamma 2.2”可以帮助建立直觉，但不能拿 `pow(x, 2.2)` 当精确 sRGB 实现。本节
程序用上述标准曲线做 CPU 自检；真正采样和写回由 GPU 格式转换完成。

## 4. 为什么计算必须在线性空间

假设混合黑色和白色，各占 50%。在线性空间：

```text
linear = 0.0 * 0.5 + 1.0 * 0.5 = 0.5
sRGB encode(0.5) ≈ 0.735
```

如果直接混合 sRGB 编码数值：

```text
wrong = 0.0 * 0.5 + 1.0 * 0.5 = 0.5
sRGB decode(0.5) ≈ 0.214
```

后者只有正确线性能量的约 43%，所以会明显偏暗。光照、插值、滤波和透明混合
处理的是光能关系，应在近似线性的工作空间中完成。

## 5. 四个必须分开的对象

当前输入纹理链是：

```text
Resource 本体
    Format = DXGI_FORMAT_R8G8B8A8_TYPELESS
    作用：拥有 RGBA8 存储，不预先指定线性或 sRGB 解释

SRV 描述结构体
    Format = DXGI_FORMAT_R8G8B8A8_UNORM_SRGB
    作用：规定 Shader 读取时 RGB 执行 sRGB -> linear

SRV 描述符
    位于 shader-visible CBV/SRV/UAV Heap 的槽位 2
    作用：保存上述访问描述并引用 Resource

GPU Descriptor Handle
    指向槽位 2，作为 Descriptor Table 起点传给根参数 t0
```

`TYPELESS` 不是“纹理没有格式”，而是 Resource 暂不决定该格式族中的具体数值
解释。它仍有明确的通道数量和每像素字节数，也仍受兼容 view 格式规则约束。

创建 SRV 的真实接口是：

```cpp
void ID3D12Device::CreateShaderResourceView(
    ID3D12Resource* pResource,
    const D3D12_SHADER_RESOURCE_VIEW_DESC* pDesc,
    D3D12_CPU_DESCRIPTOR_HANDLE DestDescriptor);
```

- `pResource`：拥有纹理存储的 Resource。
- `pDesc`：Shader 如何解释该 Resource；本节格式为 `_UNORM_SRGB`。
- `DestDescriptor`：把描述符写入哪个 CPU 可寻址的 Heap 槽位。
- 返回值是 `void`；错误通常由 Debug Layer 报告，不能用 `HRESULT` 检查。

## 6. 输入端：SRGB SRV 做了什么

CPU 上传的是未经转换的 RGBA8 字节：

```text
CopyTextureRegion：只复制字节
ResourceBarrier：只改变允许的资源用途
Sampler：规定过滤、寻址和 LOD
SRGB SRV：规定 RGB 数值解释和读取转换
```

Shader 声明没有变化：

```hlsl
Texture2D<float4> gColorTexture : register(t0);
float4 sample = gColorTexture.Sample(gColorSampler, uv);
```

但是 `sample.rgb` 已经是线性值。不要再在 Shader 中 `pow(sample.rgb, 2.2)`，否则
会二次解码。`sample.a` 不经过 sRGB 曲线，仍是普通 UNORM 的 0..1 映射。

## 7. 输出端：交换链 Resource 与 RTV View

Flip Model 交换链保持：

```cpp
swap_chain_description.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
```

但对每张 Back Buffer 显式创建：

```cpp
D3D12_RENDER_TARGET_VIEW_DESC rtv{};
rtv.Format = DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;
rtv.ViewDimension = D3D12_RTV_DIMENSION_TEXTURE2D;
device->CreateRenderTargetView(backBuffer, &rtv, handle);
```

同时 PSO 必须声明实际绑定的 View 格式：

```cpp
pipeline_description.RTVFormats[0] =
    DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;
```

不能因为 Resource 是 `UNORM`，就让 PSO 继续声明 `UNORM`。PSO 校验的是输出阶段
所配合的 RTV 格式；Resource 本体和 View 是两层对象。

Microsoft 的颜色空间说明明确建议：sRGB 内容使用 `_SRGB` SRV 解码，输出使用
`_SRGB` RTV 编码。参考：

- <https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/converting-data-color-space>
- <https://learn.microsoft.com/en-us/windows/win32/direct3d10/d3d10-graphics-programming-guide-resources-data-conversion>

## 8. Alpha Blend 的正确管线

透明像素经过：

```text
纹理 RGB 字节 --SRGB SRV--> source.rgb（线性）
纹理 A 字节   --UNORM------> source.a（线性覆盖度）

RTV 旧 RGB    --解码-------> destination.rgb（线性）

output.rgb = source.rgb * source.a
           + destination.rgb * (1 - source.a)

output.rgb --SRGB RTV------> 编码后写入 Back Buffer
```

sRGB 曲线只作用于 RGB，不作用于 Alpha。Alpha 通常表示覆盖率、透明度或其他线性
权重；对 Alpha 做 gamma 解码会破坏混合公式。

### 8.1 当前示例为什么可以直接写 sRGB Back Buffer

当前示例没有线性 HDR 中间目标，而是让每个 Draw 直接写交换链 Back Buffer。
这条路径仍能得到正确的线性混合，因为绑定 `_SRGB` RTV 后，固定功能输出阶段会
围绕混合运算完成必要转换：

```text
Back Buffer 中已经保存的 destination（8-bit sRGB）
    -> 硬件解码成线性 destination.rgb

Pixel Shader 输出的 source.rgb（线性）
source.a（线性覆盖度）
    -> Blend Unit 在线性空间合成

线性 output.rgb
    -> 硬件编码成 sRGB
    -> 量化后写入 Back Buffer Resource
```

所以它不是拿两个 sRGB 编码值直接做：

```text
source_srgb * alpha + destination_srgb * (1-alpha)   // 错误理解
```

而是等价于：

```text
linear_source * alpha + linear_destination * (1-alpha)
```

但是，“数学上的颜色空间正确”不等于“这是完整渲染器最合适的架构”。每次 Draw
写回 Back Buffer 都会经历 `linear -> sRGB -> 8-bit 量化`；后面的透明 Draw 又
需要把已有 destination 解码回来。硬件转换本身不是主要问题，真正的限制是：

- Back Buffer 只有 8-bit 通道精度，连续叠加时中间结果会反复量化。
- 可保存范围通常只有 0..1，不能保留大于 1 的 HDR 光照值。
- Bloom、曝光、tone mapping 等后处理拿不到完整的场景线性 HDR 结果。
- 交换链 Back Buffer 同时承担场景工作缓冲和最终显示缓冲，Pass 边界不清晰。

当前课程采用这条路径，是为了只引入颜色空间转换本身，不在同一节同时加入离屏
Resource、额外 RTV/SRV、全屏三角形、后处理 PSO 和更多资源屏障。它是正确的
SDR 教学路径，但不是后续完整小型渲染器的最终颜色架构。

### 8.2 完整渲染器：先统一在线性 HDR 目标完成，再输出 sRGB

更完整的实时渲染器通常创建一个线性浮点离屏颜色 Resource，例如：

```cpp
DXGI_FORMAT_R16G16B16A16_FLOAT
```

场景阶段的流程是：

```text
sRGB Base Color / Emissive 纹理
    -> SRGB SRV 解码
    -> 线性材质参数与光照
    -> 不透明物体写入线性 HDR Render Target
    -> 透明物体也在线性 HDR Render Target 中混合
    -> Bloom、曝光等线性/HDR 后处理
```

直到所有场景颜色处理完成，才执行最终全屏输出 Pass：

```text
线性 HDR 场景颜色
    -> Tone Mapping：把 HDR 映射到可显示的 SDR 范围
    -> 可选颜色分级
    -> Pixel Shader 输出线性 SDR RGB
    -> SRGB RTV 做最后一次 linear -> sRGB 编码
    -> 交换链 Back Buffer
    -> Present
```

这样才是“等线性 RGB 统一处理完，再编码为 sRGB”的架构。它有三个关键收益：

1. 场景和透明合成的中间值保存在浮点线性空间，不反复落入 8-bit 存储。
2. 大于 1 的高亮能一直保留到 Bloom、曝光和 tone mapping 阶段。
3. 场景渲染目标与最终显示目标分离，后处理 Pass 和资源生命周期更加明确。

最终输出有两种合法实现，但只能选一种，不能重复编码：

```text
方案 A（课程后续采用）：
    Shader 输出线性 SDR
    + SRGB RTV 自动编码

方案 B：
    Shader 手动编码为 sRGB
    + 普通 UNORM RTV 原样量化写入
```

如果 Shader 已经手动编码，却仍绑定 SRGB RTV，就会发生二次编码；如果 Shader
输出线性值，却绑定普通 UNORM RTV，Back Buffer 中会错误保存未经编码的线性值。

这套离屏架构将在阶段 F.2“离屏渲染与全屏后处理框架”中真正实现。本节先把它
作为明确的后续边界，不把当前直接写交换链的简化方案描述成生产渲染器终点。

### 8.3 术语纠正：RTV 不保存颜色

“把颜色编码到 RTV 中”是方便但不严谨的说法。准确关系是：

```text
Back Buffer Resource
    = 真正拥有像素存储

RTV 描述符
    = 规定 Output Merger 如何把该 Resource 当作渲染目标访问

SRGB RTV 的格式
    = 规定线性 RGB 写入 Resource 前执行 sRGB 编码
```

因此应说：

```text
GPU 按 SRGB RTV 描述的访问规则，
把线性输出编码后写入 RTV 所引用的 Back Buffer Resource。
```

RTV 自身只是描述符堆中的一条描述记录，不拥有任何颜色像素。

## 9. 哪些纹理使用 sRGB

| 纹理内容 | 常见 View | 原因 |
|---|---|---|
| Base Color / Albedo | `_UNORM_SRGB` | 美术颜色通常按 sRGB 编码 |
| Emissive Color | `_UNORM_SRGB` | 通常也是颜色数据 |
| Normal Map | `UNORM` 或 `SNORM` | 通道编码的是向量分量，不是显示颜色 |
| Metallic / Roughness | `UNORM` | 通道是材质参数 |
| Ambient Occlusion | `UNORM` | 通道是遮蔽系数 |
| Depth / Height / Mask | 对应线性数据格式 | 通道是数值，不是颜色 |

不能根据文件扩展名决定颜色空间。同一张 PNG 既可能是 Base Color，也可能装着
法线或粗糙度；材质语义才决定创建 sRGB 还是线性 SRV。glTF 阶段会依据纹理用途
自动选择 view。

## 10. 当前代码和生命周期

代码入口：

- `learning/sandbox/d3d12/r01-r08-mesh/d3d12_mesh_input_layout.cu`
- `learning/sandbox/d3d12/r01-r08-mesh/d3d12_mesh_input_layout.hlsl`

启动阶段创建 typeless 颜色 Resource、sRGB SRV、sRGB RTV 和匹配 PSO；它们在整个
渲染循环中保持存活。逐帧只绑定已有描述符并绘制，不发生颜色空间相关 CPU/GPU
同步。颜色转换也不需要 ResourceBarrier；Barrier 管资源用途，SRV/RTV 格式管
数值解释。

## 11. 当前简化边界

- Back Buffer 直接作为 SDR sRGB 目标，没有中间 HDR 浮点 Render Target；这条
  路径颜色空间正确，但受 8-bit 精度、0..1 范围和缺少统一后处理输入的限制。
- 没有 tone mapping、曝光、广色域、HDR10/PQ 或 scRGB。
- 顶点颜色和清屏值由示例约定为线性数值，尚无资产元数据系统。
- 纹理只有 Mip 0；下节会创建完整 Mip 链并解释 LOD、过滤和各向异性。
- 本节不实现软件 `pow` 路径，因为硬件格式转换更可靠，也不会误伤 Alpha。
- 线性 `R16G16B16A16_FLOAT` 离屏目标、全屏三角形和最终输出 Pass 会在 F.2
  实现；届时所有场景/透明计算先留在线性 HDR 目标，最后才 tone map 并编码。

## 12. 动手验证

```powershell
cd C:\xf\Cuda\accelerated-computing-hub\learning\sandbox
.\build.ps1 d3d12\r01-r08-mesh\d3d12_mesh_input_layout.cu -NoRun
.\d3d12\r01-r08-mesh\d3d12_mesh_input_layout.exe --frames 180 --no-vsync
```

程序首先打印标准曲线数值：

```text
sRGB reference: RGB8 128 -> linear 0.215861; alpha8 128 -> 0.501961
```

最后应输出：

```text
D3D12 R.5.4 sRGB input/output with linear blending: PASS
```

## 13. 小结与自测

```text
Resource Format 决定兼容格式族和存储
View Format 决定本次访问的数值解释
SRGB SRV 负责输入 RGB 解码
Shader 和 Blend 使用线性 RGB
SRGB RTV 负责输出 RGB 编码
Alpha 始终不经过 sRGB 曲线
```

自测题：

1. 为什么 sRGB 数值 `0.5` 不能当作线性能量 `0.5`？
2. 为什么法线纹理不能创建 `_SRGB` SRV？
3. 为什么交换链 Resource 是 `UNORM`，PSO 的 `RTVFormats[0]` 却是
   `UNORM_SRGB`？
4. `ResourceBarrier` 能不能代替 sRGB SRV 完成颜色解码？为什么？
