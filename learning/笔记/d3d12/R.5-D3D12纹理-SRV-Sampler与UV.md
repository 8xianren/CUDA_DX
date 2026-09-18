# R.5.1 D3D12 纹理、SRV、Sampler 与 UV

## 1. 本节目标

在 R.4 的深度网格上加入一张 RGBA8 纹理，让 Pixel Shader 根据插值后的 UV 读取纹理颜色。本节使用 CPU 生成的棋盘纹理，不引入 PNG/JPEG 解码器；重点是理解资源上传和 Shader 绑定链。

## 2. 必须分开的对象

```text
Texture Resource
    真正保存纹理像素的二维资源

SRV（Shader Resource View）
    描述 Shader 如何读取这份纹理的视图

SRV 描述符
    CreateShaderResourceView 写入 CBV/SRV/UAV Heap 槽位的访问记录

GPU Descriptor Handle
    定位 SRV 描述符槽位，供根描述符表使用

Sampler 描述符
    保存过滤方式和 U/V/W 寻址方式；它不保存纹理像素，也不是 SRV
```

HLSL 的两个声明分别对应两类不同描述符：

```hlsl
Texture2D<float4> gColorTexture : register(t0);
SamplerState gColorSampler : register(s0);
```

`t0` 指向纹理 SRV，`s0` 指向采样器。采样器不能放进 CBV/SRV/UAV Heap，而要放入独立的 SAMPLER Heap。

## 3. 顶点数据中的 UV

本节把 `Vertex` 从 28 字节扩展为 36 字节：

```text
offset 0  : position，float3，12 字节
offset 12 : color，float4，16 字节
offset 28 : uv，float2，8 字节
stride 36
```

Input Layout 新增：

```cpp
{"TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT, 0,
 static_cast<UINT>(offsetof(Vertex, uv)),
 D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0}
```

UV 不是像素坐标，而是顶点携带的二维参数。光栅化器在三角形内部插值 UV，Pixel Shader 收到的是当前 fragment 的插值结果。

## 4. 纹理资源上传

### 4.1 Default Heap 纹理

```cpp
textureDescription.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
textureDescription.Width = 256;
textureDescription.Height = 256;
textureDescription.DepthOrArraySize = 1;
textureDescription.MipLevels = 1;
textureDescription.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
textureDescription.SampleDesc.Count = 1;
textureDescription.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
textureDescription.Flags = D3D12_RESOURCE_FLAG_NONE;
```

创建时状态为：

```cpp
D3D12_RESOURCE_STATE_COPY_DEST
```

因为第一步 GPU 操作是从上传资源复制到它。

### 4.2 `GetCopyableFootprints` 与 RowPitch

纹理不能简单地把 `width * bytesPerPixel` 当成每行跨度。D3D12 会要求上传布局满足硬件对齐，因此使用：

```cpp
device->GetCopyableFootprints(
    &textureDescription,
    0,
    1,
    0,
    &footprint,
    &rowCount,
    &rowSize,
    &uploadByteCount);
```

对于本节的 256x256 RGBA8 纹理：

```text
逻辑行字节数 = 256 * 4 = 1024
实际 RowPitch = 1024
总上传大小 = 256 * 1024 = 262144 字节
```

不能假定所有纹理都如此；真正写入上传资源时必须使用：

```cpp
auto* row = uploadBytes + y * footprint.Footprint.RowPitch;
```

而不是使用 `y * logicalRowBytes` 作为下一行起点。

### 4.3 Copy 与状态转换

```text
Upload Buffer（CPU 写入）
    -> CopyTextureRegion
Texture Resource：COPY_DEST
    -> ResourceBarrier
Texture Resource：PIXEL_SHADER_RESOURCE
```

纹理复制完成后记录：

```cpp
barrier.Transition.StateBefore =
    D3D12_RESOURCE_STATE_COPY_DEST;
barrier.Transition.StateAfter =
    D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE;
```

资源状态描述 GPU 的使用方式；SRV 只描述如何读取，不能替代状态转换。

上传命令提交后必须等待 Fence，才能释放临时 Upload Buffer。纹理资源和 SRV 描述符则要一直活到 GPU 不再绘制它。

## 5. SRV 描述符

CBV 和纹理 SRV 共用一个 shader-visible `CBV_SRV_UAV` Heap：

```text
slot 0 -> Frame 0 CBV
slot 1 -> Frame 1 CBV
slot 2 -> Texture SRV
```

SRV 描述结构体：

```cpp
D3D12_SHADER_RESOURCE_VIEW_DESC srvDescription{};
srvDescription.Shader4ComponentMapping =
    D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
srvDescription.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
srvDescription.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
srvDescription.Texture2D.MostDetailedMip = 0;
srvDescription.Texture2D.MipLevels = 1;
```

然后把 SRV 描述符写入 slot 2：

```cpp
device->CreateShaderResourceView(
    textureResource,
    &srvDescription,
    srvCpuHandle);
```

SRV 不拥有纹理资源；释放资源后 SRV 也不能继续使用。

## 6. 采样器描述符

采样器描述符位于单独的 shader-visible `SAMPLER` Heap：

```cpp
samplerDescription.Filter =
    D3D12_FILTER_MIN_MAG_MIP_LINEAR;
samplerDescription.AddressU = D3D12_TEXTURE_ADDRESS_MODE_WRAP;
samplerDescription.AddressV = D3D12_TEXTURE_ADDRESS_MODE_WRAP;
samplerDescription.AddressW = D3D12_TEXTURE_ADDRESS_MODE_WRAP;
samplerDescription.ComparisonFunc =
    D3D12_COMPARISON_FUNC_ALWAYS;
samplerDescription.MinLOD = 0.0f;
samplerDescription.MaxLOD = D3D12_FLOAT32_MAX;
```

这里的 `LINEAR` 表示纹理过滤规则；`WRAP` 表示 UV 超出 `[0,1]` 后如何寻址。它们都是采样器状态，不是纹理格式，也不是资源状态。

## 7. 根签名和命令绑定

当前根签名包含三个根参数：

```text
Root Parameter 0 -> CBV Table -> b0 -> 当前帧矩阵
Root Parameter 1 -> SRV Table -> t0 -> 纹理
Root Parameter 2 -> Sampler Table -> s0 -> 采样器
```

帧录制时同时绑定两个 shader-visible Heap：

```cpp
ID3D12DescriptorHeap* heaps[] = {
    cbvSrvUavHeap,
    samplerHeap
};
commandList->SetDescriptorHeaps(2, heaps);
```

然后分别设置三个表的 GPU 起点：

```cpp
commandList->SetGraphicsRootDescriptorTable(0, frameCbvGpu);
commandList->SetGraphicsRootDescriptorTable(1, textureSrvGpu);
commandList->SetGraphicsRootDescriptorTable(2, samplerGpu);
```

注意：D3D12 图形命令列表同时最多绑定一个 CBV/SRV/UAV Heap 和一个 SAMPLER Heap，所以 CBV 与 SRV 必须合并到同一个前者中。

## 8. Shader 执行链

```hlsl
output.uv = input.uv;
```

光栅化器插值后：

```hlsl
return gColorTexture.Sample(gColorSampler, input.uv)
       * input.color;
```

完整数据链是：

```text
CPU Vertex.uv
    -> Input Layout TEXCOORD0
    -> VS 输出 UV
    -> 光栅化插值
    -> PS 使用 t0 的 SRV + s0 的采样器
    -> 读取 Texture Resource 像素
    -> 写 RTV
```

## 9. 当前实现验收

运行：

```powershell
.\build.ps1 d3d12\d3d12_mesh_input_layout.cu -NoRun
.\d3d12\d3d12_mesh_input_layout.exe --frames 180 --no-vsync
```

RTX 5070 / `sm_120` 实测输出包括：

```text
uploaded vertex buffer: 6 vertices, 216 bytes, stride=36
uploaded 256x256 RGBA8 checker texture: row_pitch=1024, upload=262144 bytes
rendered frames: 180
D3D12 R.5 texture resource + SRV + sampler: PASS
```

本节只验证不透明纹理采样。Alpha Blend、纹理格式的 sRGB/线性空间、Mip 生成和材质常量会在后续小节处理。

## 自测题

1. Texture Resource、SRV 描述符和 Sampler 描述符各自保存什么？
2. 为什么 CBV 和 SRV 放在同一个堆，而 Sampler 放在另一个堆？
3. 为什么上传纹理时必须使用 `GetCopyableFootprints` 返回的 `RowPitch`？
4. 为什么纹理复制完成后还要把资源从 `COPY_DEST` 转到 `PIXEL_SHADER_RESOURCE`？

