# R.11 收束：资源绑定与程序选择

本节不新增功能。R.11 的核心范围是 State Object、Shader Table、Hit Group、根参数与最小 DispatchRays；resize、设备移除恢复、多帧动态 SBT 属于后续工程化，不再作为本章不断延长的完成条件。R.12 既有预实现保留，但不算当前正式课程推进。

## 两条独立的输入链

- 数据链：BLAS/TLAS 构建 → GPU 依赖 → 全局根 SRV(t0)；输出 Buffer → 根 UAV(u0)。纹理 UAV 则通过描述符堆/表绑定。
- 程序链：HLSL → DXIL library → State Object → 查询 Identifier → 写入 SBT → DispatchRays 指定表。

TLAS 不生成 State Object。两者是执行 TraceRay 时共同需要的输入。Root Signature 声明资源接口，State Object 定义可执行程序与配置，SBT 提供程序选择记录及可选局部数据。

## 沿 ray[7] 走一遍

源码：learning/sandbox/d3d12/r11-04-geometry-raytype/dxr_geometry_raytype.hlsl:10–20。

x=7 时，RayGen 构造目标为物理实例1、geometry1的射线，rayContribution=1。几何仍由真实求交确认，RayGen 的局部变量不会直接指定命中结果。正常实例基址为4，geometry乘数为2，因此 record=4+1*2+1=7。

宿主 learning/sandbox/d3d12/r11-04-geometry-raytype/dxr_geometry_raytype_pipeline.cu:232–247 中，SBT起点为base，Hit表从base+128开始。record7地址为base+128+7*64=base+576。

record前32B是ShadowGroup identifier；+32处recordCode=0x00011100；+36处cookie=0x5a。Local Root Signature把这8B解释为b0两个DWORD。ShadowGroup指定ShadowHit，后者写出0xb0011107。这里Shadow仅是用途标签，不是实际阴影算法。

TraceRay返回后，RayGen将payload写入output[7]。输出Buffer转COPY_SOURCE、复制到Readback、提交并Signal Fence；CPU等Fence后Map读取。

## 三种不同数据

- Global root arguments：本例TLAS地址与输出地址，通过命令列表设置。
- Local root arguments：本例recordCode/cookie，由选中record携带；不是SetComputeRoot32BitConstants设置。
- Payload：一次TraceRay的动态输入输出，不是SBT局部参数；本例只有4B code。

## 本轮复验

2026-10-09 运行现有exe与DXIL，未重新编译。正常及--swap-bases两轮八项均符合预期，Fence1/1，InfoQueue errors=0 warnings=0，进程exit0。正常ray[7]=0xb0011107；交换基址后ray[7]=0xb0001107。GPU-based validation未开启，本轮不重新验收窗口版。

## 纠正此前表述

复制呈现时，中间输出纹理为COPY_SOURCE，Back Buffer必须为COPY_DEST，再转PRESENT。RTV/RENDER_TARGET只在实际渲染目标操作中使用，不能用RENDER_TARGET状态代替复制目标状态。

## 自测与答案

1. 只改InstanceID会改变Hit record索引吗？不会；它不在索引公式中。
2. 同identifier不同local参数会执行不同程序吗？不会自动换程序；同程序会读到不同局部数据。
3. 修改SBT字节就会重新编译Shader吗？不会；但必须保证记录布局合法且不覆盖GPU在用的内容。

生产引擎往往缓存State Object和SBT、用小索引查全局材质表、按Fence管理多帧资源。本课以静态小表和串行读回隔离机制，不是生产架构。

官方规范：https://microsoft.github.io/DirectX-Specs/d3d/Raytracing.html
