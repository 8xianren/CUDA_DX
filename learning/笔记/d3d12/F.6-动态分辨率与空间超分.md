# F.6 动态分辨率与空间超分：双线性、双三次、官方 NIS

[F 主线程序](../../sandbox/d3d12/aa-reconstruction/README.md) · [上一节 TAA](F.5-历史重投影与拒绝.md)

目标是让内部渲染尺寸在显示尺寸的 50%–100% 间变化，正确重建输出、保持 UI 像素尺寸，并测量质量、GPU 时间和资源成本。本节使用真实 D3D12 shader：`post.hlsl:121` 双线性、`:131` 双三次，以及 `shaders/nis.hlsl` 包装的官方 NIS。空间超分只读取当前帧，不依赖深度、motion 或历史。

## 1. 为什么一定要有两套尺寸

显示分辨率是最终交换链/呈现图像的尺寸；内部渲染分辨率是 scene pass 产生颜色与深度的尺寸。若横纵比例均为 s，则像素数约为原来的 s²：50% 是四分之一像素，不是二分之一。显存与工作量不会恰好缩成四分之一，因为显示尺寸的输出、历史、UI 和固定成本仍存在。

游戏类比是先在小画布上绘制 3D 场景，再放大到显示画布，最后以显示画布像素画文字。若把文字画在小画布再一起放大，字号也许勉强相同，但边缘与细节已经被低分辨率采样损失；本课 UI 在放大后单独合成。

## 2. 从像素中心约束推导缩放坐标

输出第 x 个像素中心是 `x+0.5`，它在整幅图中的相对位置是 `(x+0.5)/Wout`。要找内部图上的同一相对位置，乘 Win；纹理的整数 texel 索引指向中心而不是左边界，因此再减 0.5：

```text
sourceX = (outputX + 0.5) × Win/Wout − 0.5
sourceY = (outputY + 0.5) × Hin/Hout − 0.5
```

这两个 0.5 不是随便补的“D3D 偏移魔法”，它们来自明确的像素中心定义。若漏掉其中一个，同尺寸 identity 都会发生半像素位移。CPU oracle 同时检查 1.0、1.5、2.0 倍输出与常量场，避免只在某一个比例看着正常。

双线性设源坐标为 `i+f`，由相邻两个采样点的插值约束得到 `(1−f)C_i+fC_(i+1)`，二维为两个轴权重的乘积，实际读取四个 texel。硬件 linear sampler 完成相同运算；边缘使用 clamp，意味着范围外复制边缘值。

双三次使用每轴四个 texel、二维共 16 个。选择 Catmull–Rom 的理由是插值节点、连续的一阶导数与较清晰的边缘响应。核具有负权重，所以亮边可能过冲，暗边可能产生负值，这叫 ringing（振铃）。本课输出保留真实核结果用于评测，不先偷偷 saturate 再声称算法没有振铃；最终显示 tone mapping/编码是另一个阶段。

## 3. 动态比例牵动哪些合同

内部 viewport/scissor、颜色/深度/MV 纹理尺寸同步变更；显示 viewport 保持显示尺寸。UV 单位 MV 本身不依赖像素数，但转给 SDK 的内部像素 MV 必须乘当帧内部宽高；jitter 的“半个像素”也要按内部尺寸除，不能用显示尺寸除。

**内部 viewport 尺寸与相机投影 aspect 分开。** 例如 640×360 输出的相机比例为 16:9，但 Quality 档整数内部尺寸可能是 426×240，比例约 1.775，并不恰好为 16:9。若每次把内部宽高比直接塞回投影矩阵，会悄悄改变水平视锥，误差里就混进了不同相机。最终统一序列由 `SceneFrame.outputAspect` 显式传入 `outputWidth/outputHeight`，所有重建模式保持同一个投影；内部整数 viewport 只决定采样格点数量。F.1/F.4 的固定尺寸专项实验未指定这个覆盖项时，仍使用各自既定的 viewport 比例。

本课切换内部尺寸时重建相关纹理并重置历史。能够保留历史的动态分辨率算法需要另定义旧尺寸的重投影与采样范围；不要只改一个 renderScale 数字就保留未经证明的历史。

纹理 mip 也不能忽略。内部像素覆盖的屏幕范围变大，隐式导数会选择更粗 mip。若为了给后续重建保留细节采用 `lodBias=log2(renderScale)`，50% 对应 −1，即向更细一级偏移；它可能恢复纹理锐度，也可能重新引入 aliasing。正确实验要同时报告比例和 LOD bias，不能把锐度变化全部归因于超分算法。

GPU 时间来自 timestamp，纹理成本可以先按各资源尺寸×每 texel 字节推导，再核对 D3D12 allocation size。RGBA16F 是 8B/texel，RGBA32F 为 16B/texel，R32F 为 4B，RG16F 为 4B，R8 为 1B；MSAA、mip、对齐和 SDK 内部资源另计。输出分辨率不变意味着重建 pass 的输出成本仍接近常数。

## 4. 官方 NIS 的可复现接入

本课锁定 NVIDIAImageScaling commit `35e13ba316c98eeecf16f37eae70ce88019911f6`，源文件标记 v1.0.3。`nis.lock.json` 保存三个源文件 SHA-256；`fetch_nis.py` 从该 commit 下载到 `external/nis/` 并逐文件验证。原文件保留 MIT 版权/许可头，不修改官方算法；external 不作为我们编写的课程源码提交。

```powershell
python learning/sandbox/d3d12/aa-reconstruction/fetch_nis.py
```

NIS 使用方向自适应空间滤波与锐化。与双三次的固定核相比，它依据局部边缘结构改变滤波。当前入口是官方 `NVScaler`，不是把本课 `SharpenCS` 改名叫 NIS。官方实现的结构和集成要求见 [NVIDIA Image Scaling 仓库](https://github.com/NVIDIAGameWorks/NVIDIAImageScaling) 与 [NVIDIA 产品文档](https://developer.nvidia.com/rtx/image-scaling)。

输入为线性 HDR 时 shader 宏 `NIS_HDR_MODE=1`，CPU 更新配置也使用 `NISHDRMode::Linear`。两边不一致会导致阈值与亮度处理约定不同。固定 `NIS_BLOCK_WIDTH=32`、`NIS_BLOCK_HEIGHT=24`、`NIS_THREAD_GROUP_SIZE=128`：每组 128 线程协同输出 32×24 个像素，不能按普通“一线程一像素”的公式 dispatch，应调用 `Dispatch(ceil(Wout/32),ceil(Hout/24),1)`。

绑定为 t0 输入颜色、t1/t2 两张官方系数表、u0 输出、s0 linear clamp。每张系数表是 2×64 的 RGBA32F，等价于每相位 8 个 float、每行 32B；上传到 D3D12 时仍须遵守 copy footprint 的 RowPitch 对齐，不能把紧密 32B 直接当成 copy pitch。

NIS 的 b0 与 PostConstants **不是同一结构**。官方 `NISConfig` 的有效字段是前 112 字节（28 DWORD），C++ 类型按 256 字节对齐，方便 CBV；本课也可把 28 DWORD 作为 root constants 上传。必须切换到对应 PSO/根参数数据，不能把 TAA 的 16 DWORD 原样传给 NIS。

host 调用 `NVScalerUpdateConfig`，参数依次是 config、sharpness、输入 viewport 原点/尺寸/纹理尺寸、输出 viewport 原点/尺寸/纹理尺寸、HDR mode。完整屏幕无裁剪时两组原点均为 0，viewport 尺寸等于纹理尺寸。函数返回 false 应中止该模式或回退双线性；本课锁定版本要求输入/输出轴向比例在 [0.5,1]，不能任意放大 4 倍后忽略失败。

## 5. 动手、自测与边界

统一程序把比例设为 1.0、约 2/3、0.5，并保持显示尺寸与相机参数相同；输出 UI 在最后合成。比较相同帧的 No AA/full resolution、bilinear、bicubic、NIS，再观察运动序列，避免把单张锐化截图当成时域稳定性结论。质量、GPU 时间和资源记录位于本课 `results/f6/` 与 F.10 报告。

独立 oracle 的双线性/双三次常量场、identity、50%–100% 输入比例验证可用 F.5 的 `f_lessons.exe oracle` 流程复跑。2026-10-22 的 GPU oracle 中，两种滤波的同尺寸 identity 误差均为零；双三次最大误差 **3.37760×10⁻⁷**，双线性 1.5 倍输出最大误差 **1.08515×10⁻⁴**，均低于预设 2×10⁻⁴ 容差。CPU 双精度的理想双线性与硬件 sampler 不要求逐位一致；这不应被混同为颜色半精度量化，因为此 oracle 输入输出都是 RGBA32F。

真实 RTX 5070 suite 已执行 4 个比例×3 个方法，包含官方 NIS；输出始终 640×360，UI **88,704 个通道检查**全部相同。Debug Layer 开启的单次 timestamp 中，320×180→640×360 的双线性约 0.02 ms，双三次与 NIS 约 0.04 ms；仅作为确实执行的量级证据，正式性能比较应采用 F.10 关闭调试层的重复运行。资源集合包含本课 scene MRT、depth、output、diagnostic 与 display，320×180 内部约 9,240,576B，640×360 内部约 15,990,784B；它不是全部进程显存或 SDK 私有内存。原始数据见 [scaling.csv](../../sandbox/d3d12/aa-reconstruction/results/f6/scaling.csv) 与 [UI/比例报告](../../sandbox/d3d12/aa-reconstruction/results/f6/summary.json)。

最终固定场景的 120 帧比较中，下面三种方法均从 **320×180** 重建到 **640×360**，输入像素数相同，投影纵横比也统一来自输出。参考为同帧 2560×1440 光栅化后 4×4 box，显示变换为固定曝光、Reinhard、sRGB。

|空间重建方法|线性 HDR MSE|显示域 MAE|显示域 PSNR/dB|参考误差相邻帧变化 RMS|
|---|---:|---:|---:|---:|
|双线性|0.020018|0.038943|22.168|0.014255|
|Catmull–Rom 双三次|0.017820|0.033844|23.184|0.018235|
|官方 NIS|0.023321|0.030012|24.301|0.014895|

这三列质量指标没有给出同一个排序：NIS 的显示域误差较小，而本次 HDR MSE 比双线性更大；不同亮度区间经过 tone mapping 后权重发生变化，锐化、振铃和局部对比也影响误差。双三次的显示域误差较低，同时参考误差的帧间变化较大，所以“更锐”不能直接等价为“更稳定”。本表只描述这组输入和固定实现。时域 SDK 比较还必须按实际尺寸分组：例如本次 FSR Quality 为 426×240，XeSS Quality 为 377×212，名称相同不代表渲染预算相同。原始 [最终质量表](../../sandbox/d3d12/aa-reconstruction/results/f10/quality/metrics.csv) 与 [summary 中的尺寸分组](../../sandbox/d3d12/aa-reconstruction/results/f10/quality/summary.json) 保留这一差异。

**问：50% 内部尺寸为何不保证帧时间减少 75%？** 因为许多工作不与内部像素数同比缩放，输出重建、UI、固定提交以及可能受其他瓶颈限制的工作仍在。

**问：bicubic 看起来更锐，是否恢复了新细节？** 没有。它采用不同的重建核；可以更好保持已有信号，也可以产生振铃，不会凭空证明缺失几何。

**问：NIS 与 TAA/FSR/DLSS/XeSS 的共同点和差异？** 都可能输出相同显示尺寸；NIS 在本课只用当前帧空间信息，时域方案另外利用 motion、jitter、深度与历史。名称中的“超分”并不意味着输入合同或恢复能力相同。

商业引擎动态分辨率常有 GPU 预算控制器、滞回与质量档管理；本课按确定性比例序列切换以便复现实验，没有把这个序列说成完整自适应控制器。


最终F.10的相同320×180输入、640×360输出120帧对照：双线性 / 双三次 / 官方NIS显示MAE为 **0.038943 / 0.033844 / 0.030012**；场景加重建GPU均值为0.01609 / 0.02339 / 0.02710 ms（独立关闭调试运行，前8帧排除）。这说明本压力场景中更复杂的滤波用更多工作换取较低平均误差，不代表所有内容上都优胜；各区域、时间变化与完整边界见[F10](F.10-固定序列质量与性能评测.md)。
