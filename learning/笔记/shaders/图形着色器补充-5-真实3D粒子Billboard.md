# 图形着色器补充 5：真实 3D 粒子 Billboard

> **教学路线纠正（2026-09-07）**：本文件是粒子专项的后续草稿，不是完整
> HLSL/D3D12 渲染器主线。它保留用于以后讲粒子 billboard，但不能替代
> “CPU 构造 Model/View/Projection + 网格顶点/索引 + D3D12 draw”这条基础路线。
> 主线将从独立的最小网格渲染器重新开始。

## 一句话目标

把当前 position 已经接近 NDC 的简化粒子，提升为真正的 3D 粒子：

~~~text
CUDA 输出世界空间位置
    ↓
HLSL 读取粒子位置
    ↓
相机 View/Projection 变换
    ↓
用相机 right/up 基向量生成 quad
    ↓
光栅化、插值、圆形裁剪
~~~

本节讲 billboard 的几何构造和数据职责划分，不改变当前 CUDA 积分器的数值算法。

## 1. 什么是 Billboard

Billboard 是一张始终朝向摄像机的面片。粒子系统通常不为每个火花、烟尘或光点建立完整 3D 网格，而是为每个粒子生成一个很小的 quad：

~~~text
粒子中心 + 相机 right 方向 * 横向偏移
        + 相机 up    方向 * 纵向偏移
~~~

游戏开发类比是：每个粒子像一张特效卡片。卡片中心跟随粒子运动，但卡片朝向跟随摄像机，而不是固定在世界 XY 平面。

## 2. 三种位置不能混淆

~~~text
世界空间 position
    粒子在游戏世界中的物理位置，CUDA 通常生产它

观察空间 position
    乘 View 矩阵后，相对于摄像机的位置

裁剪空间 position
    再乘 Projection 矩阵后，写入 SV_Position
~~~

当前验证版把几步简化成了：

~~~text
positionSize.xy 已经接近 NDC
positionSize.z 直接作为深度
w 固定为 1
~~~

真实 3D 版本让 CUDA 写世界坐标，移动摄像机时只更新渲染侧矩阵，不需要重算物理位置。

## 3. Billboard 几何公式

设粒子中心是世界空间位置 C，摄像机在世界空间的两个正交基向量为 R 和 U：

~~~text
R = camera right
U = camera up
~~~

对 quad 局部坐标 lx、ly，世界空间角点是：

~~~text
P_world = C + R * (lx * halfWidth)
            + U * (ly * halfHeight)
~~~

正方形粒子通常令 halfWidth = halfHeight = particleSize。然后：

~~~text
P_clip = P_world * ViewProjection
~~~

这里沿用上一节的 HLSL 行向量写法；CPU 数学库若使用列向量约定，矩阵构造、上传和乘法顺序必须一起调整。

## 4. 为什么使用 camera right/up

固定世界轴的写法只适合固定在世界 XY 平面上的面片：

~~~hlsl
P_world = center + float3(local.x * size,
                          local.y * size,
                          0.0);
~~~

摄像机旋转后，面片会暴露侧面。Billboard 的 right 是屏幕水平方向在世界空间中的向量，up 是屏幕竖直方向在世界空间中的向量，因此 quad 横向和纵向始终跟随摄像机。

## 5. HLSL 教学版本

下面继续使用 SV_VertexID 生成六个角点，不需要传统 Vertex Buffer：

~~~hlsl
cbuffer FrameConstants : register(b0)
{
    // CPU 必须用与 shader 一致的矩阵方向和布局上传。
    row_major float4x4 viewProjection;

    // 世界空间正交方向；w=0 表达方向而不是位置。
    float4 cameraRight;
    float4 cameraUp;

    float2 viewportSize;
    float2 inverseViewportSize;
};

StructuredBuffer<float4> gWorldPositions : register(t0);
StructuredBuffer<float4> gColors         : register(t1);

struct VertexOutput
{
    float4 clipPosition : SV_Position;
    float4 color : COLOR0;

    // 交给 Pixel Shader 做圆形裁剪，必须保持普通插值。
    float2 localPosition : TEXCOORD0;
};

VertexOutput VSMain(uint vertexId : SV_VertexID,
                    uint instanceId : SV_InstanceID)
{
    static const float2 corners[6] =
    {
        float2(-1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0),
        float2(-1.0, -1.0),
        float2( 1.0,  1.0),
        float2( 1.0, -1.0)
    };

    // xyz 是 CUDA 生产的世界空间中心；w 保存世界单位半径。
    const float4 positionWorld = gWorldPositions[instanceId];
    const float2 local = corners[vertexId];
    const float halfSize = positionWorld.w;

    // cameraRight/cameraUp 是方向，加入偏移时不应带平移。
    const float3 worldOffset =
        cameraRight.xyz * (local.x * halfSize) +
        cameraUp.xyz * (local.y * halfSize);
    const float3 worldCorner =
        positionWorld.xyz + worldOffset;

    VertexOutput output;
    // worldCorner 是位置点，w=1；ViewProjection 的平移和透视会生效。
    output.clipPosition =
        mul(float4(worldCorner, 1.0), viewProjection);
    output.color = gColors[instanceId];
    output.localPosition = local;
    return output;
}
~~~

与当前验证版的区别：

~~~text
当前版：
    center.xy + local * NDC radius
    直接写简化的裁剪位置

3D 版：
    center_world + right/up * world radius
    再乘 ViewProjection
~~~

## 6. camera right/up 从哪里来

相机世界空间旋转矩阵的轴向量就是相机的基向量。具体取矩阵的行还是列，取决于 CPU 数学库和向量约定，不能脱离约定死记下标。

~~~text
cameraRight   = 相机局部 +X 轴变换到世界空间
cameraUp      = 相机局部 +Y 轴变换到世界空间
cameraForward = 相机局部 +Z 或 -Z 轴变换到世界空间
~~~

cameraForward 的正负号受左右手坐标系影响。Billboard 只需要正确的 right/up。

CPU 端应保证：

~~~text
length(cameraRight) ≈ 1
length(cameraUp) ≈ 1
dot(cameraRight, cameraUp) ≈ 0
~~~

如果基向量带缩放或不正交，粒子会变成椭圆或发生倾斜。

## 7. 世界尺寸与屏幕尺寸

真实 3D billboard 的半径通常使用世界单位：

~~~text
远处粒子：裁剪空间 w 更大 → 透视除法后 quad 更小
近处粒子：裁剪空间 w 更小 → 透视除法后 quad 更大
~~~

当前 NDC 粒子使用固定 NDC 半径，不会因为 z 变大而自动缩小。

~~~text
world-space size：
    适合烟雾、火花、尘土
    受距离和 FOV 影响

screen-space size：
    适合 HUD、标记点、编辑器控制柄
    屏幕上保持近似固定大小
~~~

如果需要固定像素大小，必须根据距离、投影参数和 viewport 反推世界单位半径，这是另一种尺寸策略。

## 8. Constant Buffer 的 CPU 接口

教学上可以用显式 16-byte 成员表达接口：

~~~cpp
struct FrameConstantsCpu {
  // 4x4 float 矩阵 = 64 bytes。
  // 元素顺序必须与 CPU 数学约定和 shader 布局一致。
  float view_projection[16];

  // 方向用 float4，最后一个分量固定为 0。
  float camera_right[4];
  float camera_up[4];

  // 两个 float2 总共 16 bytes。
  float viewport_size[2];
  float inverse_viewport_size[2];
};

// 64 + 16 + 16 + 8 + 8 = 112 bytes。
static_assert(sizeof(FrameConstantsCpu) == 112);

constexpr UINT Align256(UINT size)
{
  return (size + 255u) & ~255u;
}
~~~

真实项目还必须确认 CPU 矩阵方向、行列排列、HLSL row_major/column_major、cbuffer packing、CBV 256-byte 对齐以及上传资源生命周期。

## 9. Root Signature 如何增加 b0

当前项目只有覆盖 t0/t1 的 SRV range。增加相机 CBV 时至少声明：

~~~cpp
D3D12_DESCRIPTOR_RANGE cbv_range{};
cbv_range.RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_CBV;
cbv_range.NumDescriptors = 1;
cbv_range.BaseShaderRegister = 0;  // register(b0)
cbv_range.RegisterSpace = 0;
cbv_range.OffsetInDescriptorsFromTableStart = 0;
~~~

一种清晰的组织是：

~~~text
root parameter 0 → CBV descriptor table，b0
root parameter 1 → SRV descriptor table，t0/t1
~~~

CBV 和 SRV 都可以放在同一个 CBV_SRV_UAV shader-visible heap 中，但两个 root table 的起始 GPU handle 必须正确。

每帧更新相机时，不能覆盖 GPU 仍在读取的同一段常量内存。通常使用环形常量缓冲，每帧取得新的 256-byte 对齐区段，结合 Fence 判断何时可以复用。

## 10. 粒子 Buffer 数据约定

真实 3D 版可以继续采用当前 SoA：

~~~text
positionWorld[N] : float4
velocity[N]      : float4
color[N]         : float4
~~~

其中：

~~~text
positionWorld.xyz → 世界空间中心
positionWorld.w   → 世界单位半径
~~~

CUDA 的 base pointer 偏移和 D3D12 的两个 SRV 都可以保持不变，主要改变的是 position 的语义。

## 11. 常见错误

### 错误 1：把世界坐标直接写入 SV_Position

~~~hlsl
output.clipPosition = float4(worldCorner, 1.0);
~~~

真实世界坐标必须先经过 ViewProjection。

### 错误 2：六个顶点都输出中心坐标

六个顶点重合，三角形面积为零，不会产生可见 quad。每个角必须加入不同的 right/up 偏移。

### 错误 3：用世界 X/Y 代替 camera right/up

摄像机旋转后面片会侧翻，因为它仍固定在世界平面。

### 错误 4：把方向的 w 写成 1

cameraRight/cameraUp 是方向，w=0；worldCorner 是位置，w=1。混用会把平移错误地加入偏移。

### 错误 5：混淆 world-space size 和 screen-space size

世界半径固定时远处变小；NDC 半径固定时屏幕大小近似不变。

### 错误 6：只改 shader，不更新 CBV 绑定

声明 b0 后，D3D12 还必须提供 CBV descriptor、root parameter/range、shader-visible heap 中的 descriptor，以及 descriptor table 或 root CBV 绑定。

## 12. 与当前项目的迁移边界

当前已验证的 CUDA/D3D12 程序可以保持不变：

~~~text
CUDA：
    继续更新现有 SoA Buffer

D3D12：
    继续使用 External Memory 和 Fence
    继续使用 t0/t1 SRV

真实 3D 版本新增：
    position 改用 world-space 语义
    新增 FrameConstants CBV
    VS 使用 cameraRight/cameraUp + ViewProjection
~~~

要真正运行这个版本，还需要在 C++ 渲染器中完成 CBV 创建、每帧上传和 root table 绑定。本节先建立 shader 与资源契约，不直接改动当前互操作验证程序。

## 13. 动手练习

### 练习 A：手算一个 Billboard 顶点

~~~text
C = (10, 2, 5)
R = (1, 0, 0)
U = (0, 1, 0)
halfSize = 0.5
local = (1, -1)
~~~

计算：

~~~text
P_world = C + R*(local.x*halfSize)
           + U*(local.y*halfSize)
~~~

应得到右下角世界位置。摄像机旋转时 R/U 会改变，但 C 不应改变。

### 练习 B：验证透视缩放

比较两个 world-space halfSize 相同的粒子：一个距离摄像机 2 米，一个距离摄像机 20 米。预测远处粒子的屏幕尺寸更小，再和当前 NDC 版本对比。

### 练习 C：检查方向的 w

~~~hlsl
float4(cameraRight.xyz, 0.0)  // 方向
float4(worldCorner, 1.0)      // 位置
~~~

说明两处为什么不同，并指出如果都写成 1.0，平移会如何错误地施加到偏移上。

## 14. 小结

- Billboard 是面向摄像机的 quad，不是固定在世界 XY 平面的 quad。
- 粒子中心通常由 CUDA 以世界空间坐标生产；相机矩阵属于渲染侧。
- quad 顶点公式是 C + right*offsetX + up*offsetY。
- right/up 是方向，使用 w=0；worldCorner 是位置，使用 w=1。
- SV_Position 必须接收裁剪空间坐标，世界坐标要先乘 ViewProjection。
- world-space 粒子大小会自然产生远小近大；screen-space 大小保持近似固定。
- 新增 b0 后，D3D12 还要增加 CBV、Root Signature、Descriptor Heap 和绑定命令。
- CUDA 的 SoA、External Memory、Fence 和 SRV 结构可以保留，改变的是 position 语义和 VS 变换。

## 自测题

1. 为什么真实 3D billboard 要用 camera right/up，而不能一直使用世界 X/Y 轴？
2. 公式 P_world = C + R*(lx*size) + U*(ly*size) 中，C、R、U、lx/ly 分别是什么？为什么 R/U 是方向而 C 是位置？
3. 为什么世界空间粒子会随距离变小，而当前 NDC 粒子不会？
4. HLSL 增加 cbuffer FrameConstants : register(b0) 后，D3D12 侧除了写 shader，还必须增加哪些对象和绑定步骤？
5. 如果六个 quad 顶点都输出粒子中心经过 ViewProjection 后的同一个坐标，为什么不会得到一个可见粒子？

## 下一节预告

下一节讲纹理采样和粒子材质：Texture2D/Sampler、GLSL sampler、纹理坐标插值，以及如何把圆形粒子升级成带软边、噪声、火焰或序列帧的 GPU 粒子材质。

## 官方资料

- D3D12 constant buffers: https://learn.microsoft.com/windows/win32/direct3d12/constant-buffers
- HLSL constant buffer packing: https://learn.microsoft.com/windows/win32/direct3dhlsl/dx-graphics-hlsl-packing-rules
- HLSL matrix type: https://learn.microsoft.com/windows/win32/direct3dhlsl/dx-graphics-hlsl-matrix
- HLSL semantics: https://learn.microsoft.com/windows/win32/direct3dhlsl/dx-graphics-hlsl-semantics
- D3D12 root signatures: https://learn.microsoft.com/windows/win32/direct3d12/root-signatures
