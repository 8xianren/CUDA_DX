# R.5.6 D3D12 完整材质数据、Alpha Mode 与渲染队列

## 1. 本节目标

把 R.5.3 的“两条手写 Draw”收成 CPU 侧材质数据和渲染队列，并回答四个问题：

1. 材质和纹理、PSO 分别拥有什么？
2. glTF 的 `OPAQUE` / `MASK` / `BLEND` 在 D3D12 里分别改 Shader、深度还是 BlendState？
3. CPU 为什么要按 Alpha Mode 分队列，透明物体为什么还要额外从远到近排序？
4. straight-alpha 纹理生成 Mip 时，为什么 RGB 要用 Alpha 加权？

可运行代码：

- `learning/sandbox/d3d12/r01-r08-mesh/d3d12_mesh_input_layout.cu`
- `learning/sandbox/d3d12/r01-r08-mesh/d3d12_mesh_input_layout.hlsl`

官方资料：

- [glTF 2.0 materials.alphaMode](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#_material_alphamode)
- [ID3D12GraphicsCommandList::SetGraphicsRoot32BitConstants](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12graphicscommandlist-setgraphicsroot32bitconstants)
- [clip (HLSL)](https://learn.microsoft.com/en-us/windows/win32/direct3dhlsl/dx-graphics-hlsl-clip)

## 2. 直觉：演员、戏服和入场规则不是一件事

游戏类比：

```text
Texture Resource     = 一张布料照片
Material             = 这件衣服怎么穿：不透明墙、树叶镂空、玻璃半透明
PSO                  = 舞台规则：能不能混合、能不能写深度
Render Queue         = 演员按规则排队上场
```

R.5.3 已经有两套舞台规则：不透明 PSO 关 Blend、写深度；透明 PSO 开 Blend、不写深度。
当时“谁走哪套规则”是源码里写死的两条 `DrawIndexedInstanced`。本节把这个决定
收进 `Material.alpha_mode`，再由 CPU 队列翻译成 Draw。

## 3. 必须分开的对象

```text
Texture Resource
    拥有 GPU 像素存储，包括整条 Mip 链

SRV / Sampler
    描述如何读取那份像素，不拥有像素

Material
    CPU 策略：baseColorFactor、metallic、roughness、alphaMode、alphaCutoff
    不拥有 Texture，也不等于 PSO

PSO
    固定管线状态：BlendState、DepthStencilState、Shader 字节码
    不能按材质临时改字段

MeshDrawItem
    一次 Draw 的 CPU 描述：索引范围 + 材质指针 + 排序深度
```

因此“换一张贴图”和“把墙改成玻璃”不是同一件事。前者改 SRV 指向的 Resource；
后者改 Alpha Mode，进而改队列和 PSO。

### 商业引擎 vs 本课

UE/Unity 会把材质编译成 Shader 变体或 PSO 缓存，透明物体常用包围体中心到相机的
距离排序，并可能把 MASK 做成单独的 shader permutation。本课用同一套 VS/PS、两套
PSO、root constants 传材质、CPU `std::vector` 分队列。相同的是：Alpha Mode 决定
覆盖度语义，透明混合仍要排序，MASK 的镂空必须在写深度前丢弃。

## 4. 三种 Alpha Mode

glTF 用字符串；本课用整数，方便放进 root constants：

| 模式 | 覆盖度怎么处理 | PSO | 深度写入 | 队列顺序 |
|---|---|---|---|---|
| `OPAQUE` | Shader 强制 `alpha=1` | 不透明 | 写 | 先画，可按材质聚类 |
| `MASK` | `clip(alpha - cutoff)`，通过后仍当实心 | 不透明 | 写（仅通过测试的像素） | 跟在 OPAQUE 后 |
| `BLEND` | 保留 `alpha`，straight-alpha 混合 | 透明 | 不写 | 最后画，且从远到近 |

关键纠正：

- 纹理有 Alpha 通道，不等于材质是透明的。OPAQUE 墙也可以采样同一张带 Alpha 的图，
  但输出覆盖度必须是 1。
- MASK 不是半透明。它是“要么完全在、要么完全不在”。`clip` 丢弃的像素既不写颜色
  也不写深度，所以镂空后面的物体仍可见。
- BLEND 才是半透明。它必须读取已有颜色，所以要开 Blend；它不能把自己登记成实心墙，
  所以不写深度。

`BlendEnable=FALSE` 时，硬件不会自动把 Pixel Shader 的 Alpha 改成 1。当前交换链
不消费该 Alpha，但 OPAQUE/MASK 仍应明确输出 1，避免以后离屏合成读到纹理残值。

## 5. 渲染队列

CPU 在启动时按 Alpha Mode 把 `MeshDrawItem` 分进三个容器：

```text
opaque_items  -> 不透明 PSO
mask_items    -> 仍用同一个不透明 PSO，Shader 做 clip
blend_items   -> 透明 PSO，按 sort_depth 从大到小
```

每帧录制顺序固定为：

```text
OPAQUE
    -> MASK
    -> BLEND（远到近）
```

MASK 必须在 BLEND 之前，因为它要写入实心深度；如果先画玻璃再画树叶，树叶镂空处
的深度关系会乱。BLEND 内部排序和 PSO 切换是两件事：PSO 解决“能不能混合/写深度”，
排序解决“多个透明层谁先进入 RTV”。

本课相机在 `-Z` 看向原点，局部 `z` 越大越远，所以 `sort_depth` 直接用三角形的
局部 z。引擎通常用相机空间距离或包围体深度；这是工程差别，不是另一套混合公式。

## 6. Root Constants 传材质

材质只有 32 字节 / 8 个 DWORD，不必再开一份 256-byte CBV。Root Signature 增加：

```text
root parameter 1
    D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS
    ShaderRegister = 1   -> HLSL register(b1)
    Num32BitValues = 8
    Visibility = PIXEL
```

每 Draw 前调用：

```cpp
command_list->SetGraphicsRoot32BitConstants(
    1, 8, &material.constants, 0);
```

它把 8 个 32-bit 值嵌进命令列表，不占用 CBV/SRV/UAV heap。矩阵仍走每帧 CBV（b0），
因为 WVP 每帧变、所有物体共享同一份相机矩阵。材质每物体不同、体积小，适合 root
constants。

Root Signature 现在有 4 个参数：b0 table、b1 constants、t0 table、s0 table。
因此纹理 SRV 从原来的 root parameter 1 挪到 2，Sampler 挪到 3。改 Root Signature
后，命令列表里所有 `SetGraphicsRootDescriptorTable` 的槽号必须一起改。

### Root Signature、Root Constants 与 CBV 的内存布局

三套编号不要混：

```text
Root parameter 下标   C++ 绑定时用：SetGraphicsRoot*(slot, ...)
HLSL register         Shader 里用：b0 / b1 / t0 / s0
Descriptor heap 槽    CBV/SRV 描述符在堆里的物理位置
```

Root Signature 只是接口契约，不保存矩阵或材质字节。当前 4 个 root parameter：

```text
slot 0  DESCRIPTOR_TABLE   range=CBV  ShaderRegister=0  -> HLSL b0  只给 VS
slot 1  32BIT_CONSTANTS    ShaderRegister=1, 8 DWORD    -> HLSL b1  只给 PS
slot 2  DESCRIPTOR_TABLE   range=SRV  ShaderRegister=0  -> HLSL t0  只给 PS
slot 3  DESCRIPTOR_TABLE   range=SAMPLER ShaderRegister=0 -> HLSL s0 只给 PS
```

整份 Root Signature 有约 64 DWORD 的硬件预算：每个 root constant 占 1 DWORD，
每个 descriptor table 占 1 DWORD，每个 root CBV/SRV/UAV 描述符占 2 DWORD。
本课 8 个材质 DWORD + 3 个 table = 11 DWORD，远低于上限。

Root Signature **对象本身不是指针**。它是启动时创建的接口契约：有几个槽、每个槽
是什么类型、映射到哪个 HLSL register。真正每帧填进去的是 root 参数的**值**：

```text
DESCRIPTOR_TABLE 槽里装的是 GPU descriptor handle
    = 描述符堆里某一段的起点，可以把它想成“指向描述符的句柄/指针”
    它不指向纹理像素，也不指向矩阵字节。
    硬件再顺着那个描述符找到 Resource 的 GPU 地址。

32BIT_CONSTANTS 槽里装的是数据本身
    = 8 个 DWORD 原样嵌进命令流，没有描述符，也没有 Resource。

ROOT CBV/SRV/UAV（本课不用）槽里装的是资源 GPU 虚拟地址
    = 指向 Resource，不是指向描述符；占 2 DWORD。
```

所以“11 DWORD 预算够，材质塞进 root”说的是：这 11 个 DWORD 是 root 里当场
携带的绑定数据。其中 8 个是材质数值，3 个是三个 table 的描述符起点。预算指
root 能内联多少绑定，不是 Root Signature blob 在磁盘上的大小。

`ObjectConstants` 走 CBV，必须 256 字节对齐。真实数据只有 64 字节矩阵，其余是
填充，住在每帧一份 Upload Heap 里：

```text
ObjectConstants  CBV resource（每 Back Buffer 一份）
  +0    float4x4 world_view_projection   64 bytes
  +64   padding                          192 bytes
  合计  256 bytes = 1 个 CBV 单元
```

`MaterialConstants` 走 Root Constants，没有 Resource，也没有 256 对齐：

```text
MaterialConstants  嵌进命令列表（每 Draw 覆盖一次）
  +0    float4 base_color_factor         16 bytes   DWORD 0..3
  +16   float  metallic_factor            4 bytes   DWORD 4
  +20   float  roughness_factor           4 bytes   DWORD 5
  +24   float  alpha_cutoff               4 bytes   DWORD 6
  +28   uint   alpha_mode                 4 bytes   DWORD 7
  合计  32 bytes = 8 DWORD
```

HLSL `cbuffer` 仍按 16 字节寄存器打包。这不是 Root Constants 特有的规则，普通 CBV
也一样：编译器把常量缓冲切成连续的 `float4` 格子，每个格子 16 字节。标量不能骑
在两个格子中间；`float4` 自己就是一整格。本课材质因此是：

```text
cbuffer 格子 0 : gBaseColorFactor.xyzw                         16 bytes
cbuffer 格子 1 : metallic | roughness | cutoff | alpha_mode    16 bytes
```

C++ 结构体字段顺序必须和这个打包一致；`SetGraphicsRoot32BitConstants`
的 `DestOffsetIn32BitValues=0` 表示从 DWORD 0 起整份覆盖。

`register(b1)` **不是** API 规定“材质必须用 b1”。它只是我们自己选的常量缓冲槽号。
Root Signature 里 `Constants.ShaderRegister = 1` 必须和 HLSL 的 `register(b1)` 对上；
改成 `b3` 也行，两边一起改即可。它和 C++ 的 root parameter 下标 1 碰巧相同，不是
同一套编号。

若把材质也做成第二份 CBV，32 字节有效数据仍要占一个 256 字节单元，还要描述符
或 root CBV、以及 Fence 保护映射内存。Root Constants 把 8 个 DWORD 复制进命令
流，CPU 的 `Material` 对象可以立刻改，因为 GPU 之后读的是命令列表里的副本。

当前“两个 CBV”只是双缓冲：frame 0 和 frame 1 各有一份相同布局的 `ObjectConstants`，
防止 CPU 改写 GPU 还在读的矩阵。它们不是 b0 和 b1。b1 是 Root Constants。

## 7. Shader 里的三种覆盖度

```hlsl
float4 sampled = texture * vertexColor * gBaseColorFactor;
if (gAlphaMode == 0) sampled.a = 1;
else if (gAlphaMode == 1) {
    clip(sampled.a - gAlphaCutoff);
    sampled.a = 1;
}
return sampled;
```

`metallicFactor` / `roughnessFactor` 本节只做可见的非物理调制，证明字段已经绑定。
它们还不是 glTF metallic-roughness BRDF；真正的金属工作流在后续材质/PBR 小节。

`doubleSided` 的影子：glTF 双面会把 `CullMode` 设为 `NONE`。本节一直关剔除，是为了
不让绕序干扰 Alpha Mode 实验；完整光栅化状态所有权放到 R.7。

## 8. Alpha-weighted Mip

R.5.5 对 straight-alpha 独立平均 RGB 和 Alpha。透明像素里的 RGB 仍会进入缩小后的
颜色，MASK/BLEND 边缘可能脏。本节改为：

```text
rgb_out = sum(rgb * alpha) / sum(alpha)
a_out   = average(alpha)
```

这仍是 straight-alpha **存储**：磁盘/VRAM 里 RGB 没有提前乘 Alpha。加权只发生在
生成下一 Mip 的滤波过程。预乘 Alpha 是另一种存储约定，对应 `SrcBlend=ONE`；两者
不能混用。本课 BLEND 仍用 `SRC_ALPHA / INV_SRC_ALPHA`。

## 9. 当前场景

```text
index 0..2   OPAQUE 墙     z=0.90  写深度
index 3..5   MASK 叶片     z=0.55  clip + 写深度
index 6..8   BLEND 远玻璃  z=0.35  先混合
index 9..11  BLEND 近玻璃  z=0.12  后混合
```

四份材质共享同一张 256x256 sRGB 颜色纹理。纹理左半边接近透明、右半边不透明，
用来露出 MASK 镂空和 BLEND 覆盖度。

## 10. 真实验收

PowerShell：

```powershell
cd C:\xf\Cuda\accelerated-computing-hub\learning\sandbox
.\build.ps1 d3d12\r01-r08-mesh\d3d12_mesh_input_layout.cu -NoRun
.\d3d12\r01-r08-mesh\d3d12_mesh_input_layout.exe --frames 2 --no-vsync
```

本机 RTX 5070 / `sm_120` 实测：

```text
uploaded vertex buffer: 12 vertices, 432 bytes, stride=36
uploaded index buffer: 12 indices, 24 bytes, format=R16_UINT
materials: opaque=1 mask=1 blend=2 (blend sorted far-to-near)
uploaded 256x256 RGBA8 color texture: mips=9, typeless resource + sRGB SRV,
base_row_pitch=1024, upload=359940 bytes
rendered frames: 2
D3D12 R.5.6 material data, alpha mode and render queues: PASS
```

看画面时应能同时看到：远处实心棋盘墙、中景被 clip 掉的叶片镂空、两层半透明玻璃
按远到近叠在墙和镂空之后。

## 11. 当前简化边界

- metallic/roughness 只做可见调制，不是 BRDF。
- 没有独立的法线/金属度纹理，也没有 BC 压缩。
- 没有 OIT；多个透明物体仍靠 CPU 排序。相交透明三角形、粒子和毛发以后再处理。
- `doubleSided` 尚未按材质切换 CullMode。
- 排序用局部 z，不是相机空间距离；R.6 实例化后再讨论每实例变换下的深度。
- Debug Layer 仍放到 P.5.3 / R.7，本节不把“能出图”说成调试层已干净。

## 12. 小结

```text
Material = CPU 策略，不是 Texture，也不是 PSO
OPAQUE   = 强制 alpha=1，不透明 PSO，写深度
MASK     = clip(cutoff)，仍走不透明 PSO，镂空不写深度
BLEND    = 保留 alpha，透明 PSO，不写深度，远到近排序
队列     = CPU 按 Alpha Mode 分类后再提交 Draw
Root Constants = 把小份材质数据嵌进命令列表
Alpha-weighted Mip = 滤波时用覆盖度给 RGB 加权，存储仍是 straight-alpha
```

## 13. 自测题

1. 一张带 Alpha 的颜色纹理，为什么还可以被 `OPAQUE` 材质使用？此时 Shader 必须做什么？
2. 为什么 MASK 可以复用不透明 PSO，而不需要第三套 BlendState？
3. 为什么 BLEND 队列既要换 PSO，又要按深度排序？这两步各解决什么问题？
4. Alpha-weighted Mip 是否等于把纹理改成预乘 Alpha？为什么？
