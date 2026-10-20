# R.5.2 D3D12 Alpha Blend 与透明绘制

> 版本说明：本文记录 R.5.2 的单透明 PSO 实验。主示例已在后续 R.5.3
> 升级为“不透明 PSO + 透明 PSO”；双 PSO 的当前代码和说明见
> `R.5.3-D3D12不透明与透明双PSO.md`。

## 1. 本节目标

在 R.5.1 的 Texture Resource、SRV、Sampler 和 UV 链上加入 Alpha Blend，让纹理的 Alpha 通道控制源颜色与目标颜色的混合。本节还要说明透明绘制为什么通常需要从远到近排序，以及它和深度写入之间的关系。

本节使用 straight alpha（非预乘 Alpha）公式，不处理 sRGB、Mip 生成、完整材质参数和 Order-Independent Transparency。
这里记录的是 R.5.2 的透明合成原理和历史单 PSO 实验；当前示例已经在 R.5.3
拆成不透明/透明双 PSO，R.5.4 又加入了 sRGB/线性颜色链。

## 2. 混合发生在什么位置

Pixel Shader 返回源颜色：

```hlsl
float4 source = gColorTexture.Sample(gColorSampler, input.uv)
                * input.color;
```

Rasterizer/Pixel Shader 产生的这个颜色称为 source；RTV 中已经存在的颜色称为 destination。Alpha Blend 在 Pixel Shader 输出之后、写入 RTV 之前执行：

```text
PS 输出 source
    -> Blend Unit 读取 RTV 中的 destination
    -> 按 PSO 的 BlendState 计算
    -> 把结果写回 RTV
```

它不是 Pixel Shader 中自动发生的乘法，也不是纹理采样器的功能。

## 3. straight-alpha 公式

本节使用：

```text
sourceFactor      = source.a
destinationFactor = 1 - source.a
blendOperation    = ADD
```

因此 RGB 结果为：

```text
output.rgb = source.rgb * source.a
             + destination.rgb * (1 - source.a)
```

例子：

```text
source.rgb      = (1, 0, 0)
source.a        = 0.25
destination.rgb = (0, 0, 1)

output.rgb = (1,0,0)*0.25 + (0,0,1)*0.75
           = (0.25, 0, 0.75)
```

这就是半透明红色叠在蓝色背景上得到紫红色的原因。

## 4. D3D12 BlendState 配置

当前 PSO 的 Render Target 0 使用：

```cpp
D3D12_RENDER_TARGET_BLEND_DESC& targetState =
    blend.RenderTarget[0];

targetState.BlendEnable = TRUE;
targetState.LogicOpEnable = FALSE;

// RGB：source.rgb * source.a + destination.rgb * (1-source.a)
targetState.SrcBlend = D3D12_BLEND_SRC_ALPHA;
targetState.DestBlend = D3D12_BLEND_INV_SRC_ALPHA;
targetState.BlendOp = D3D12_BLEND_OP_ADD;

// Alpha 通道单独配置。这里让结果 alpha 代表“源覆盖目标”后的覆盖度：
// output.a = source.a + destination.a * (1-source.a)
targetState.SrcBlendAlpha = D3D12_BLEND_ONE;
targetState.DestBlendAlpha = D3D12_BLEND_INV_SRC_ALPHA;
targetState.BlendOpAlpha = D3D12_BLEND_OP_ADD;

targetState.RenderTargetWriteMask =
    D3D12_COLOR_WRITE_ENABLE_ALL;
```

颜色和 Alpha 有两套独立的因子：`SrcBlend/DestBlend` 处理 RGB，`SrcBlendAlpha/DestBlendAlpha` 处理 Alpha。不能只设置 RGB 因子就认为 Alpha 通道也自动采用相同公式。

`BlendEnable=TRUE` 才启用混合；如果是 `FALSE`，源颜色会直接覆盖目标颜色。`LogicOpEnable` 和 Blend 不能同时作为同一 Render Target 的两套颜色运算方式使用，本节关闭 LogicOp。

## 5. 纹理 Alpha 如何产生

本节仍使用 RGBA8_UNORM 纹理，但把 Alpha 设成从左到右的渐变：

```cpp
const float horizontalAlpha =
    0.15f + 0.85f * static_cast<float>(x) /
                       static_cast<float>(kTextureWidth - 1);
row[x * 4 + 3] = static_cast<std::uint8_t>(
    horizontalAlpha * 255.0f + 0.5f);
```

上传后，SRV 按 `R8G8B8A8_UNORM` 读取；Shader 得到的是 0 到 1 的 `float4`，所以 Alpha 参与公式时是浮点权重，不是 0 到 255 的整数。

本节没有使用 sRGB 格式。UNORM 与 sRGB 的颜色解码关系会在后续单独讲，不能把“Alpha Blend”与“颜色空间转换”混成一个功能。

## 6. Alpha Blend 与深度测试

透明绘制通常使用：

```text
DepthEnable = TRUE
DepthFunc = LESS
DepthWriteMask = ZERO
```

含义是：

- 仍然用已有深度挡住被不透明几何体遮挡的透明 fragment。
- 透明 fragment 通过深度测试后，不把自己的深度写回深度资源。
- 多个透明层不会因为第一个透明层写入深度而把后续层全部挡掉。

但关闭深度写入后，深度测试不能自动解决透明层的混合顺序。透明混合一般不是交换律运算，因此需要从远到近绘制：

```text
先画远物体
    -> 颜色进入 RTV
再画近物体
    -> 近物体颜色与远物体颜色混合
```

当前代码故意这样提交：

```cpp
// 远三角形：index 0..2
commandList->DrawIndexedInstanced(3, 1, 0, 0, 0);

// 近三角形：index 3..5
commandList->DrawIndexedInstanced(3, 1, 3, 0, 0);
```

如果把它们反过来，颜色混合结果会改变，即使几何深度关系没有改变。这正是透明物体需要排序的原因。

真实渲染器通常分成两个 Pass；R.5.3 已在示例中完成这个拆分：

```text
不透明 Pass：DepthWriteMask=ALL，通常不启用 Blend
透明 Pass：  DepthWriteMask=ZERO，启用 Blend，按远到近排序
```

R.5.2 当时的 demo 为了集中展示 Alpha Blend，只有一个透明纹理 PSO；双 PSO 的
实际代码和 API 解释见 `R.5.3-D3D12不透明与透明双PSO.md`。

## 7. straight alpha 与 premultiplied alpha

本节是 straight alpha：纹理 RGB 没有提前乘 Alpha，因此使用：

```text
SrcBlend = SRC_ALPHA
DestBlend = INV_SRC_ALPHA
```

另一种常见格式是 premultiplied alpha：纹理存储的 RGB 已经是 `rgb * alpha`，此时通常使用：

```text
SrcBlend = ONE
DestBlend = INV_SRC_ALPHA
```

这两套数据约定不能混用。若把预乘纹理误用 straight-alpha，边缘会再次乘 Alpha，出现发暗；反之也会出现亮边或颜色错误。

## 8. 当前代码链

```text
CPU 生成 RGBA8 像素（含 Alpha）
    -> Upload Buffer，按 RowPitch 排列
    -> CopyTextureRegion
    -> Texture Resource：COPY_DEST
    -> Barrier：PIXEL_SHADER_RESOURCE
    -> SRV：t0
    -> Sampler：s0
    -> PS Sample 得到 source float4
    -> BlendState 读取 RTV destination
    -> 写回混合后的颜色
```

Alpha Blend 不改变 Texture Resource、SRV 或 Sampler 的职责；它是 PSO 固定管线中的 RTV 写入规则。

## 9. 实测验收

运行：

```powershell
.\build.ps1 d3d12\r01-r08-mesh\d3d12_mesh_input_layout.cu -NoRun
.\d3d12\r01-r08-mesh\d3d12_mesh_input_layout.exe --frames 180 --no-vsync
```

RTX 5070 / `sm_120` 输出：

```text
uploaded 256x256 RGBA8 checker texture: row_pitch=1024, upload=262144 bytes
rendered frames: 180
D3D12 R.5.2 texture + SRV + sampler + alpha blend: PASS
```

## 10. 当前边界

已完成：

```text
straight-alpha RGB/Alpha 混合
透明 Pass 的深度写入选择
远到近绘制顺序
纹理 Alpha 到 BlendState 的完整链条
```

后续再处理：

```text
sRGB 与线性空间（已在 R.5.4 完成）
MipMap 和各向异性过滤
材质常量（baseColor、metallic、roughness）
透明裁剪（alpha test）
```

## 自测题

1. `SrcBlend=SRC_ALPHA` 和 `DestBlend=INV_SRC_ALPHA` 对 RGB 计算的数学公式是什么？
2. 为什么透明 Pass 通常保留深度测试但关闭深度写入？
3. 为什么透明物体通常需要从远到近排序？
4. straight alpha 和 premultiplied alpha 的 BlendState 为什么不同？
