# F.7：让官方 FSR 消费我们真正渲染的帧

本节目标：在同一 D3D12 工程中调用官方时域超分，而不是把双线性缩放改名为 FSR。代码入口是 [共享工程](../../sandbox/d3d12/aa-reconstruction/README.md)、[SDK adapter](../../sandbox/d3d12/aa-reconstruction/src/sdk_upscalers.cpp)、[每帧输入契约](../../sandbox/d3d12/aa-reconstruction/src/sdk_upscalers.h)。F.9 的帧生成属于另一条独立输出链，本节只有每个真实帧的一次重建。

## 1. 先定义我们要解决的问题

内部渲染宽高是 `Wr × Hr`，显示宽高是 `Wo × Ho`。我们只有前者数量的当前帧样本，却要估计后者数量的像素滤波结果。单帧空间缩放只能利用当前帧；时域方案还利用上一帧提供的信息，但先要知道“当前看到的表面，上帧在哪里”。这就是 F.4 的运动矢量、F.5 的重投影为什么必须先做正确。

可以类比拍摄静止布景的多张照片：每张略微移动采样位置，合在一起能补充信息。但人物会移动、前景会挡住背景、透明火花可能没有唯一表面运动。官方算法能做更复杂的拒绝、锁定和重建，不能补救我们把方向、曝光或资源状态传错。

我们采用清楚的一套约定：D3D 常规深度近处 0、远处 1；像素坐标 x 向右、y 向下；运动矢量 current→previous；纹理在内部渲染分辨率；矢量数值单位也属于内部像素；运动值不包含投影 jitter。资源布局和数值单位是两个独立问题：一张低分辨率纹理仍然可以存输出像素单位的值，只是那时必须额外换算。本课选择两者都属于内部网格，避免隐含比例。

## 2. 从约束推导运动与 jitter

设同一表面的无 jitter 屏幕位置为 `uv_current`、`uv_previous`。重投影希望满足：

```text
uv_previous = uv_current + motion_uv
motion_uv = uv_previous - uv_current
motion_pixel = motion_uv × (Wr, Hr)
```

所以一个物体从屏幕 x=0.30 移动到 0.35，运动矢量 x 应为 `-0.05 Wr`。它描述“回到过去应向哪里找”，不是物体向前的速度。我们给 FSR 的 `motionVectorScale=(1,1)`，因为 shader 已经存像素单位；若存 UV，scale 才是 `(Wr,Hr)`。如果存的是真正 NDC 差值，先依据 viewport 的 x/2、-y/2 换成 UV，不能把 NDC 和 UV 都叫“归一化坐标”而漏掉 2 与 y 符号。

投影对几何坐标注入 `Δndc=(2jx/Wr,-2jy/Hr)`。再经过 D3D viewport：

```text
Δscreen_x = Δndc_x × Wr/2 = jx
Δscreen_y = -Δndc_y × Hr/2 = jy
```

这说明本课传入的 `(jx,jy)` 是几何在屏幕上的偏移；有效采样位置相对于场景会反向偏移。不要因为“相机抖动”四个字又随手取负。FSR sample 自己的中间变量与投影约定不同，我们核对的是最终投影位移与 dispatch 值的关系。

[独立 CPU 契约验证](../../sandbox/d3d12/aa-reconstruction/verify_sdk_contracts.py) 从上述约束计算期望值，检查多种分辨率、jitter 符号和曝光还原，共 15 项通过。它只能证明我们的约定换算，不能证明官方 GPU 算法图像正确。

## 3. 版本、许可和实际运行的算法

2026-10-22 接入固定 [FidelityFX/FSR SDK v2.3.0](https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK/releases/tag/v2.3.0)。包内存在多个算法 provider，不能把 SDK 大版本当作本机算法版本。本机 RTX 5070 实际 `ffxQueryGetProviderVersion` 返回 **3.1.5**；本节运行跨厂商 FSR 3.1.5，不声称运行 AMD ML FSR 4。

SDK 2.x 把 loader、upscaler、framegeneration 分成不同 DLL。本节需要 `amd_fidelityfx_loader_dx12.dll` 与 `amd_fidelityfx_upscaler_dx12.dll`；F.9 才加载帧生成 effect。官方包和源码 tag ZIP 的 SHA256、大小、URL、许可入口记录在 [sdk_manifest.json](../../sandbox/d3d12/aa-reconstruction/sdk_manifest.json)。两个 release 二进制包同时比对 GitHub asset digest 与本地 SHA256；源码 ZIP 的固定 hash 是我们对官方 tag 下载的内容锁定，不能冒称厂商数字签名。

[runtime-identities.json](../../sandbox/d3d12/aa-reconstruction/results/f7/runtime-identities.json) 另记录实际 DLL 的 SHA256、文件版本和 Windows Authenticode 检查：AMD loader/upscaler 与 Intel XeSS 的签名均为 Valid，主体分别是 AMD / Intel。upscaler DLL 文件版本 4.1.1.2740 仍不改变本机 provider 实际为 3.1.5 的结论。

API 头具有 MIT 许可；SDK 总体许可有逐文件例外以及二进制条款，详见 [官方许可](https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK/blob/v2.3.0/docs/license.md)。本仓库只提交自编 adapter、脚本与清单，第三方包下载到忽略的 `build/deps`。不会把“网上可下载”误写成“所有组件都 MIT”。

## 4. Context 生命周期与真实 API

官方入口的核心原型为：

```cpp
ffxReturnCode_t ffxCreateContext(ffxContext* context,
    ffxCreateContextDescHeader* desc, const ffxAllocationCallbacks* memCb);
ffxReturnCode_t ffxQuery(ffxContext* context, ffxQueryDescHeader* desc);
ffxReturnCode_t ffxDispatch(ffxContext* context,
    const ffxDispatchDescHeader* desc);
ffxReturnCode_t ffxDestroyContext(ffxContext* context,
    const ffxAllocationCallbacks* memCb);
```

`context` 是 SDK 的不透明句柄，不是我们的 D3D12 device；创建传其地址是为了让 SDK 写回句柄。`desc` 指向带 `type` 和 `pNext` 的描述符链；`type` 决定 SDK 怎样解释后面的字节，不能只填字段而忘填类型。`memCb=nullptr` 使用 SDK 默认 CPU 分配方式，与 D3D12 GPU 资源分配回调不是一回事。成功值是 `FFX_API_RETURN_OK=0`，其他值必须处理。

本课创建链依次是：

|结构|关键参数|本课取值与原因|
|---|---|---|
|`ffxCreateContextDescUpscale`|`flags`|HDR 与动态分辨率；不打开倒深度、无限远和 jitter cancellation，因为输入并非这些约定|
|同上|`maxRenderSize`|允许的内部最大尺寸，本课等于输出尺寸，覆盖 50%–100%|
|同上|`maxUpscaleSize`|输出宽高|
|`ffxCreateBackendDX12Desc`|`device`|宿主创建的真实 `ID3D12Device*`|
|`ffxCreateContextDescUpscaleVersion`|`version`|官方头的 `FFX_UPSCALER_VERSION`，表达 ABI/API 版本|

这些描述符保存在 adapter 成员里；device、context 与 DLL 都活到最后一次使用它们的 GPU Fence 完成。宿主 `Shutdown` 前先 `SubmitWait`，adapter 不私自拿一个新队列替宿主“等一下”，因为那个新队列的 Fence 根本不覆盖原队列。

初始化发现的一个真实集成错误很有教学意义：仅用绝对路径加载 loader，并 `AddDllDirectory`，本机 `ffxCreateContext` 返回 2。原因是 effect 在另一个目录，loader 的延迟查找没有自动采用我们期望的路径。修正是先以绝对路径 `LoadLibraryExW` 加载官方 upscaler effect，保留其 `HMODULE`，然后加载 loader。关闭顺序是 context → loader → effect → DLL 目录 cookie。没有复制或改写官方二进制，也没有把错误码吞掉。

## 5. 每帧输入的布局、含义和状态

|输入|格式 / 尺寸|语义与状态|
|---|---|---|
|color|RGBA16_FLOAT / 内部尺寸|线性 HDR，尚未 tone mapping / UI；`NON_PIXEL_SHADER_RESOURCE`|
|depth|R32_TYPELESS 资源、D32 DSV / R32_FLOAT SRV|jitter 后几何的设备深度；SDK 描述显式写 R32_FLOAT；`NON_PIXEL_SHADER_RESOURCE`|
|motionVectors|RG16_FLOAT / 内部尺寸|无 jitter 的 current→previous 内部像素位移；`NON_PIXEL_SHADER_RESOURCE`|
|reactive|可选 R8_UNORM / 内部尺寸|透明等应减少历史依赖的区域，0 稳定、较高值提高响应；输入必须已生成并转成读取态|
|transparencyAndComposition|本基线未提供|不是 reactive 的别名；用于特殊透明/合成策略，缺省边界明确保留|
|exposure|本基线未提供|固定曝光 1；若接自动曝光，要传正确 1×1 数据或开启相应功能|
|output|RGBA16_FLOAT / 输出尺寸|宿主拥有的 UAV，调用前 `UNORDERED_ACCESS`，返回仍是该状态|

`ffxApiGetResourceDX12` 只是把真实 D3D12 resource 包成 SDK 描述，不会复制纹理，也不等于状态转换。所有权仍属于宿主。输入纹理不能在 GPU 尚未读完时销毁；输出不能因为 CPU 上 `ffxDispatch` 返回了就立即 Map。

其余 dispatch 字段逐一填写：`commandList` 是正在录制的 DIRECT list；`renderSize` 是本帧有效内部范围；`upscaleSize` 是输出范围；`jitterOffset`、`motionVectorScale` 采用前面的约定；`frameTimeDelta` 单位毫秒，不能传秒；`cameraNear/Far` 与实际投影一致；`cameraFovAngleVertical` 是垂直弧度；`viewSpaceToMetersFactor=1` 表示一世界单位一米；`preExposure=P>0` 描述输入颜色事先乘过 P。当前固定 P=1。

我们关闭额外 RCAS 锐化，避免把锐化强度差异当成重建质量差异。SDK 会修改 command list 的 root signature、PSO 和 descriptor heaps；宿主之后显示 UI 或执行别的 compute，必须重绑自己的状态。adapter 在输出上补 UAV barrier，只建立访问排序；GPU 是否执行完仍依赖宿主 Fence。

本课材质统一采用 `log2(renderWidth/outputWidth)` 的额外 mip LOD bias，让较低内部尺寸仍按同一输出尺寸目标获取纹理细节。FSR 官方进一步推荐 `log2(render/display)-1`，比本实验再细一级，但也建议对易闪烁高频内容调整。这里有意保留统一材质采样基线，不采用 FSR 专用的额外 `-1`；因此对照结果不代表对 FSR 做尽所有推荐锐度调参后的画质上限。

## 6. Native、Quality、Balanced、Performance 和重置

模式的语义先问 SDK。本机 640×360 输出的 `ffxQueryDescUpscaleGetRenderResolutionFromQualityMode` 结果是：

|模式|内部尺寸|每维目标倍率|
|---|---|---|
|Native AA|640×360|1.0|
|Quality|426×240|1.5|
|Balanced|376×211|1.7|
|Performance|320×180|2.0|

整数尺寸会舍入；必须把真实尺寸用于 viewport、SRV 范围、motion 单位和 jitter，而非继续用理想浮点倍率。Native AA 仍是时域抗锯齿，不能理解为“关闭算法”。

本课 SDK 使用按倍率确定长度的 Halton 序列，不能把 Native 的 8 相硬编码到超分模式。`SdkUpscaler::JitterPhaseCount(renderWidth,outputWidth)` 对 FSR 调用官方 `ffxQueryDescUpscaleGetJitterPhaseCount`，输入是**本帧实际整数尺寸**；内部 DRS 改变后会重新查询。XeSS 则按官方“至少 `8×(输出宽/输入宽)²`”的要求取上整，满足其下界。自编 Native TAA 保留 8 相。即使采用官方建议，也不代表已经对各家 SDK 的所有画质参数做完生产调优。

这里的“相位数”是重复采样序列包含多少个不同 jitter 位置，不是 CPU/GPU 同时在途的帧数。宽高各放大 r 倍时，一个内部像素的足迹覆盖约 r² 个输出像素；若仍只使用原来的 8 个位置，每单位输出面积得到的采样位置就稀疏了。让序列长度随 r² 增长能保持类似的采样密度，但这不是“经过这些帧必定完全收敛”的定理：遮挡、运动和历史拒绝都会使有效样本减少。

FSR 查询只在 CPU 上读取推荐值，不提交 GPU 工作：将 `header.type` 设为 `FFX_API_QUERY_DESC_TYPE_UPSCALE_GETJITTERPHASECOUNT`，`renderWidth` 填本帧输入宽、`displayWidth` 填输出宽，`pOutPhaseCount` 指向一个有效的 `int32_t`，再调用 `ffxQuery(&context,&query.header)`。返回码成功且相位数大于 0 才能用于 `% phaseCount` 的周期索引；本课查询失败就中止验收，不偷偷退回固定 8 相。

640 输出下，以实际整数尺寸计算，FSR 3.1.5 官方查询实际得到 Native / Quality / Balanced / Performance 的 **8 / 18 / 23 / 32 相**，已写入四组 120 帧运行摘要的 `jitter_phase_count`。XeSS 公式取上整得到 **8 / 24 / 32 / 43 相**。最终采用值以各运行摘要为准，不能仅靠名义 1.5×、1.7× 等字符串回填。

Camera cut 改变了对应关系，第一帧 `reset=true`；输出 resize 超过/改变 context 输出配置，需要先等待 GPU，销毁 context，按新输出创建，再将首帧 reset。内部 DRS 在预留 maxRender 内变化，则逐帧更新 `renderSize`，不需要每帧重新申请整套 history。输入 UV、运动尺度与新的内部网格必须一起更新。本课质量档切换采用重建 context 加首帧 reset，优先可验证性。

## 7. 动手、证据与边界

从仓库根目录：

```powershell
& learning/sandbox/d3d12/aa-reconstruction/fetch_sdks.ps1
& learning/sandbox/d3d12/aa-reconstruction/build.ps1
python learning/sandbox/d3d12/aa-reconstruction/verify_sdk_contracts.py
```

初始化/销毁/resize/缺 DLL 注入结果在 [sdk-probe.json](../../sandbox/d3d12/aa-reconstruction/results/f7/sdk-probe.json)，CPU 数学约定在 [sdk-contracts.json](../../sandbox/d3d12/aa-reconstruction/results/f7/sdk-contracts.json)。探针实际建立 FSR 4 个模式及 XeSS 4 个模式，测试 FSR 640→800 输出重建、缺 DLL 返回 fallback，Debug/GPU Validation 告警错误为 0、Fence 10/10。探针没有渲染图像；FSR / XeSS 图像统一进入 `results/f10/sequences`，按同一分析流程评测。

2026-10-22 的主程序实际 GPU 验收随后完成：Native / Quality / Balanced / Performance **各 120 帧**，输出 640×360，全部报告真实 provider 3.1.5、`fallback=false`、浮点输出有限值、启用 Debug/GPU Validation，首帧和第 60 帧 Camera Cut 触发 reset。四组分别保存在 `results/f10/sequences/fsr-*`；它们不是单帧 smoke test。

另外，`fsr-dynamic` 16 帧覆盖内部 426×240 → 320×180 → 480×270 → 640×360；每次尺寸改变的历史失效显式进入日志。CSV 的 `reset` 列记录原因枚举：0 无重置，1 首帧，2 Camera Cut，5 内部动态尺寸；不是只取 0/1 的布尔值。新输出 800×450 的 `sdk-resize` 实际重建 8 帧成功，见 [resize-dispatch/summary.json](../../sandbox/d3d12/aa-reconstruction/results/f7/resize-dispatch/summary.json)。故意缺失 SDK 的 8 帧显示 `provider=bilinear fallback` 与 `fallback=true`，不混进 FSR 成绩。质量序列含验证与读回开销，正式性能仅使用 F.10 的独立 benchmark。

商业引擎一般把 SDK 放进 render graph，统一资源生命周期、各视图 history、曝光、透明材质输出与异步调度。本课有意采用单队列同步验收，保留清楚的模块契约；同样的底层机制是纹理输入、对应关系、history 与 GPU 依赖，不代表生产引擎也应逐帧阻塞 CPU。

自测及答案：为什么 `motionVectorScale` 不是输出宽高？因为纹理已经存内部像素位移，再乘会重复缩放。为什么切换相机不能保留全部 history？因为像素对应的表面已经不连续，重投影假设失效。为什么初始化成功还不能写“FSR 验收通过”？因为资源内容、状态、运动方向、jitter 与时序质量尚未被 GPU 输出证明。下一节用 XeSS 真正运行，并把 DLSS/Streamline 的差异具体映射出来。

参考：[官方 Upscale 接口头](https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK/blob/v2.3.0/Kits/FidelityFX/upscalers/include/ffx_upscale.h)、[FSR API 生命周期](https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK/blob/v2.3.0/Kits/FidelityFX/docs/getting-started/ffx-api.md)、[官方技术说明](https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK/blob/v2.3.0/Kits/FidelityFX/docs/techniques/super-resolution-upscaler.md)。
