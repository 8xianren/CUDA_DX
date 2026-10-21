# 图形着色器补充 1：HLSL 与 GLSL 的共同骨架

## 一句话目标

看完这一节，你能把当前 D3D12 粒子 shader 从 `StructuredBuffer`、`SV_VertexID/SV_InstanceID`、`SV_Position` 到 `clip` 的完整数据流讲清楚，并能把它翻译成 GLSL 的 SSBO、`gl_VertexID/gl_InstanceID`、`gl_Position` 和 `discard`。

## 1. 先建立共同模型：两个阶段，不是两个 CUDA kernel

当前粒子绘制的逻辑可以画成：

```text
每个粒子实例
  + 每个实例的 6 个顶点
        │
        ▼
Vertex Shader（VS）
  读取 position/color
  生成 quad 的 6 个顶点
  输出裁剪空间位置 + 要传给像素阶段的值
        │
        ▼
图元装配 + 光栅化
  两个三角形覆盖哪些屏幕像素
  对 VS 输出做插值
        │
        ▼
Pixel Shader（HLSL）/ Fragment Shader（GLSL）
  每个覆盖到的 fragment 执行一次
  用局部坐标裁成圆并输出颜色
```

它和 CUDA kernel 有相似点：都是大量相似 invocation 并行执行，也会遇到寄存器、访存、分支发散。但图形 shader 还有固定的图形管线契约：

- VS 的输出位置决定图元在屏幕上的位置。
- 光栅化器决定 PS/FS 被调用哪些 fragment。
- VS→PS/FS 之间的普通变量默认会按三角形做插值。
- `SV_*`（HLSL）或 `gl_*`（GLSL）是管线规定的内建输入/输出，不是普通自定义数组。

所以不能把 PS/FS 简单理解成“对每个粒子执行一次”。一个粒子的 quad 可能覆盖很多 fragment，像素阶段的调用次数取决于屏幕覆盖范围和光栅化结果。

## 2. HLSL 当前代码逐段阅读

文件：`C:\xf\Cuda\accelerated-computing-hub\learning\sandbox\particles\p04-p05-renderer\d3d12_static_particles.hlsl`

### 2.1 `StructuredBuffer` 与 D3D12 SRV

```hlsl
StructuredBuffer<float4> gPositions : register(t0);
StructuredBuffer<float4> gColors    : register(t1);
```

含义分成两层：

1. `StructuredBuffer<float4>`：shader 看到的是一组连续的 16-byte 结构化元素，可以用 `gPositions[index]` 读取。
2. `register(t0)`/`register(t1)`：把资源绑定到 D3D12 的 SRV 寄存器槽位 t0/t1。它不是 CPU 虚拟地址，也不是 CUDA pointer。

CPU 端通过 SRV 描述符把同一块 SoA allocation 的不同区间接到这两个槽位：

```text
Buffer 元素区间：
[0, N)       position  → t0 → gPositions
[N, 2N)     velocity  （本 shader 不绑定）
[2N, 3N)    color     → t1 → gColors
```

`FirstElement` 的单位是 `float4` 元素，不是 byte；这就是 color 使用 `2*N` 而不是 `2*N*16` 的原因。

### 2.2 `SV_VertexID` 和 `SV_InstanceID`

```hlsl
VertexOutput VSMain(uint vertexId : SV_VertexID,
                    uint instanceId : SV_InstanceID)
```

调用：

```cpp
DrawInstanced(6, 4096, 0, 0);
```

会产生：

```text
instanceId = 0..4095       选择粒子
vertexId   = 0..5          选择这个粒子的 6 个 quad 顶点
```

因此没有传统 Vertex Buffer。六个局部角点由 HLSL 常量数组生成，真正从共享 Buffer 读取的只有粒子 position/color。

### 2.3 `SV_Position` 与裁剪空间

```hlsl
output.clipPosition = float4(
    positionSize.xy + local * screenCorrectedRadius,
    positionSize.z,
    1.0);
```

VS 输出的 `SV_Position` 在光栅化前属于裁剪空间；经过透视除法后进入 NDC，通常 x/y 在 `[-1, 1]`。本例没有投影矩阵，直接把粒子位置当作 NDC 附近的位置使用。

宽高比修正是必要的：1280×720 窗口中，x 方向每个 NDC 单位对应 640 像素，y 方向对应 360 像素。若 x/y 半径相同，屏幕上的圆会变成椭圆，所以代码使用：

```hlsl
float2(positionSize.w * (720.0 / 1280.0), positionSize.w)
```

### 2.4 普通输出变量会被插值

```hlsl
output.color = gColors[instanceId];
output.localPosition = local;
```

`color` 和 `localPosition` 不是系统值。三角形覆盖 fragment 后，光栅化器会根据 fragment 在三角形内的位置，对它们做透视相关的插值。这样 PS 能得到每个像素自己的局部坐标。

### 2.5 `clip` 如何把 quad 裁成圆

```hlsl
float radiusSquared = dot(input.localPosition,
                          input.localPosition);
clip(1.0 - radiusSquared);
```

局部坐标范围约为 `[-1, 1]²`：

```text
x² + y² <= 1  → 单位圆内部，保留
x² + y² >  1  → 圆外，clip 丢弃 fragment
```

`clip(x)` 在 x<0 时丢弃当前 fragment。它不是修改深度，也不是把颜色设成透明；该 fragment 根本不会写入 Render Target。

## 3. GLSL 的一一对应写法

GLSL 没有 HLSL 的语义字符串 `SV_*`，而是使用 `gl_*` 内建变量和 `layout(location=...)`/`layout(binding=...)`。

下面是与当前 HLSL 逻辑等价的 GLSL 4.50 示例。它是语法对照代码，实际 Vulkan 程序还需要创建 descriptor set/layout，并把 binding 0/1 接到对应的 buffer。

### 3.1 GLSL Vertex Shader

```glsl
#version 450

// std430 规定 SSBO 的成员布局规则。这里数组元素是 vec4，
// 每个元素 16 bytes，正好对应 CUDA/D3D12 侧的 float4。
// binding=0 是 descriptor binding 编号，不是 GPU 虚拟地址。
layout(std430, binding = 0) readonly buffer Positions {
    vec4 gPositions[];
};

layout(std430, binding = 1) readonly buffer Colors {
    vec4 gColors[];
};

// location=0/1 是 VS 到 FS 之间的接口槽位。
// 默认插值方式是 smooth（透视相关插值）；如果要传整数或不插值的值，
// 必须显式使用 flat，并保证两端声明匹配。
layout(location = 0) out vec4 vColor;
layout(location = 1) out vec2 vLocalPosition;

void main()
{
    // gl_VertexID 对应 HLSL 的 SV_VertexID；
    // gl_InstanceID 对应 HLSL 的 SV_InstanceID。
    const vec2 corners[6] = vec2[6](
        vec2(-1.0, -1.0),
        vec2(-1.0,  1.0),
        vec2( 1.0,  1.0),
        vec2(-1.0, -1.0),
        vec2( 1.0,  1.0),
        vec2( 1.0, -1.0)
    );

    const uint vertexId = uint(gl_VertexID);
    const uint instanceId = uint(gl_InstanceID);
    const vec4 positionSize = gPositions[instanceId];
    const vec2 local = corners[vertexId];

    // 与 HLSL 相同：x 半径乘 height/width，避免宽屏中圆变椭圆。
    const float aspectCorrection = 720.0 / 1280.0;
    const vec2 screenCorrectedRadius =
        vec2(positionSize.w * aspectCorrection, positionSize.w);

    // GLSL 的 gl_Position 对应 HLSL 的 SV_Position。
    gl_Position = vec4(
        positionSize.xy + local * screenCorrectedRadius,
        positionSize.z,
        1.0);

    vColor = gColors[instanceId];
    vLocalPosition = local;
}
```

### 3.2 GLSL Fragment Shader

```glsl
#version 450

layout(location = 0) in vec4 vColor;
layout(location = 1) in vec2 vLocalPosition;

// location=0 对应当前渲染目标的第一个颜色附件。
layout(location = 0) out vec4 outColor;

void main()
{
    const float radiusSquared = dot(vLocalPosition, vLocalPosition);

    // GLSL 没有 HLSL 的 clip(x)；用 discard 丢弃当前 fragment。
    if (1.0 - radiusSquared < 0.0) {
        discard;
    }

    // GLSL 没有标准 saturate；clamp(x, 0, 1) 是对应写法。
    const float edgeLighting =
        0.55 + 0.45 * clamp((1.0 - radiusSquared) * 4.0,
                             0.0, 1.0);
    outColor = vec4(vColor.rgb * edgeLighting, 1.0);
}
```

## 4. HLSL/GLSL 语法对照表

| 概念 | HLSL | GLSL |
|---|---|---|
| 标量浮点 | `float` | `float` |
| 2/3/4 向量 | `float2/3/4` | `vec2/3/4` |
| 无符号整数 | `uint` | `uint` |
| 位置系统值 | `SV_Position` | `gl_Position`（VS 输出） |
| 顶点编号 | `SV_VertexID` | `gl_VertexID` |
| 实例编号 | `SV_InstanceID` | `gl_InstanceID` |
| 像素颜色输出 | `SV_Target0` | `layout(location=0) out vec4` |
| 资源槽位 | `register(t0)` | `layout(binding=0)` |
| 结构化只读 Buffer | `StructuredBuffer<T>` | `readonly buffer` + SSBO |
| 丢弃 fragment | `clip(x)` | `discard`（通常配合 `if`） |
| [0,1] 饱和 | `saturate(x)` | `clamp(x, 0.0, 1.0)` |
| 向量点积 | `dot(a,b)` | `dot(a,b)` |
| 顶点阶段 | Vertex Shader | Vertex Shader |
| 像素阶段 | Pixel Shader | Fragment Shader |

这里有一个容易混淆的边界：`register(t0)` 和 `binding=0` 都是“接口编号”，但它们属于不同图形 API 的资源绑定模型。它们不是 CUDA pointer，也不能直接拿来当作跨 API 的物理地址。

## 5. 与 CUDA 共享 Buffer 的关系

当前链条是：

```text
CUDA pointer
  → CUDA kernel 写 float4 position/color
  → external semaphore signal
  → D3D12 queue wait
  → SRV t0/t1
  → HLSL VS/PS 读取
```

CUDA 负责“生产数据”，HLSL 负责“把数据变成图元和像素”。

External Semaphore/Fence 解决的是跨 API 的先后关系；SRV/SSBO 解决的是 shader 如何解释内存；`ResourceBarrier` 解决的是 D3D12 资源状态。三者是正交职责，不能互相替代。

## 6. 编译模型差异

当前 D3D12 程序使用：

```cpp
D3DCompileFromFile(..., "VSMain", "vs_5_1", ...);
D3DCompileFromFile(..., "PSMain", "ps_5_1", ...);
```

也就是 HLSL → DXBC（shader model 5.x 路径）并交给 D3D12 PSO。现代 Windows 项目也常使用 DXC，把 HLSL 编译成 DXIL。

Vulkan 通常把 GLSL 编译成 SPIR-V，再创建 shader module；OpenGL 则可能由驱动在运行时编译 GLSL。无论后端是 DXIL、SPIR-V 还是驱动内部表示，shader 源码都不是 CUDA C++ kernel：执行入口、资源绑定、同步和输出契约都不同。

## 7. 动手练习

1. 在 `d3d12_static_particles.hlsl` 中暂时注释 `clip(1.0 - radiusSquared);`，重新编译运行。你会看到圆粒子变成方片；这验证了圆形来自 Pixel Shader 的 fragment discard，而不是 Vertex Shader 的几何形状。
2. 把 `gColors[instanceId]` 改成 `float4(1, 0, 0, 1)`，确认 CUDA 仍然更新位置，但颜色已不再从共享 Buffer 读取。
3. 把 `output.localPosition = local;` 改为 `output.localPosition = 0.5 * local;`，预测圆形裁剪区域会怎样变化，然后运行验证。
4. 对照上面的 GLSL 版本，标出四组接口：SSBO binding、VS 输出 location、FS 输入 location、FS 输出 location。接口编号对不上时，通常不是 CUDA 算法错，而是 shader linkage/descriptor layout 错。

## 8. 小结

- HLSL 和 GLSL 的核心图形管线模型相同：VS 生成顶点，光栅化产生 fragment，PS/FS 输出颜色。
- HLSL 用语义 `SV_*`，GLSL 用 `gl_*` 内建变量和 `layout(...)` 接口限定。
- `StructuredBuffer<float4>` 对应 GLSL 的 SSBO 数组；`register(t0)` 对应资源接口编号，而不是地址。
- `SV_Position`/`gl_Position` 是裁剪空间位置；普通 VS 输出会在三角形内插值。
- HLSL `clip` 与 GLSL `discard` 都能丢弃 fragment，但语法和精确语义不应混写。
- CUDA 写入共享 Buffer 后，Fence、Resource Barrier、SRV/SSBO、shader 计算分别承担不同职责。

## 自测题

1. 为什么一个粒子调用一次 `DrawInstanced` 后，Pixel Shader 的执行次数不一定等于粒子数？
2. `register(t0)`/`layout(binding=0)` 为什么不能当作 CUDA device pointer？
3. 如果 VS 输出的 `localPosition` 在 HLSL 中标成 `nointerpolation`，圆形裁剪会发生什么变化？GLSL 中对应的接口限定符是什么？

## 官方资料

- [HLSL Semantics](https://learn.microsoft.com/windows/win32/direct3dhlsl/dx-graphics-hlsl-semantics)
- [HLSL StructuredBuffer](https://learn.microsoft.com/windows/win32/direct3dhlsl/sm5-object-structuredbuffer)
- [D3D12 Root Signatures](https://learn.microsoft.com/windows/win32/direct3d12/root-signatures)
- [OpenGL Shading Language Specification](https://registry.khronos.org/OpenGL/specs/gl/)
- [Vulkan Shader Resource Binding](https://docs.vulkan.org/guide/latest/shader_memory_layout.html)
