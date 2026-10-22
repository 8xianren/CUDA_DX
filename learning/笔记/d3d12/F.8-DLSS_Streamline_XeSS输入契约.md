# F.8：XeSS 实际执行，以及 DLSS / Streamline 的契约对照

目标：把 F.7 的“输入来自自己的渲染器，SDK 只消费明确契约”推广到另一家官方 SDK，并分清算法、运行时与集成层。实际实现是 [sdk_upscalers.cpp](../../sandbox/d3d12/aa-reconstruction/src/sdk_upscalers.cpp) 的 XeSS 分支。DLSS 与 Streamline 在本节完成真实接口和数据映射，没有伪装成已经运行的后端。

## 1. 先拆开三个名字

DLSS Super Resolution 是 NVIDIA 的时域重建功能；NGX 是直接接入它时使用的一组 SDK 接口；Streamline 是可承载 DLSS、Reflex 等插件的集成框架，本身不是另一种超分算法。Intel XeSS-SR 是另一套官方重建实现。XeSS SDK 包还包含低延迟与帧生成组件，但本节加载的只有 `libxess.dll`，并不因此启用帧生成。

把它们类比成渲染器中的“渲染算法”和“插件调度层”：我们可以直接调用一个后处理模块，也可以经插件系统给它标记资源、传相机常量并调度。两条路径最后都需要正确的颜色、运动、深度与历史生命周期；换一层包装不会自动填好这些信息。

2026-10-22 核对的版本是 [XeSS SDK 3.0.2](https://github.com/intel/xess/releases/tag/v3.0.2)、[DLSS 310.9.16](https://github.com/NVIDIA/DLSS/releases/tag/v310.9.16)、[Streamline 2.14.16](https://github.com/NVIDIA-RTX/Streamline/releases/tag/v2.14.16)。本机 XeSS 的 `xessGetVersion` 返回 **2.0.2.0**：这是包内 SR runtime 的版本，不是下载错包。包版本、单个运行时版本、模型版本不能混写。

## 2. 同一画面为什么不能原封不动换 SDK

F.4 定义了原始数据，adapter 的职责是把含义映射到 SDK 的单位。对于本课 pixel motion：

```text
m_render = (uv_previous - uv_current) × (Wr,Hr)
uv_previous = uv_current + m_render / (Wr,Hr)
```

低分辨率 XeSS motion 与 FSR 一样，纹理尺寸和位移单位都采用内部网格；我们传 `xessSetVelocityScale(context,1,1)`。如果使用 XeSS high-res motion，纹理改成输出尺寸，且运动需膨胀，数值也应对应输出网格。所谓 dilation 是将小邻域中较靠前表面的运动扩展给边缘像素，以减少重投影采错背景；它不是“把向量值乘大”。本课采用 low-res 模式，SDK 根据深度自行处理相关工作。

Jitter 仍按 F.7 的推导：投影增加 `(+2jx/Wr,-2jy/Hr)` 后屏幕几何位移为 `(jx,jy)`，直接传同一数值。相机 motion 从无 jitter 的前后矩阵计算，避免把采样位置变化误当真实几何运动。SDK flags 保持 `JITTERED_MV` 关闭。

曝光差异尤其容易出错。设真实线性颜色 C，应用为 FP16 数值范围先乘预曝光 P，输入纹理为 `C_in=C×P`。SDK 内部希望按显示曝光 E 处理，应乘：

```text
scale = E/P
C_in × scale = C×P×E/P = C×E
```

FSR 有专门的 `preExposure=P` 字段；XeSS 的 `exposureScale` 是要乘到输入上的比例，因此本课固定 E=1 时传 **1/P**，不能照抄 P。这不是命名差异，而是数学含义相反。当前基线 P=E=1，数值恰好相同，容易把错误藏起来；CPU 契约测试额外用 P=0.25 和 4 验证换算。

上述等式描述 XeSS **内部处理时**的尺度。官方说明还要求把内部所乘 scale 的倒数应用回输出，因此输出保持输入颜色的空间与标度；它不会替宿主显示管线永久消除预曝光。未来 P 不为 1 时，后续 tone mapping / 曝光和历史管理仍必须理解预曝光，本课并没有实现完整自动曝光系统。

## 3. XeSS 创建、查询与执行的真实函数

```cpp
xess_result_t xessD3D12CreateContext(ID3D12Device* device,
    xess_context_handle_t* outContext);
xess_result_t xessD3D12Init(xess_context_handle_t context,
    const xess_d3d12_init_params_t* params);
xess_result_t xessGetOptimalInputResolution(xess_context_handle_t context,
    const xess_2d_t* output, xess_quality_settings_t quality,
    xess_2d_t* optimal, xess_2d_t* minimum, xess_2d_t* maximum);
xess_result_t xessD3D12Execute(xess_context_handle_t context,
    ID3D12GraphicsCommandList* commands,
    const xess_d3d12_execute_params_t* params);
xess_result_t xessDestroyContext(xess_context_handle_t context);
```

`device` 是宿主设备；`outContext` 由 runtime 写回，初始化前不能 execute。`Init` 是阻塞的初始化，可能分配资源、建立内部管线；不要把它放进每帧热路径。重新初始化前必须等待先前 GPU 命令完成。`Execute` 仅向传入列表记录命令，不替宿主提交或等 Fence。`DestroyContext` 回收内部 history 和临时资源，不回收我们传进去的颜色纹理。

XeSS 返回码与 FSR 不能用同一“非 0 即失败”判断：**负值是错误，0 是成功，正值是警告**。adapter 对负值返回 false 并留下具体函数名和错误码；不能把“不支持设备”误当“黑屏但继续显示”。当前 RTX 5070 的官方跨厂商 D3D12 runtime 实际初始化成功；不声称 NVIDIA GPU 使用 Intel XMX 单元。

`xess_d3d12_init_params_t` 中所有字段的责任如下：

|字段|本课值 / 含义|
|---|---|
|`outputResolution`|输出宽高，不是内部 renderSize|
|`qualitySetting`|Native 对应 `AA`，其余用 SDK 的 QUALITY/BALANCED/PERFORMANCE|
|`initFlags`|0：low-res MV、普通深度、线性 HDR；无外部 descriptor heap、无曝光纹理、无 autoexposure|
|`creationNodeMask / visibleNodeMask`|0，采用本课单适配器默认节点配置|
|`pTempBufferHeap / pTempTextureHeap`|nullptr，内部资源由 SDK 分配和拥有|
|`bufferHeapOffset / textureHeapOffset`|0；若由引擎提供外部 heap，必须满足各自对齐和大小，不能用相同 offset 盲覆盖|
|`pPipelineLibrary`|nullptr；生产可用管线缓存缩短初始化，必须按官方生命周期使用|

可以先调用 `xessD3D12BuildPipelines` 做准备，但它必须在 CreateContext 与 Init 之间，且 flags 与后续 Init 一致；本教学基线使用阻塞 Init，便于错误定位。

## 4. Execute 的资源、数值与所有权

|执行字段|本课输入|
|---|---|
|`pColorTexture`|内部 RGBA16F、线性 HDR、无 UI、`NON_PIXEL_SHADER_RESOURCE`|
|`pVelocityTexture`|内部 RG16F，current→previous 内部像素位移，无 jitter，读取态|
|`pDepthTexture`|low-res MV 模式必需，D32/普通设备深度，读取态|
|`pExposureScaleTexture`|空，改用 `exposureScale=1/preExposure`|
|`pResponsivePixelMaskTexture`|本基线为空，未启用 RPM 标志|
|`pOutputTexture`|输出 RGBA16F、UAV，宿主拥有|
|`jitterOffsetX/Y`|内部像素位移，范围 [-0.5,0.5]|
|`resetHistory`|Camera cut、重建 context 后的首帧为 1|
|`inputWidth / inputHeight`|本帧有效输入尺寸|
|所有 input/output Base 坐标|0；未来打包进大纹理时才改成对应子区域原点|
|`reserved0`|0，不能借给私有参数|
|`pDescriptorHeap / descriptorHeapOffset`|空 / 0；由 SDK 管理内部 descriptor heap|

Reactive mask 和 XeSS responsive pixel mask 不能仅因“都减少拖影”就当完全相同的东西。XeSS RPM 需要初始化对应 flag、满足未 jitter 的 mask 约定和推荐 clamp；本基线明确不启用。透明粒子压力场景仍会展示未提供专门 mask 时的失效范围，不用“SDK 已接上”掩盖透明材质管线尚不完整。

SDK 可能重新绑定 heaps、PSO 和 root signature。宿主调用完必须恢复后续 pass 的绑定；资源包装没有复制资源，GPU 未完成时不可复用或释放。adapter 输出仍处于 UAV，随后显示 pass 显式转换到 SRV，读回则转换到 COPY_SOURCE，再等覆盖复制的 Fence。

## 5. 查询分辨率，不能照搬品牌档位名称

本机以 640×360 输出查询：

|档位|FSR 3.1.5 建议输入|XeSS-SR 2.0.2.0 建议输入|
|---|---|---|
|Native / AA|640×360|640×360|
|Quality|426×240|377×212|
|Balanced|376×211|320×180|
|Performance|320×180|279×157|

因此“同为 Quality”并不是相同内部像素数量；品牌默认档位比较与固定输入分辨率比较应分别标明。不能把 FSR 的 1.5 倍硬编码到 XeSS。对动态分辨率，还应使用：

```cpp
xess_result_t xessGetOptimalInputResolution(
    xess_context_handle_t context, const xess_2d_t* output,
    xess_quality_settings_t quality, xess_2d_t* optimal,
    xess_2d_t* minimum, xess_2d_t* maximum);
```

三个输出分别是建议值、允许最小与最大输入；本课 adapter 实际使用此函数，符合 XeSS 1.3+ 的官方接入要求。一个质量上下文未必允许 50%–100% 全区间。本课 F.6 的全范围 DRS 由自编空间/TAA 路径验证，FSR 使用明确 maxRender 配置；不会擅自把 XeSS Quality 的输入压到 50% 再把拒绝执行称作 SDK 错误。

同一版指南要求 Halton 等重复序列的相位数至少达到 `8×(TargetWidth/InputWidth)²`。我们用实际尺寸计算并 `ceil`，确保整数相位数不小于下界，不根据品牌档位硬编码。Native 为 8；640 输出下 Quality 377 输入取 24、Balanced 320 输入取 32、Performance 279 输入取 43。主循环和摘要记录真实采用的长度；仅 jitter 取值范围合法、GPU 没报错，不能代替这项输入质量要求。

## 6. DLSS 直接 NGX 集成映射

下面来自固定版本官方头，属于已核实的接口学习，**本课未执行 NGX/DLSS**。

```cpp
NVSDK_NGX_Result NVSDK_NGX_D3D12_Init_with_ProjectID(
    const char* projectId, NVSDK_NGX_EngineType engineType,
    const char* engineVersion, const wchar_t* applicationDataPath,
    ID3D12Device* device, const NVSDK_NGX_FeatureCommonInfo* featureInfo,
    NVSDK_NGX_Version sdkVersion);
NVSDK_NGX_Result NVSDK_NGX_D3D12_GetCapabilityParameters(
    NVSDK_NGX_Parameter** outParameters);
```

`projectId` 是项目标识，不能伪造 NVIDIA 分配的 AppID；官方提供 ProjectID 路径。`engineType/engineVersion` 描述宿主引擎；`applicationDataPath` 是 SDK 数据与日志位置；`device` 是实际 D3D12 device；`featureInfo` 可配置搜索路径等公共信息；`sdkVersion` 与编译头匹配。初始化成功后查询功能支持、驱动需求和最佳输入范围，再创建 feature，不能仅凭显卡品牌跳过 capability query。

`NVSDK_NGX_D3D12_CreateFeature(commandList, featureID, parameters, outHandle)` 创建特定功能句柄；`EvaluateFeature(commandList, handle, parameters, callback)` 消费每帧参数并录制 GPU 工作；`ReleaseFeature(handle)` 在最后一次使用的 Fence 完成后释放。参数映射应包含 color/depth/motion/output、render subrect、jitter、motion scale、reset、曝光及创建时 HDR/low-res MV/depth flags。字段的单位必须按该版本 DLSS 指南，而不是复用 Streamline 的 normalized scale 数值。

一个容易被旧文章误导的所有权细节：当前 `GetCapabilityParameters` 返回的参数表需要 `NVSDK_NGX_D3D12_DestroyParameters`；已弃用的 `GetParameters` 返回表则由 NGX 管理。两者不能都用 `delete`，也不能混淆成“不管哪种 Get 都不用释放”。这一结论直接核对当前头函数附近的说明。

## 7. Streamline 集成映射与资源标签

```cpp
sl::Result slInit(const sl::Preferences& pref, uint64_t sdkVersion);
sl::Result slIsFeatureSupported(sl::Feature feature,
    const sl::AdapterInfo& adapterInfo);
sl::Result slSetD3DDevice(void* device);
sl::Result slSetTagForFrame(const sl::FrameToken& frame,
    const sl::ViewportHandle& viewport, const sl::ResourceTag* resources,
    uint32_t resourceCount, sl::CommandBuffer* commands);
sl::Result slSetConstants(const sl::Constants& values,
    const sl::FrameToken& frame, const sl::ViewportHandle& viewport);
sl::Result slEvaluateFeature(sl::Feature feature, const sl::FrameToken& frame,
    const sl::BaseStructure** inputs, uint32_t inputCount,
    sl::CommandBuffer* commands);
```

`Preferences` 显式列出需要的 features、插件搜索目录、日志和 frame-based resource tagging；按官方流程尽早初始化，adapter 枚举时查询支持，设备创建后调用 `slSetD3DDevice`。`frame` 把资源与常量归到同一个真实帧；`viewport` 区分视口/history。三次调用传不同 frame token，就相当于把上一帧的身份证贴到当前图像上，即使资源格式正确也不成立。

输入资源标签分别是 `kBufferTypeScalingInputColor`、`kBufferTypeScalingOutputColor`、`kBufferTypeDepth`、`kBufferTypeMvec`，有曝光则加 `kBufferTypeExposure`。`Resource` 内提供原生对象和真实当前状态；`ResourceTag` 提供用途、有效期与 extent。`eValidUntilPresent` 意味着相关帧 Present 前不得复用其内容；`eOnlyValidNow` 可让需要晚使用的功能复制，不能当作无成本的万能安全选项。

Streamline common constants 要求无 jitter 的矩阵与明确相机信息。本课内部像素 motion 映射到其归一化要求时，`mvecScale=(1/Wr,1/Hr)`，这与 FSR/XeSS adapter 的 `(1,1)` 不同。深度反转、motion 是否带 jitter、reset、投影矩阵/逆矩阵、相机近平面和远平面要保持一致。DLSS options 用 `slDLSSGetOptimalSettings(options,settings)` 查询，再 `slDLSSSetOptions(viewport,options)` 配置。

当前官方流程使用 `slSetTagForFrame`；旧 `slSetTag` 已弃用，不能照抄旧教程混合两套 frame tagging。SL 可以基于标签状态管理转换，但宿主必须报告真实状态；evaluate 后仍需恢复命令列表绑定。Streamline 的 DLL/插件和 DLSS 模型并非“下载开源框架头文件就全都有”，需要核对 release 包、签名与各组件许可。我们的 interface-only 状态不会显示成可选的假 DLSS 模式。

## 8. 失败回退、实际证据与自测

失败路径必须可见：DLL 不存在→`Initialize=false`；缺少函数导出→清楚错误；设备不支持或 init 失败→保留错误码。主程序对初始化不可用显式走空间缩放，并标记 `fallback`。若已初始化之后 `Dispatch` 返回失败，当前验收程序会抛错并停止该次运行，避免继续提交可能已被部分录制的列表；它没有实现任意执行错误后的当帧自动恢复。生产引擎若要在这种情况下回退，必须先处理命令列表与资源状态的完整性，不能只在错误后再调一次缩放。更严重的 device removed 必须进入宿主设备恢复/退出路径。

[sdk-probe.json](../../sandbox/d3d12/aa-reconstruction/results/f7/sdk-probe.json) 已记录 XeSS 4 个模式真实初始化、推荐尺寸；同一探针完成 FSR resize 生命周期、缺 DLL 回退与 Debug 0。真实图像 dispatch、时间序列与质量比较统一放在 `results/f10/sequences/xess-*` 和 F.10 报告，不将初始化数值冒充图像验收。执行命令见 [工程 README](../../sandbox/d3d12/aa-reconstruction/README.md)。

2026-10-22 的最终序列已实际完成 XeSS Native / Quality / Balanced / Performance **各 120 帧**，输出均为 640×360。四组摘要分别记录输入 640×360、377×212、320×180、279×157，以及实际 jitter 相位 **8 / 24 / 32 / 43**；运行时均为官方 XeSS-SR 2.0.2.0、`fallback=false`，启用 D3D Debug / GPU Validation，各日志报告 `debug_warning_error=0`。输出经过有限值检查，首帧与第 60 帧 Camera Cut 重置历史。该轮已采用真正逐级 box 生成的棋盘 mip 链与按实际输入尺寸计算的推荐相位，质量与性能引用最终 F.10 报告，不沿用之前调试阶段的数据。

可直接查看 [Native 摘要](../../sandbox/d3d12/aa-reconstruction/results/f10/sequences/xess-native/summary.json)、[Quality 摘要](../../sandbox/d3d12/aa-reconstruction/results/f10/sequences/xess-quality/summary.json)、[Balanced 摘要](../../sandbox/d3d12/aa-reconstruction/results/f10/sequences/xess-balanced/summary.json)、[Performance 摘要](../../sandbox/d3d12/aa-reconstruction/results/f10/sequences/xess-performance/summary.json) 和 [F.10 讲义](F.10-固定序列质量与性能评测.md)。这些证据证明本课程输入确实驱动了官方 GPU 实现并完成连续帧验收；它们不意味着已经验证所有分辨率、预曝光变化或生产引擎材质组合。

商业引擎通常把每家 SDK 藏在统一重建接口后，但不会把各家的参数强行定义成同一个含义；正确抽象是先保留规范化的宿主数据，再让 adapter 做精确换算。我们已用同一个 `SdkFrame` 暴露所有权、数值与状态，并为曝光写了不同映射。

自测及答案：Streamline 与 DLSS 是两种重建算法吗？不是，前者是集成框架，后者是功能。为什么 P=1 的测试不能证明曝光映射正确？因为 P 与 1/P 恰好一样，需要非 1 样本。为什么 same Quality 不能直接归因谁更快？内部像素数量可能不同，必须同时报告输入与输出尺寸、同样的场景和测量范围。下一节才讨论额外显示帧、Present 节奏和真实输入采样频率。

参考：[XeSS-SR 官方指南](https://github.com/intel/xess/blob/v3.0.2/doc/xess_sr_developer_guide_english.md)、[XeSS D3D12 接口](https://github.com/intel/xess/blob/v3.0.2/inc/xess/xess_d3d12.h)、[NGX 官方头](https://github.com/NVIDIA/DLSS/blob/v310.9.16/include/nvsdk_ngx.h)、[Streamline 核心接口](https://github.com/NVIDIA-RTX/Streamline/blob/v2.14.16/include/sl_core_api.h)、[SL/DLSS 官方指南](https://github.com/NVIDIA-RTX/Streamline/blob/v2.14.16/docs/ProgrammingGuideDLSS.md)、[SL 生命周期与资源标记](https://github.com/NVIDIA-RTX/Streamline/blob/v2.14.16/docs/ProgrammingGuide.md)。
