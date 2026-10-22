# F.9 官方帧生成：把真实渲染、插值、UI 与显示节奏分开

本节目标：亲手接入官方帧生成交换链，看到真实渲染帧与生成帧分别走过哪些队列，并用不同的测量工具回答“渲染了多少帧、提交了多少帧、系统实际显示了多少变化”。

代码入口：[aa-reconstruction](../../sandbox/d3d12/aa-reconstruction/README.md)。独立实验：[framegen_demo.cpp](../../sandbox/d3d12/aa-reconstruction/src/framegen_demo.cpp)、[GPU 场景](../../sandbox/d3d12/aa-reconstruction/shaders/framegen_scene.hlsl)、[验收脚本](../../sandbox/d3d12/aa-reconstruction/verify_framegen.py)。本节复用 F.7/F.8 的 SDK 下载，使用单独的窗口程序隔离 Present 问题，没有再复制一套超分器。

当前代码定位：`learning/sandbox/d3d12/aa-reconstruction/src/framegen_demo.cpp:181` 创建 SDK context；`:231` 官方生成回调；`:242` 后置 UI；`:269` 真实帧循环与统计线程；`:345` 两类队列等待；`:390` 关闭顺序。行号对应本课最终源码，后续修改请按同名函数定位。场景投影深度与运动矢量在 `shaders/framegen_scene.hlsl` 的 `PSMain`。

## 1. 先提出问题：渲染 60 帧，为什么能交给显示器 120 幅图？

设游戏在时刻 $t_0$ 和 $t_1=t_0+\Delta t$ 各模拟一次世界，渲染结果为 $C_0$、$C_1$。如果每次都完整重跑几何、材质、光照，计算第二幅图仍需真正渲染一帧；单纯让交换链多执行一次 `Present` 只能重复已有图像。

帧生成解决的是另一道题：在得到两幅真实图像后，估计它们之间的画面 $\hat C(t_0+\alpha\Delta t)$。一帧插值通常取 $\alpha=1/2$。像动画师先画两个关键姿势，再补中间姿势；生成的姿势更密，原始关键姿势的时间与输入来源没有变。

先推导一个无遮挡、匀速、刚性平移的简单点。设它在两帧的屏幕位置为 $p_0,p_1$，线性运动假设给出：

$$p(\alpha)=(1-\alpha)p_0+\alpha p_1.$$

若输入运动矢量采用本课与 FSR 的“当前指向历史”约定 $v_1=p_0-p_1$，则中间位置为：

$$p(1/2)=p_1+\tfrac12v_1.$$

这只推导了位置约束，**没有**推导出可靠的图像插值器。边缘会显露原先不可见的背景；一个像素内可能混有前景和背景；粒子、反射、透明表面不一定有唯一几何运动矢量；运动还可能加速。简单地把颜色平均会出现两个半透明物体。真正的算法还要处理光流、几何运动、深度与遮挡。本课调用 AMD 官方实现，GPU 场景着色器只生成真实帧的输入，不自行伪造商业帧生成算法。

“光流”是根据两张图的图案变化估计像素运动；“几何运动矢量”由场景上一帧/当前帧的变换投影得到。它们提供的信息不同：光流可以看到着色与纹理变化，几何运动知道场景对应关系，但对反射或透明混合未必充分。不能把二者当成两个不同名字的同一张纹理。

再看因果：我们必须先拿到 $C_1$ 才能基于 $C_0,C_1$ 生成中间图，因此生成图不会预知 $t_1$ 以后才发生的按键。即使显示图像数翻倍，真实模拟与输入采样仍为 60 Hz。插值成本、显示排队和 pacing 会改变延迟，不能从“120 FPS”推出“输入响应等价于原生 120 FPS”。

## 2. 当前官方版本与本机选择

2026-10-22 核对 AMD 官方 SDK 2.3.0：本课恢复官方签名的 `amd_fidelityfx_loader_dx12.dll` 与 `amd_fidelityfx_framegeneration_dx12.dll`，把它们放到实验 exe 同目录。下载 URL、版本与压缩包 SHA256 见[SDK 清单](../../sandbox/d3d12/aa-reconstruction/sdk_manifest.json)。第三方依赖位于被忽略的 `build/deps/`，DLL 不提交到仓库。

本机 RTX 5070 实际查询返回 **Frame Generation 3.1.6、Swapchain 3.1.7**。SDK 中也有只面向相应 AMD 硬件的 ML 帧生成版本，不能因为 SDK 文档首页写着 4.0.1，就把本机运行结果称为 FSR 4 帧生成。`FFX_FRAMEGENERATION_VERSION` 是本程序编译时的接口兼容版本，实际 provider 必须用 `ffxQueryGetProviderVersion` 查询，两个概念不能混在一起。

AMD 对非 ML 的 3.1.6 路径声明支持其他厂商的等效 GPU，并建议真实输入帧率至少约 60 FPS。这个建议涉及插值质量和节奏，不是“30 FPS 以下 API 就无法创建”。本课以 1280×720、60 Hz 真实模拟、单生成帧、SDR、窗口模式、VSync 关闭为固定实验条件。[官方 SDK 与硬件说明](https://gpuopen.com/amd-fsr-sdk/)、[官方 3.1.6 算法接口说明](https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK/blob/v2.3.0/Kits/FidelityFX/docs/techniques/frame-interpolation.md)。

## 3. 先画执行关系，再看 API

```text
主线程：输入采样/模拟 -> 绘制真实 Color/Depth/MV -> Prepare -> Execute -> Proxy Present
                                                       |             |
主图形队列：场景 + Prepare -----------------------------+--> 官方光流/插值
                                                                      |
SDK 的显示线程/显示队列：                    generated 图 -> 后置 UI -> Present
                                              real 图 -> 后置 UI -> Present

独立统计线程：只读 GetFrameStatistics，记录系统已经报告显示的 present ID 变化
```

本实验 `allowAsyncWorkloads=false`，因此光流和帧生成使用主图形队列；**UI 与真正的显示提交仍由 SDK 的另一队列处理**。关闭异步计算不等于只有一个队列。代理交换链保持 `IDXGISwapChain4` 接口，应用每个真实帧只调用一次 `Present`，SDK 内部安排两幅图的提交。

`Present` 返回只说明 API 接受了相应工作，不表示 GPU 已经绘制完成，也不表示面板已经扫描出图像。本程序的 `FlushMain` 是教学中为复用 allocator 而等待主队列的简化；它不覆盖 SDK 隐藏的显示队列。关闭程序时还要调用专门的 `WaitForPresents`。

商业引擎通常保留多帧命令资源，用延迟回收避免每个真实帧阻塞 CPU，并将低延迟标记、负载限制器和输入采样时机纳入调度。本课逐帧等待主队列是为了清楚验证资源生命周期；代理交换链、资源状态、跨队列依赖和后置 UI 的底层契约相同，不能把本课同步策略当作生产最佳方案。

## 4. 创建：类型化描述结构链比函数数量更重要

SDK 的五个主要函数签名如下。这里是官方头文件中的真实 C 接口，不是自创伪 API：

```cpp
ffxReturnCode_t ffxCreateContext(ffxContext* context,
    ffxCreateContextDescHeader* desc, const ffxAllocationCallbacks* memCb);
ffxReturnCode_t ffxDestroyContext(ffxContext* context,
    const ffxAllocationCallbacks* memCb);
ffxReturnCode_t ffxConfigure(ffxContext* context,
    const ffxConfigureDescHeader* desc);
ffxReturnCode_t ffxQuery(ffxContext* context, ffxQueryDescHeader* desc);
ffxReturnCode_t ffxDispatch(ffxContext* context,
    const ffxDispatchDescHeader* desc);
```

- `context` 是不透明对象句柄的地址；创建时写回，后续配置/查询/提交/销毁继续传同一个地址。
- `desc` 指向以 `header.type`、`header.pNext` 开头的类型化结构。`type` 告诉运行时当前结构的含义；`pNext` 串联后端、版本或可选参数。传错 `type` 是接口错误，不是硬件慢。
- `memCb=nullptr` 使用 SDK 默认分配器。若定制分配器，销毁时必须提供兼容的回调；应用不能用 `delete` 直接释放 SDK context。
- 返回 `0` 为成功，非零要停止依赖该结果的流程。代码的 `Fx` 保留返回码并向上报告，不继续用空句柄。
- 描述结构引用的设备、队列、交换链/回调用户对象需保持有效。程序把创建描述保存为 `Demo` 成员，避免把生命周期不明确的临时结构地址留下。

帧生成 context 的描述链是 `FrameGeneration -> FrameGenerationVersion -> BackendDX12`。前者指定输出尺寸、最大渲染尺寸、颜色格式与深度/MV/HDR 等约定；版本结构说明接口版本；DX12 后端指向创建所有资源的 `ID3D12Device`。本课不打开 HDR、反向深度或无限远深度标志，因为输入没有采用这些约定。

交换链使用 `ffxCreateContextDescFrameGenerationSwapChainForHwndDX12`：

|成员|本课值与含义|
|---|---|
|`swapchain`|`IDXGISwapChain4**` 输出地址，由 SDK 创建代理对象|
|`hwnd`|真实 Win32 窗口；同一窗口不能同时保留另一个普通交换链|
|`desc`|1280×720、RGBA8 UNORM、1 sample、3 buffer、flip discard、frame-latency waitable flag|
|`fullscreenDesc`|空，保持窗口模式|
|`dxgiFactory`|创建时持有的 DXGI 工厂|
|`gameQueue`|主 DIRECT 队列，交给 SDK 建立执行依赖|
|`header.pNext`|SwapchainVersion 结构，明确兼容版本|

这里交换链始终单采样，MSAA 若启用应先 Resolve。UI 显示帧不应该携带多采样资源直接进入 flip-model backbuffer。

`GetFrameLatencyWaitableObject()` 返回应用需要关闭的独立 handle。只取一次并每个真实帧等待，限制 CPU 领先幅度；按照 3.1.7 的契约，先销毁交换链 context，再 `CloseHandle`。不能每帧取得一个新 handle 却从不关闭。[官方交换链文档](https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK/blob/v2.3.0/Kits/FidelityFX/docs/techniques/frame-interpolation-swap-chain.md)。

## 5. 输入不是“给一张图”那么简单

本课用一张全屏三角形同时输出三张 1280×720 纹理，shader 中的运动方块与固定细杆构成遮挡测试。

|资源|布局/格式|所有者与交接状态|
|---|---|---|
|颜色|`R8G8B8A8_UNORM`，四个 8 位通道，SDR 编码值|应用创建；RT 写完转 `COPY_SOURCE`，复制到代理 backbuffer|
|深度|`R32_FLOAT`，一分量，D3D 正向投影深度|应用创建；RT 写完转 `NON_PIXEL_SHADER_RESOURCE` 供 Prepare 读取|
|运动矢量|`R16G16_FLOAT`，XY 两个 half|应用创建；同上，数值为当前像素到历史像素的偏移|
|生成结果|官方 context/交换链内部纹理|SDK 负责寿命与排队；回调只在有效范围内访问|
|显示 backbuffer|交换链实际输出表面|SDK 交给 UI 回调；回调完成后恢复传入资源状态|

CPU 不假设纹理显存紧密排列；截图用 `GetCopyableFootprints` 得到 `RowPitch`，逐行从 readback buffer 取 RGBA 字节，再写 RGB PPM。资源格式、像素编码与显存布局是不同问题。

我们的深度来自距离 $z$，近面 $n=0.1$、远面 $f=100$。投影之后深度具有 $d(z)=A+B/z$ 的形式。施加 $d(n)=0$、$d(f)=1$：

$$A+B/n=0,\quad A+B/f=1 \Rightarrow
A=\frac f{f-n},\quad B=-\frac {fn}{f-n}.$$

于是 shader 使用 $d(z)=f/(f-n)-fn/[(f-n)z]$。背景、方块、前景杆分别取距离 20、2、1，而不是把这三个世界距离直接塞到 `[0,1]` 深度纹理。

运动方块本帧中心 `currentX`、上帧中心 `previousX`，其所有可见像素的运动为 `(previousX-currentX,0)`；固定背景和细杆为零。以方块向右为例，历史位置在当前像素左侧，所以运动的 X 分量为负。没有摄像机 jitter，`jitterOffset=(0,0)`；没有混合 jitter cancellation 标志。

`ffxDispatchDescFrameGenerationPrepareV2` 关键输入逐项对应如下：

- `commandList`：尚在录制的主图形命令列表，不是 command queue。
- `frameID`：与当帧 Configure 相同，逐次严格 `+1`；发生跳号时 SDK 会视作时序断裂。
- `renderSize`：本帧有效 Depth/MV 的尺寸；不是随意填显示器桌面分辨率。
- `depth/motionVectors`：`ffxApiGetResourceDX12` 包装的资源、描述与当前状态，不转移 COM 对象所有权。
- `motionVectorScale=(1,1)`：数值已经是像素偏移；若输入存的是 UV 偏移，应乘渲染宽高。SDK 头文件注释同时出现“to UV space”和“pixel space”的措辞，实际集成以其明确给出的尺度示例及官方示例保持一致，不凭文字猜测反向缩放。
- `frameTimeDelta`：毫秒，本固定仿真为 16.667；不是秒。
- `reset`：第一帧为真；相机切换、尺寸或时序断裂也要重置相关历史。不能只把历史数组清成黑色。
- `cameraNear/Far`：0.1/100，与上面的投影深度完全一致。
- `cameraFovAngleVertical`：垂直视场角，弧度，本课 $\pi/3$。
- `viewSpaceToMetersFactor`：视空间单位到米，本课为 1。
- `cameraPosition` 与 `cameraUp/Right/Forward`：位置与归一化基，本场景相机静止在原点，基为 +Y/+X/+Z。

Prepare 之后 SDK 可以改变命令列表绑定状态；后续若再画别的东西，要重新绑定自己的 PSO、root signature 与描述符。不要以为 SDK 内部绑定是应用可以继续依赖的状态。[官方 Prepare 与资源生命周期说明](https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK/blob/v2.3.0/Kits/FidelityFX/docs/techniques/frame-interpolation-api.md)。

## 6. 每帧 Configure、生成回调与 UI 回调

每个真实帧更新 `ffxConfigureDescFrameGeneration`：`swapChain` 指向代理交换链；`frameGenerationEnabled` 控制开关；`allowAsyncWorkloads=false` 让算法在主队列执行；`generationRect` 为完整输出区域；`frameID` 严格递增。`frameGenerationCallback` 和 `presentCallback` 是两种不同职责的回调，各有 `UserContext=this`，该 `Demo` 对象不能提前释放。

生成回调的真实签名是：

```cpp
ffxReturnCode_t callback(ffxDispatchDescFrameGeneration* params, void* user);
```

`params` 包含 SDK 准备好的命令列表、当前颜色、最多四个输出槽、实际生成数、reset、颜色传递函数、亮度范围、生成区域和 frame ID。本课只把这些参数交给 `ffxDispatch(&fgContext,&params->header)`，并在调用前后放 GPU timestamp。不把 `numGeneratedFrames` 强制修改成“想要的 4”，也不把 callback 被调用就当成计算必然成功。

UI 回调则是：

```cpp
ffxReturnCode_t callback(ffxCallbackDescFrameGenerationPresent* params, void* user);
```

它有 `currentBackBuffer`（可能是真实帧或生成帧）、`outputSwapChainBuffer`、`commandList`、`isGeneratedFrame`、`frameID`。本实验先把输入拷贝到输出，再画青色 UI 条和白色准星。顺序为 **插值结果 -> UI**，因此算法从来不插值这条 UI。

UI 回调不能使用主线程正在复用的 command allocator/list。应在 SDK 传来的列表上录制少量工作，按传入的 FFX 资源状态做临时 transition，并恢复状态后返回。FFX 状态枚举的位值与 D3D12 不相同，所以 `State()` 明确逐位映射，不能 `static_cast<D3D12_RESOURCE_STATES>(ffxState)`。

本课用 `ClearRenderTargetView` 的矩形参数画 UI；生产中可以画文字、图标、动画，但最好轻量，因为真实帧与生成帧各执行一次。UI 是否重采样鼠标、动画是否按显示时钟推进，是引擎设计选择，不代表世界模拟也变成显示频率。回调日志按 `isGeneratedFrame` 分类，避免凭“奇偶帧”猜哪张是生成帧。

## 7. 同步与失败路径：最容易漏的是 SDK 的隐藏队列

本课每帧顺序为：重置已完成的 allocator/list -> 绘制三张输入 -> transition -> 拷贝真实颜色至代理 backbuffer -> Prepare -> 执行主列表 -> Proxy Present（触发生成录制）-> 主队列 Signal/Wait。主队列等待允许下一次复用输入与 allocator，但此时 SDK UI/present 可能仍在另一队列运行。

截图记录在 UI 回调中；CPU 直到所有 SDK presents 完成后才 Map，不能在主队列 fence 一过就读回另一个队列尚未写完的数据。

销毁顺序：

1. 停止/加入 DXGI 统计线程，保证不再读取即将销毁的 swapchain。
2. 等主队列，再 `ffxDispatch` 一个 `ffxDispatchDescFrameGenerationSwapChainWaitForPresentsDX12`。
3. Configure 关闭 FG 并清空回调，确保不再生成引用应用对象的新工作。
4. 再次等待 SDK presents，销毁 FG context，再销毁 swapchain context。
5. 关闭 waitable handle、fence event 和窗口；随后应用资源自然释放。

正常与异常路径都走 `Close`；构造到一半失败也先清理已经创建的 SDK 对象。关闭失败会保留错误输出。验收在销毁 SDK 后才收集 Debug Layer 信息，因此“运行期间没错误、销毁时却提前释放在用资源”不会被漏掉。

SDK 不允许多个线程同时无保护操作同一个 FG context 的相关接口。本程序主线程调用 Configure/Prepare/Present，生成回调在该 Present 路径录制；独立 UI 线程只使用设备和自己收到的命令列表，统计线程只读 DXGI。若以后把多个窗口的 FG Prepare 放到多个线程，必须按官方线程安全要求增加全局互斥，而不是认为 `ID3D12Device` 大体线程安全就等于 FFX context 也线程安全。

## 8. 五种计时不能相互替代

|量|来源|能说明什么|不能说明什么|
|---|---|---|---|
|真实采样间隔|输入/模拟前的 CPU QPC|真实世界更新节奏|显示器是否真的刷新|
|Scene+Prepare / FG GPU 时间|同队列 timestamp + `GetTimestampFrequency`|对应 GPU 区间成本|完整游戏帧成本、总延迟|
|应用 `Present` CPU 耗时|调用前后 QPC|代理 API 在主线程阻塞多久|SDK 内部两次 Present 的时刻|
|UI composition callback|官方 `isGeneratedFrame` 与 CPU QPC|真实/生成图各被合成几次|真正显示时刻与物理扫描|
|OS 显示观测|DXGI `GetFrameStatistics` / 独立 PresentMon ETW|系统报告的 displayed present ID、显示变化与丢帧证据|面板响应、光子时刻|

GPU timestamp 每个真实帧独占四个 query 槽：场景开始/Prepare 结束、FG 开始/结束。`ResolveQueryData` 写 readback，直到队列完成才读；没有把 CPU 的 `ffxDispatch` 函数耗时当 GPU 时间。

FidelityFX 会先录制 UI，然后按 pacing 安排提交，所以两个 UI 回调的间隔可能很短；直接用它们计算“120Hz 显示节奏”是错误的。本课为此另外尝试 PresentMon 2.6.0 的独立 ETW 捕获。工具版本、二进制 SHA256 与 MIT 许可在 [PresentMon 清单](../../sandbox/d3d12/aa-reconstruction/framegen/presentmon-manifest.json)，不随仓库提交 exe。

若 ETW 表中的 `DisplayedTime` 为 `NA`，不能补零、也不能认为这就是有效显示率。本程序同时使用 1 ms 高分辨率 timer 轮询 DXGI 系统统计，只有成功 HRESULT 且 present ID 变化时才记录。首次 `GetFrameStatistics` 可能返回 `DXGI_ERROR_FRAME_STATISTICS_DISJOINT`，先建立统计序列；失败返回中的输出数据不计入测量。

由于轮询会漏事件，且本课读取的是 SDK 代理交换链，DXGI 的 present-ID 变化率与独立 ETW 的 displayed-rate 不能直接视作同一个指标。本课以 **PresentMon 的 `DisplayedTime` 为显示节奏的主要证据**；DXGI 只提供交叉检查。保留最大轮询间隔、原始 present ID、刷新编号与 QPC；不以 `LastPresentCount` 的增长量冒充实际显示变化总数。`LastPresentCount` 验证 SDK 确实额外提交帧，ETW 表保留显示与未显示记录，不能因两者数值不一致便取更高的数。[微软 flip-model 统计解释](https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/dxgi-flip-model)、[GetFrameStatistics 的限制](https://learn.microsoft.com/en-us/windows/win32/api/dxgi/nf-dxgi-idxgiswapchain-getframestatistics)、[PresentMon 官方测量字段](https://github.com/GameTechDev/PresentMon/blob/v2.6.0/README-ConsoleApplication.md)。

开发验证还发现两个真实问题。窗口完全被编辑器遮挡时，DWM 可见性相关行为会让显示观测远低于提交率；本课的自动测量窗口因此在短时间内置顶，退出立即销毁。其次，普通 `sleep_until` 在本机形成过约 30 ms/1 ms 交替的真实采样间隔；最后改用高分辨率 waitable timer 等待 60 Hz 采样 deadline。这个 timer 解决的是应用侧采样抖动，不能代替 SDK 的显示 pacing；后者仍要按 GPU 完成与显示约束调度生成图和真实图。

这里的计时器也是显式拥有的操作系统对象：

```cpp
HANDLE CreateWaitableTimerExW(LPSECURITY_ATTRIBUTES attributes,
    LPCWSTR name, DWORD flags, DWORD desiredAccess);
BOOL SetWaitableTimer(HANDLE timer, const LARGE_INTEGER* dueTime,
    LONG periodMs, PTIMERAPCROUTINE callback, LPVOID argument, BOOL resume);
```

本课 `attributes=nullptr` 使用默认安全属性，`name=nullptr` 创建匿名对象，`flags=CREATE_WAITABLE_TIMER_HIGH_RESOLUTION`，访问权为 `TIMER_ALL_ACCESS`。`dueTime` 的负数表示相对时间，单位是 **100 ns**；不是负的毫秒。真实帧每次设置一个一次性 deadline，所以 `periodMs=0`；DXGI 统计轮询才设为 1 ms 的周期。`callback/argument=nullptr` 不使用 APC 回调，`resume=FALSE` 不要求唤醒睡眠中的系统。随后 `WaitForSingleObject` 等待，超时视为失败；退出 `CancelWaitableTimer`、`CloseHandle`。高分辨率不等于实时操作系统保证：线程仍可能因系统负载晚醒，因此保留真实测得的 p95/max，而不是把配置的 16.667 ms 当实测结果。[微软创建 timer 文档](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-createwaitabletimerexw)、[设置 timer 文档](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-setwaitabletimer)。

本课的“输入标记到 CPU 提交”只从调用 `GetAsyncKeyState` 前的 QPC 到 `ExecuteCommandLists` 后计时，不含设备采样、排队、显示扫描和面板响应。没有 Reflex 分析器、光电传感器或硬件点击装置，**端到端输入到光子延迟未测量**。这是明确的证据边界，不影响我们验证官方 FG 路径确实运行。

## 9. 动手与自动验收

从仓库根目录执行：

```powershell
& learning/sandbox/d3d12/aa-reconstruction/fetch_sdks.ps1
& learning/sandbox/d3d12/aa-reconstruction/build_framegen.ps1 -Run
```

脚本编译独立程序，然后依次运行关闭与开启 FG 两种配置，每次 240 个真实帧。两轮使用同一运动路径、输出尺寸、相机、VSync 与 Debug 配置；剔除前 30 个真实帧的窗口/缓存/节奏器启动阶段。不要一边跑另一个 GPU 性能测试一边解释本实验的计时差异。

查看结果不重跑 GPU：

```powershell
python learning/sandbox/d3d12/aa-reconstruction/verify_framegen.py --analyze-only
```

原始结果进入 [results/f9](../../sandbox/d3d12/aa-reconstruction/results/f9/summary.json)：`real-frames.csv` 保存真实采样与 GPU 计时；`display-events.csv` 标注每个真实/生成回调；`dxgi-display-observations.csv` 保存 OS 显示观测；`presentmon.csv` 保留独立捕获，不把缺失值掩盖掉；`runtime.json` 保存 provider、Debug 错误和计数。

`run-provenance.json` 在启动时记录源代码、shader、构建脚本、验收脚本、SDK 清单、exe 与 PresentMon 的 SHA256。`--analyze-only` 读取原来的执行证据，不给旧数据换上当前源文件 hash。因此同步到另一台机器后，能区分“重新算了一遍统计”与“用当前代码重新跑过 GPU”。

`frameID=59` 的真实图、`frameID=60` 的生成图和真实图各有读回。自动验证生成图不是任一真实图的原样重复，移动方块的红色像素重心落在两帧中点的 1 像素以内，并检查每幅图的青色 UI 条 8400 个像素、白色准星 500 个像素严格正确。这个检查证明本场景后置 UI 没有被插值变形；不能由一根 UI 条推出所有字体、alpha 混合、动态光标场景都已验证。

完整实测数字由 `summary.json` 保存，最终课程验收必须同时检查实际 provider、生成数、D3D12/FFX 错误、UI 像素与有效显示观测，不能只以窗口打开判定成功。

2026-10-22 本机最终实测如下。两轮均开启 D3D12 Debug Layer，统计区间各 210 个真实帧；场景只含程序化图案，不代表 H 角色路径追踪场景的成本。

|指标|FG 关闭|FG 开启|
|---|---:|---:|
|总真实帧 / 官方生成帧|240 / 0|240 / 240|
|DXGI 最后成功 Present 计数|240|480|
|实际输入/模拟采样率|60.002 Hz|60.000 Hz|
|真实采样间隔 p95|16.970 ms|17.020 ms|
|场景 + Prepare GPU 均值|0.0241 ms（无 Prepare）|0.0472 ms|
|官方 FG GPU 均值|0|0.4157 ms|
|独立 ETW 显示率|59.95 FPS|105.47 FPS|
|ETW 显示间隔 p50 / p95|16.677 / 16.734 ms|8.329 / 16.871 ms|
|输入采样标记 -> CPU 提交均值|0.290 ms|0.532 ms|
|应用 Proxy Present CPU 均值|0.468 ms|0.604 ms|
|D3D12 / FFX / callback 错误|0 / 0 / 0|0 / 0 / 0|

开启 FG 后，显示间隔的中位数接近半个真实帧，但尾部依然可能达到一个真实帧。最终显示率没有被写成理想的 120 FPS；显示提交增加与稳定显示所有生成帧是两回事。两种模式的 ETW `PresentMode` 也不同：关闭路径存在 composed/independent 的转换，开启路径的稳态为 independent flip；因此不能把这张表解释成算法在所有显示环境下固定获得的倍率。

DXGI 轮询记录到的 present-ID 变化率分别约 59.99、120.44 次/秒，与 ETW 的 59.95、105.47 FPS 不完全一致。保留两套原始 CSV，明确区分 API 统计与系统显示事件；这里没有选择较高的数宣传性能，也没有把差值武断地全归为 GPU 慢。窗口可见性、显示模式、SDK 代理统计与采集语义需要分别考虑。

三张图中红色方块的 X 重心依次为 **885.500、883.739、881.500** 像素，生成图距离两幅真实图重心中点为 **0.239 像素**。青色 UI 条各 8400 像素、白色准星各 500 像素全部正确；原图 hash 和检查值写入摘要。这才构成“GPU 官方插值确实生成了中间画面，UI 在之后重新合成”的直接证据。

ETW 的 frame-start-to-displayed 均值也保存在摘要中，但 FG 模式的 ETW frame 是 SDK 的显示提交帧，不等同于主循环的输入采样点。不能把它从约 26.1 ms 变为约 9.6 ms 解读成“端到端按键延迟下降到三分之一”；端到端输入到光子仍然没有测量。

## 10. 自测题与直接答案

**问题 1：60 个真实帧加 60 个生成帧，是否等价于原生 120 FPS？**

答案：图像提交数可能相同，但真实模拟、输入采样与插值误差不同；显示还受系统合成与显示器刷新约束。必须分别记录真实率、生成率、系统显示率和延迟边界。

**问题 2：主队列 fence 到达，能否销毁 FG context 与 UI 资源？**

答案：不能直接推导。SDK 的 UI/present 在另一队列；还要停止新回调并等待 SDK 的全部 presents。资源状态只描述访问用途，不取代跨队列完成关系。

**问题 3：UI 回调为何要在真实帧和生成帧各画一次？**

答案：让 UI 在最终显示图上直接绘制，避免把文字与准星作为世界图案送入插值。代价是额外 UI 工作，需要保持轻量。

**问题 4：`Present` 只花 0.3 ms，能否说输入延迟只有 0.3 ms？**

答案：不能。这只是该 CPU API 调用区间；此前与此后的 GPU 工作、SDK pacing、系统合成、扫描和面板响应不在这个量中。

下一节 F.10 将把成本与画质证据放进统一表格：固定输入条件，观察连续帧里的闪烁、显露和拖影，而不是仅挑一张静止截图。
