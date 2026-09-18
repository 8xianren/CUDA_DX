# R.5.5 D3D12 MipMap、过滤与 LOD

## 1. 本节目标

本节把 R.5.1 的“只有一张 Mip 0 的纹理”扩展为完整的 Texture2D Mip 链，并回答
三个实际问题：

1. 远处或屏幕上很小的纹理，为什么不能永远只采样最高分辨率？
2. D3D12 如何把多个 Mip 上传到同一个纹理 Resource？
3. `Texture2D.Sample` 如何根据当前像素的 UV 变化选择 Mip 和过滤方式？

可运行代码：

- `learning/sandbox/d3d12/d3d12_mesh_input_layout.cu`
- `learning/sandbox/d3d12/d3d12_mesh_input_layout.hlsl`

官方资料：

- [Upload and readback of texture data](https://learn.microsoft.com/en-us/windows/win32/direct3d12/upload-and-readback-of-texture-data)
- [D3D12_FILTER](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ne-d3d12-d3d12_filter)
- [Texture.Sample](https://learn.microsoft.com/en-us/windows/win32/direct3dhlsl/dx-graphics-hlsl-to-sample)
- [D3D12_SHADER_RESOURCE_VIEW_DESC](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ns-d3d12-d3d12_shader_resource_view_desc)

## 2. 直觉：给不同距离准备不同分辨率的贴图

把一张 256x256 的 Base Color 纹理贴到屏幕上：

- 近处物体可能有几百个屏幕像素覆盖一个纹理区域，需要读取 Mip 0 的细节。
- 远处物体可能只有十几个屏幕像素，却仍覆盖了整张纹理。此时一个屏幕像素
  对应很多纹理像素，直接从 Mip 0 取样会产生闪烁和摩尔纹。

MipMap 就是预先保存的降采样链：

```text
Mip 0: 256 x 256
Mip 1: 128 x 128
Mip 2:  64 x  64
...
Mip 8:   1 x   1
```

游戏类比：这是为同一模型准备的 LOD，但对象不同。网格 LOD 替换的是几何顶点；
纹理 Mip 替换的是图像采样的分辨率。Sampler 根据纹理在屏幕上的投影大小选择
合适层级，避免把远景当作近景逐 texel 读取。

Mip 不能消除所有锯齿。它先解决“纹理采样频率过高”的问题；屏幕几何边缘的
抗锯齿属于 MSAA/FXAA/TAA 等另一条路线。

## 3. Mip 链与 subresource

### 3.1 级数

每次把宽、高约减半，直到都为 1。最大维度为 `N` 时，级数是：

```text
floor(log2(N)) + 1
```

当前 `N=256`，因此为 9 级。代码用 `calculate_mip_level_count` 在编译期计算，
而不是把 9 散落在多个 API 调用中。

### 3.2 每级是独立 subresource

对非数组 Texture2D，可以把一个 Mip 理解为一个 subresource。数组纹理还要把
每个 array slice 的每个 Mip 组合起来；本节没有数组维度，因此 `SubresourceIndex`
就是 Mip 编号 0..8。

一个 Resource 可以拥有所有 Mip 的存储，但上传时每级都有自己的：

- 逻辑尺寸 `width/height`
- 上传起始 `Offset`
- 行间距 `RowPitch`
- 有效行字节数 `RowSizeInBytes`
- 行数 `NumRows`

这些值由 `ID3D12Device::GetCopyableFootprints` 给出。上传 footprint 里的行通常
按 256 字节对齐，subresource 起始偏移通常按 512 字节对齐，所以 Mip 之间会有
padding。CPU vector 中的紧密排列不等于 Upload Buffer 中的排列。

### 3.3 Resource、上传资源和 SRV 的职责

```text
CPU CpuMipLevel vector
    --按每级 footprint 写入-->
Upload Heap Buffer
    --CopyTextureRegion，每级一个 subresource-->
Default Heap Texture2D (Mip 0..8)
    --SRV 描述如何读取-->
Pixel Shader Texture2D.Sample
```

- Default Heap Texture Resource 拥有 GPU 纹理存储。
- Upload Heap Buffer 是短期 staging 资源，copy 完并等待 Fence 后可以释放。
- SRV 不拥有像素，只描述 Shader 访问哪个 Resource、格式和 Mip 范围。
- Resource Barrier 只描述 GPU 使用状态，不生成 Mip，也不进行 sRGB 解码。

## 4. CPU 生成 Mip：必须尊重颜色空间

当前颜色 Resource 的格式是 `R8G8B8A8_TYPELESS`，SRV 的格式是
`R8G8B8A8_UNORM_SRGB`。因此 Mip 落盘时必须保持“RGB 是 sRGB 编码字节、Alpha 是
线性 UNORM 覆盖度”的契约。

对一个 2x2 邻域，正确的 RGB 流程是：

```text
四个 sRGB RGB8 字节
    -> 每个值 sRGB 解码到线性 RGB
    -> 在线性空间求平均
    -> 平均值编码回 sRGB
    -> 写入下一 Mip 的 RGB8 字节
```

Alpha 不经过 sRGB 曲线：

```text
四个 Alpha8 / 255
    -> 普通线性平均
    -> 量化为 Alpha8
```

如果直接平均 sRGB 编码字节，暗部会被当作线性能量，Mip 会偏暗。这个问题和
BC 压缩、GPU 的 tiled 内存排布是正交的：本节只讨论数值颜色空间，不把“编码
传递函数”“减少存储字节”“物理显存布局”混成一个概念。

当前代码中的 `build_color_texture_mip_chain` 还明确写出了非 2 的幂尺寸边界：不足
2x2 时复制最后一个源像素。当前 256x256 恰好是 2 的幂，但边界策略让生成器的
契约清楚可见。

### Alpha 边缘的暂缓问题

本节对 straight-alpha 纹理独立平均 RGB 和 Alpha。这对教学足够，但透明贴图的
彩色边缘可能出现污染：完全透明像素中的 RGB 仍可能影响缩小后的颜色。生产管线
通常会考虑预乘 Alpha 或 Alpha-weighted filtering，并与材质的 Alpha Mode 一致。
这不是本节偷偷解决的内容，将在 R.5.6 的 Alpha Mode/材质数据中系统处理。

## 5. 真实 D3D12 上传流程

### 5.1 创建带 Mip 的 Resource

```cpp
texture_description.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
texture_description.Width = 256;
texture_description.Height = 256;
texture_description.DepthOrArraySize = 1;
texture_description.MipLevels = 9;
texture_description.Format = DXGI_FORMAT_R8G8B8A8_TYPELESS;
```

初始状态使用 `D3D12_RESOURCE_STATE_COPY_DEST`，因为接下来由 Copy 命令写入。
Resource 描述了整条链的存储；它不代表 CPU vector，也不代表 SRV。

### 5.2 查询所有 footprint

真实调用是：

```cpp
device->GetCopyableFootprints(
    &texture_description,
    0,                  // FirstSubresource：从 Mip 0 开始
    kTextureMipLevels,  // NumSubresources：连续查询 9 个 Mip
    0,                  // BaseOffset：Upload Buffer 中的起始基准
    footprints.data(),  // 每个 Mip 的放置 footprint
    row_counts.data(),  // 每个 Mip 的行数
    row_sizes.data(),   // 每个 Mip 的有效行字节数
    &upload_byte_count);// 覆盖所有 footprint 后需要的总字节数
```

`GetCopyableFootprints` 不返回 `HRESULT`；它是设备查询接口。代码仍检查返回的
每级尺寸是否覆盖 CPU 数据，避免把错误的 stride 当成正确结果。

### 5.3 写 Upload Buffer

CPU 的 `CpuMipLevel::rgba8` 每行紧密排列，D3D12 的 Upload footprint 每行可能有
padding，所以代码使用：

```cpp
destination_row = upload_bytes
                + footprints[mip].Offset
                + y * footprints[mip].Footprint.RowPitch;
```

然后只 `memcpy` 当前行的有效 `width * 4` 字节。不能用上一 Mip 的 RowPitch，也不能
把所有 Mip 当作一个连续二维数组。

### 5.4 每级 CopyTextureRegion

```cpp
destination.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
destination.SubresourceIndex = mip;

source.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
source.PlacedFootprint = footprints[mip];

upload_list->CopyTextureRegion(&destination, 0, 0, 0, &source, nullptr);
```

这里的 `destination` 说明写入 Default Heap 纹理的哪个 Mip；`source` 说明从
Upload Buffer 的哪一块、按什么 RowPitch 读取。Copy 是字节搬运，不执行 sRGB
解码或平均。

所有 9 次 Copy 录制完成后，代码记录一次：

```cpp
COPY_DEST -> PIXEL_SHADER_RESOURCE
```

使用 `D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES` 覆盖整条 Mip 链。提交 Queue 后用
Fence 等待，原因有两个：确认 GPU 已完成 copy，并确认临时 Upload Buffer 可以安全
销毁。这个 Fence 等待是初始化阶段的 CPU/GPU 生命周期同步，不是每次 Sample 的
同步。

## 6. SRV 的 Mip 范围

```cpp
srv_description.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
srv_description.Texture2D.MostDetailedMip = 0;
srv_description.Texture2D.MipLevels = 9;
srv_description.Texture2D.ResourceMinLODClamp = 0.0f;
```

- `MostDetailedMip=0`：view 的最细起点是 Mip 0。
- `MipLevels=9`：这个 view 暴露 Mip 0..8；如果只写 1，硬件没有合法的低分辨率
  Mip 可选，即使 Resource 本身拥有它们。
- `ResourceMinLODClamp=0`：SRV 级别的最小 LOD 限制。本节没有用它人为偏移。

SRV 仍然使用 `_UNORM_SRGB`，所以无论硬件最终选 Mip 0 还是 Mip 5，采样返回的
RGB 都会从该 Mip 的 sRGB 字节解码为线性 float；Alpha 仍按普通 UNORM 读取。

## 7. Sampler 与过滤

```cpp
sampler_description.Filter = D3D12_FILTER_MIN_MAG_MIP_LINEAR;
sampler_description.AddressU = D3D12_TEXTURE_ADDRESS_MODE_WRAP;
sampler_description.AddressV = D3D12_TEXTURE_ADDRESS_MODE_WRAP;
sampler_description.MinLOD = 0.0f;
sampler_description.MaxLOD = 8.0f;
```

`MIN_MAG_MIP_LINEAR` 包含三层含义：

1. **MAG**：放大时，在一个 Mip 内做双线性过滤。
2. **MIN**：缩小时，在一个 Mip 内做双线性过滤。
3. **MIP**：在相邻两个 Mip 之间按小数 LOD 线性插值。

三者都为 Linear 时通常称为 trilinear（三线性）过滤。它不是各向异性过滤；
斜视表面上，三线性仍以近似方形 footprint 工作，各向异性过滤会沿拉伸方向取
更多样本，代价更高但更适合掠射角纹理。后续性能/质量课程再讨论各向异性取舍。

`MinLOD/MaxLOD` 是 Sampler 的夹紧范围，本例把 LOD 限制为完整链的 0..8。它们
不会生成缺失的 Mip，也不会改变 Resource 的拥有关系。

## 8. 隐式 LOD：`Sample` 到底依据什么选择

HLSL：

```hlsl
return gColorTexture.Sample(gColorSampler, input.uv) * input.color;
```

`Sample` 没有显式 LOD 参数。这里的 LOD 不是网格/模型 LOD，也还不是整数
`MipLevel`。D3D/HLSL 里的纹理 LOD（`lambda`）是一个**连续值**：它描述当前
屏幕像素在纹理空间里的 footprint 有多大。整数部分才对应要读的 Mip 层，小数
部分才是相邻两层之间的混合权重。

Pixel Shader 运行时，硬件可利用当前像素相邻调用的 UV 屏幕导数来估计这个
footprint。概念近似为：

```text
rho = max(
    length(ddx(uv * textureSize)),
    length(ddy(uv * textureSize)))
lambda = log2(rho)
```

其中：

- `ddx/ddy` 描述 UV 沿屏幕 x/y 方向的变化。
- `textureSize` 把归一化 UV 变化换成 texel 尺度。
- `rho` 是 footprint **较长那条边**的 texel 长度，不是覆盖面积。向右走 1 个
  屏幕像素大约跨过 `length(ddx(uv*textureSize))` 个 texel，向下同理；取 max
  是因为只要最长边已经覆盖太多 texel，就需要更粗的 Mip。
- 用 `log2(rho)` 是因为每一级 Mip 把宽和高都大约减半，也就是把这条边长除以 2：
  `rho=1` → Mip 0，`rho=2` → Mip 1，`rho=4` → Mip 2。若误把 `rho` 当成面积，
  正方形时 `log2(sqrt(area))` 碰巧同值，但长条 footprint 会算错；各向异性过滤
  要处理的正是这种被拉长的 footprint。
- `lambda < 0` 通常意味着放大，主要使用 MAG 规则。
- `lambda >= 0` 意味着缩小，`floor(lambda)` 选出较低那层 Mip，小数部分交给
  MIP 规则做层间插值。

这不是要求开发者手写的精确硬件实现，而是理解行为的近似公式。实际结果还会
受到采样器的 `MipLODBias`、`MinLOD`、`MaxLOD` 和实现细节影响。

### `Sample`、`SampleLevel`、`SampleGrad`

- `Sample`：使用隐式导数，普通材质纹理的默认选择。
- `SampleLevel`：显式给出 LOD，绕过隐式导数；适合手工 LOD、预览某一级 Mip
  或特殊后处理，但错误的固定 LOD 会导致闪烁或细节浪费。
- `SampleGrad`：显式提供 `ddx/ddy`，适合 UV 在 Shader 中经过非标准变换、而
  默认导数无法表达真实 footprint 的情况。

本节使用 `Sample`，让 GPU 根据光栅化后插值的 UV 和像素邻域自动完成 LOD。

## 9. 为什么示例把 UV 改成多次重复

如果三角形只把 UV 从 0 变化到 1，它在当前窗口中通常不足以产生明显的缩小
footprint，观察不到高 Mip 的作用。示例改为：

- 远三角形约重复 16 次；
- 近三角形约重复 8 次；
- Sampler 使用 `WRAP` 处理超过 1 的坐标。

这样同样的屏幕距离对应更大的 texel 变化，更容易让隐式 `lambda` 进入 1、2
甚至更高的范围。UV 的重复是为了验收 Mip 选择，不是生产材质必须重复的数值。

## 10. 当前代码的真实验收

PowerShell：

```powershell
cd C:\xf\Cuda\accelerated-computing-hub\learning\sandbox
.\build.ps1 d3d12\d3d12_mesh_input_layout.cu -NoRun
.\d3d12\d3d12_mesh_input_layout.exe --frames 2 --no-vsync
.\d3d12\d3d12_mesh_input_layout.exe --frames 180 --no-vsync
```

本机 RTX 5070 / `sm_120` 实测：

```text
uploaded 256x256 RGBA8 color texture: mips=9, typeless resource + sRGB SRV,
base_row_pitch=1024, upload=359940 bytes
...
rendered frames: 2
D3D12 R.5.5 MipMap filtering and implicit LOD: PASS
```

180 帧也通过，输出 `frame-resource CPU waits: 20`。这表示帧资源复用时发生了
有限次数 Fence 等待，与纹理 Mip 初始化的单次 Fence 等待是两个不同阶段。

代码没有读取 GPU 内部最终选择了哪一级 Mip；要观察精确 LOD，可在后续加入
`SampleLevel` 对照、Mip 颜色编码调试纹理或使用 PIX/RenderDoc 的纹理调试器。

## 11. 当前简化边界与后续位置

### 商业引擎 vs 本课

商业引擎通常不在运行时用 CPU 逐级平均一张未压缩棋盘图。UE/Unity 一类管线
会在导入纹理时离线生成 Mip，颜色图常压成 BC7/BC5，世界材质默认开各向异性，
大世界还可能做纹理流送或虚拟纹理。本课故意 CPU 生成 RGBA8、三线性、启动时
一次上传整条链，是为了让 `GetCopyableFootprints`、sRGB 平均和 `Sample` 隐式 LOD
可见。纹理 LOD 仍由屏幕 footprint 的边长决定，这一点和引擎相同；差别在资产管线与默认质量。

### BC 压缩纹理的影子

如果资产已经是 BC1/BC5/BC7，运行时采样路径**不会**先在 CPU 解压成 RGBA 再上传。
离线工具生成每一级 Mip 后，把每一级单独压成压缩块；GPU 上传的是这些压缩字节。
`Sample` 时由纹理单元按需解开被踩到的 4x4 块。CPU 解压只出现在编辑器缩略图、
CPU 读回等特殊路径。压缩格式的 footprint 按块对齐，不能套用本节 RGBA8 的
`width*4` 行字节；完整讲解放到后续压缩纹理小节。

- Mip 在 CPU 生成，便于看清 sRGB 解码、线性平均和 RowPitch；生产工具链也可能
  在离线资产处理阶段生成，或使用 GPU compute 生成。
- 只实现三线性过滤，没有各向异性过滤、压缩纹理和纹理数组。
- 颜色纹理采用独立 RGB/Alpha 平均；straight-alpha 边缘的预乘/加权策略移到
  R.5.6 Alpha Mode 和完整材质数据。
- 仍直接渲染到 sRGB 交换链 Back Buffer；HDR 离屏目标、后处理和最终 tone mapping
  属于后续 F.2 路线。
- 窗口 Resize、MSAA、反向 Z 等不属于 Mip 机制，本节不借 Mip 之名跳过它们。

## 12. 小结

```text
Mip 链 = 同一纹理的多级预过滤 subresource
GetCopyableFootprints = 每级 Upload Offset/RowPitch/NumRows 的权威来源
CopyTextureRegion = 按 subresource 把字节从 Upload 搬到 Default Texture
SRV.MipLevels = 允许 view 看到哪些 Mip
Sample = 依据 UV 屏幕导数隐式估计 LOD
MIN/MAG/MIP_LINEAR = 层内双线性 + 层间线性（三线性）
sRGB 颜色 Mip = 先解码、在线性平均、再编码；Alpha 仍按线性 UNORM 平均
```

## 13. 自测题

1. Resource 已经拥有 9 个 Mip，为什么 SRV 的 `Texture2D.MipLevels` 仍不能写 1？
2. 为什么不能把 CPU 中紧密排列的 Mip vector 直接连续 `memcpy` 到 Upload Buffer，
   而必须使用每级 `Offset + y * RowPitch`？
3. 对 sRGB 颜色纹理生成 Mip 时，为什么 RGB 要“先解码再平均再编码”，而 Alpha
   不应经过 sRGB 曲线？
4. `Sample`、`SampleLevel` 和 `SampleGrad` 在 LOD 来源上有什么区别？本示例为什么
   使用 `Sample`？

