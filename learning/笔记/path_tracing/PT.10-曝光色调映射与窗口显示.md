# PT.10 曝光、色调映射与窗口显示

2026-10-21。已把同一份GPU路径追踪历史接入真实交换链，曝光与显示负对照、尺寸/最小化、历史不变和R.13兼容回归均通过。PT.10整章仍进行中，降噪辅助缓冲、成熟降噪器、External Fence与完整性能评测尚待完成。

[共享路径追踪入口](../../sandbox/path_tracing/dxr-path-tracer/README.md)；[共享窗口代码](../../sandbox/d3d12/common/README.md)；[上一节GPU历史](PT.10-GPU线性累积与历史重置.md)。

## 上节自测答案

1. 批均值必须按样本数加权。2个样本均值1、6个样本均值3，合并为(2+18)/8=2.5，不能平均成2。
2. 重置必须完全避开旧历史读取。新资源未初始化，旧资源可能含NaN；NaN*0仍是NaN，不能用old*0+new保证清理。
3. UAV状态不变不代表访问没有依赖：后一次compute需要读到前一次写入，UAV barrier排序GPU访问；CPU读取/释放资源仍须等待Fence，二者分工不同。

## 显示问题分成三个步骤

积分器输出scene-linear RGB，可以大于1。这里以线性sRGB原色解释RGB，相对单位由场景灯强度决定，不是已经标定到显示器cd/m²的绝对亮度。我们需要把它放进SDR的8位RGB输出，同时保留可调整曝光与高光层次。

游戏开发直觉：积分器在测量场景光照，曝光决定看这份测量时的整体尺度，Tone Mapping压缩高光，sRGB编码决定显示线性值如何分配到码值。修改后三项不应改写原始测量结果。

流程固定为：

```text
路径样本 → 线性HDR均值 → 曝光倍率 → Tone Mapping
         → 一次sRGB编码 → UNORM量化 → Back Buffer → Present
```

### 曝光倍率的推导

本课参数e是相对曝光补偿，不是由光圈、快门、ISO计算的绝对摄影EV。约定补偿+1使线性值加倍，0保持不变；两次补偿相加应等价于倍率相乘：

\[
M(0)=1,\quad M(1)=2,\quad M(a+b)=M(a)M(b).
\]

取连续的指数形式便得到M(e)=2^e。于是：

\[
L_{\mathrm{exposed}}=L_{\mathrm{HDR}}2^e.
\]

-2是1/4倍，+2是4倍，不是给每个颜色分量加2。限制e在[-16,16]并拒绝非有限输入；它只是本课参数边界，不是摄影物理的统一限制。

### 从约束构造教学Tone Mapping曲线

想把x>=0映到[0,1)，要求黑色保持0、单调递增、高光趋近1、低亮度附近斜率为1。这些约束没有唯一决定曲线；我们再选择简单有理函数族：

\[
T(x)=\frac{ax}{b+x},\quad b>0.
\]

由x→∞时T→1得到a=1；由T'(0)=a/b=1得到b=1，因此：

\[
T(x)=\frac{x}{1+x},\qquad T'(x)=\frac1{(1+x)^2}>0.
\]

这就是本课使用的Reinhard形式。x=1、4、16分别映到.5、.8、16/17。高亮不会像min(x,1)那样全部变成同一个1，但8位量化仍可能让相邻高光落到同一码值。

我们逐RGB通道应用这条曲线，通道比例可能改变，所以它不是完整的保色调电影色彩管线。商业引擎还需要颜色管理、工作色域转换、自动曝光、艺术调色等；本课选择简单曲线，便于独立CPU/GPU逐码验证，而不是宣称复刻UE的最终显示效果。

### sRGB编码是接口约定，不是Tone Mapping

Tone Mapping后得到显示端线性分量c∈[0,1]。sRGB规定编码：

\[
S(c)=\begin{cases}
12.92c,&c\le0.0031308,\\
1.055c^{1/2.4}-0.055,&c>0.0031308.
\end{cases}
\]

这些系数来自颜色编码规范，不应伪装成由渲染方程推导出的物理定律。它也不是简单pow(c,1/2.2)。标准公式见[W3C提供的sRGB解释文档](https://www.w3.org/Graphics/Color/srgb)。alpha固定1，不进行RGB传递函数编码。

本课交换链、PSO和RTV均为R8G8B8A8_UNORM，shader手动做一次sRGB。UNORM把[0,1]映射到整数码值，不自动执行sRGB传递函数。另一种管线可以在兼容的_SRGB RTV中让硬件编码，此时shader必须输出显示线性值；不能手动编码后又让RTV编码。本节实际验收的是手动编码+UNORM路径，未实现第二条硬件RTV路径。

测试标尺HDR=1、EV0经Reinhard得到.5，真实Back Buffer的灰度码值是：正常188、漏编码127、重复编码223、硬截断255。CPU半向上舍入的漏编码参考是128；GPU浮点运算和格式量化允许1码差异，不能据此声称GPU精确中间值或某一种tie规则。

## 从持久GPU历史直接绘制

共享显示shader位于`learning/sandbox/d3d12/common/hdr_display.hlsl`。VS用SV_VertexID生成覆盖视口的三个顶点，不需要顶点缓冲。PS从根SRV的ByteAddressBuffer读取RGB：

```hlsl
uint address=(pixel.y*sourceStride+pixel.x)*pixelByteStride;
float3 hdr=asfloat(hdrHistory.Load3(address));
float3 exposed=hdr*exp2(exposureEV);
float3 linearDisplay=exposed/(1+exposed);
```

sourceStride是每行多少像素，pixelByteStride是每像素多少字节，二者不能混用。PT.10的步长128，R.13的float4历史步长16；两者RGB均位于记录开头12B。读取辐亮度之后不使用后面的亮度二阶矩、材质或计数。

CPU只读取结果用于验收。显示始终直接消费PathHistory持有的DEFAULT资源，没有先下载成PNG再上传纹理。合成HDR标尺是显示函数专项输入，与真实DXR场景验收分别记录。

显示常量保持48B/12个DWORD：

|偏移|字段|单位|
|---:|---|---|
|0|uint4 sourceRect(x,y,w,h)|源像素|
|16|uint4 destination(x,y,w,h)|Back Buffer像素|
|32|uint sourceStride|像素/行|
|36|float exposureEV|相对补偿档数|
|40|uint pixelByteStride|字节/像素|
|44|uint mode|0正常、1截断、2漏编码、3重复编码|

根参数0为PS可见的t0根SRV，参数1为PS可见的b0根常量。SetGraphicsRootShaderResourceView(0,historyGPUVA)设置地址，不复制历史，也不会替调用者持有资源生命周期；SetGraphicsRoot32BitConstants(1,12,&constants,0)把48B常量值记录进命令流。

为了复用成熟的窗口生命周期，把R.13原WindowDisplay提取到`d3d12/common/window_display.h`。原`dxr_window_display.h`和`dxr_display.hlsl`保留兼容include入口。新旧主线只有一份交换链/RTV/读回实现，也没有复制设备/BLAS/TLAS。

## 像素中心、比例和两种Resize

内部历史尺寸与输出窗口尺寸可以不同。默认内部384×192，客户区480×270；保持2:1比例后目标矩形为480×240，上下各15像素黑边。

设目标矩形内的像素坐标为q，目标宽度D，源宽度S。目标像素中心归一化为(q+.5)/D，映回源后取floor：

\[
p=\left\lfloor\frac{(q+0.5)S}{D}\right\rfloor
=\left\lfloor\frac{(2q+1)S}{2D}\right\rfloor.
\]

shader使用右侧整数表达式，避免浮点数在源像素边界两侧舍入不一致。二维分别计算，再加源矩形偏移。当前上限4096保证乘法范围；宿主还检查最终byte地址在资源内。这是最近邻显示，没有把它称为抗锯齿重建或超分。

仅改窗口大小时，内部积分域不变，历史不需要重置。实际测试641×359→321×481，保持64spp/generation1，竖屏留黑边。

改内部采样尺寸384×192→160×90时，像素划分和相机宽高比改变，需要重分配历史并重置到4spp/generation3。这与上一节“尺寸改变要重置”指的是同一类积分目标变化，不能误推广成任意交换链Resize都必须清空历史。

WM_SIZE只记录尺寸意图。渲染线程在旧帧Fence完成、没有旧Back Buffer录制引用时释放引用，调用ResizeBuffers，再GetBuffer/重建RTV和读回footprint。最小化期间不Dispatch、不Present、不增加计数；恢复后根据真实客户区决定是否重建。

## 交换链API与同步契约

实际调用原型：

```cpp
HRESULT CreateSwapChainForHwnd(
    IUnknown* pDevice,
    HWND hWnd,
    const DXGI_SWAP_CHAIN_DESC1* pDesc,
    const DXGI_SWAP_CHAIN_FULLSCREEN_DESC* pFullscreenDesc,
    IDXGIOutput* pRestrictToOutput,
    IDXGISwapChain1** ppSwapChain);
```

D3D12的pDevice参数实际传DIRECT command queue，不是ID3D12Device。hWnd是本窗口；pDesc描述尺寸/格式/缓冲；后两个可选输入传null，表示窗口模式且不限制特定输出；ppSwapChain接收COM对象，随后QueryInterface为SwapChain3。所有HRESULT检查失败。见[Microsoft API说明](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_2/nf-dxgi1_2-idxgifactory2-createswapchainforhwnd)。

本课desc初始480×270、RGBA8_UNORM、SampleCount1、BufferCount2、RENDER_TARGET_OUTPUT、FLIP_DISCARD、STRETCH、AlphaMode IGNORE。使用GetCurrentBackBufferIndex选择当前buffer，不假设索引严格交替。Flip模型把缓冲交给桌面合成系统，不能把Present理解成CPU逐像素拷贝屏幕；见[DXGI flip模型](https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/dxgi-flip-model)。

设置RGB_FULL_G22_NONE_P709作为SDR输出颜色空间并检查支持。它不是HDR10/PQ输出；应用使用HDR中间值不意味着显示器正在进行HDR呈现。当前图像字节验收只覆盖应用Back Buffer，不校验显示器校准或整个操作系统颜色管理。

GPU一帧：

```text
历史UAV → PIXEL_SHADER_RESOURCE
Back Buffer PRESENT → RENDER_TARGET
DrawInstanced(3,1,0,0)
Back Buffer RENDER_TARGET → COPY_SOURCE → 复制实际像素到Readback
Back Buffer COPY_SOURCE → PRESENT
历史PIXEL_SHADER_RESOURCE → UAV
Close / ExecuteCommandLists
Present(1,0)
队列Signal → CPU等待Fence → Map验收
```

调用Present(1,0)使用同步间隔1，flags0；DXGI_STATUS_OCCLUDED单独统计，其他失败HRESULT抛错。此处无撕裂/独占全屏或HDR输出实现。

为使Fence位于Present之后，UploadContext::SubmitWait增加可选beforeSignal回调；PathHistory::Flush/Readback转发它。默认不传回调保持旧行为。回调只能做Present等提交后操作，不能释放资源或重置命令列表。Fence完成不表示显示器已扫描到该帧，也不是端到端显示延迟测量。本课仍每帧等Fence，单份Readback在这个同步前提下安全；多帧在途需要帧资源与异步退役，不能删除等待就宣称支持。

读回纹理必须用GetCopyableFootprints获得布局。641像素一行有效RGBA字节为2564，但实际RowPitch为2816；321宽时有效1284、RowPitch1536。CPU按footprint.Offset+y*RowPitch+x*4读取，只保存有效RGB，不把padding写进PPM。Map读范围覆盖读回资源，Unmap写范围[0,0)；alpha逐像素检查255。

若窗口关闭，先结束渲染循环再销毁窗口/交换链；WM_CLOSE仅标记请求。自动验收中提前关闭会报告未完成；交互模式允许立即关闭。没有实现设备移除后的重建恢复，失败不会被当成成功帧。

## 运行与验收

仓库根目录：

```powershell
.\learning\sandbox\path_tracing\dxr-path-tracer\verify_display.ps1
```

脚本使用已完成PT.8的资产与能量表，CMake/VS2022构建path_viewer，DXC编译路径/累积/共享显示shader；运行16帧显示、GPU历史回归、PPM分析，最后通过verify_display_compat.ps1构建并运行R.13窗口/Resize回归。旧.cu宿主用build.ps1/sm_120重编译，仍无新增CUDA kernel。

新结果全部直接写`dxr-path-tracer/results/pt10-display/`，R.13回归也在其r13-regression子目录，不覆盖历史结果。PPM来自真实Back Buffer；analyze_display.py只转PNG/排版，不再次应用曝光或gamma。display.csv记录尺寸、历史计数/代号、曝光、模式、显示矩形和最大字节差。

从共享主线目录打开持续交互窗口：

```powershell
.\build\Release\path_viewer.exe .\results\pt08\gallery.gltf .\results\pt10-display .\results\pt08\energy-lut.bin .\results\pt10-display\interactive interactive
```

五个参数是场景、shader目录、能量表、输出目录、verify或interactive。交互入口提供+/-曝光、WASD相机平移、R重置、T切换Reinhard/截断、Esc关闭；只消费本窗口按键消息。它是参考查看器，尚无鼠标自由转向、编辑器UI或高吞吐多帧调度；完整自由相机在计划H阶段。自动测试通过相同渲染/相机/显示函数执行状态变化，没有自动模拟用户键盘输入，因此不把输入手感称为已测性能。

### 本机实测

|项目|结果|
|---|---|
|当前Path Tracer|16 Present/16逐帧验证，Back Buffer使用9/7，occluded0|
|颜色/alpha|RGB最大差1码，badRGB0，alpha全255|
|同步/验证层|Fence20/20，Debug/GPU Validation0|
|同一64spp的EV -2/0/+2|每像素128B历史逐字节不变，count64/generation1|
|漏编码/重复编码/截断|显示图变化，历史逐字节不变|
|输出窗口Resize|641×359、321×481；内部384×192历史保持|
|最小化3tick|提交数、Present数、历史样本数均不变|
|继续采样/相机/内部尺寸/手动重置|68spp/gen1 → 4/gen2 → 4/gen3 → 4/gen4|
|GPU历史回归|前节全部通过，Debug0，Fence33/33|
|R.13 window兼容|96帧，buffer48/48，RGB≤1，Fence97/97，Debug0/0|
|R.13 resize兼容|64帧，5次重建，3次reset，最小化跳过3tick，Fence65/65，Debug0/0|

正常EV0显示区平均RGB码值100.1306，EV-2为57.1095、EV+2为151.2639；漏编码44.9523，重复编码161.3402。这些是显示码值的平均，仅说明显示变化，不是线性辐亮度或物理能量统计。

![实际Back Buffer对比](../../sandbox/path_tracing/dxr-path-tracer/results/pt10-display/display-comparison.png)

图已实际查看，黑边、曝光与两个编码反例符合逐像素验证。64spp仍有噪声，显示曲线不会消除Monte Carlo误差。当前保留最近邻放大，能看见原像素；它与降噪或超分是不同处理。

## 下一节

继续降噪输入与外部消费者：albedo/normal/depth如何定义、怎样避免把首个抖动样本误当完整特征缓冲、成熟降噪器如何作为替换模块，以及D3D12/CUDA External Memory/Fence的所有权时间线。完整误差、GPU时间、射线数和显存报告仍待完成。

自测：为什么曝光+1是乘2而非加1？为什么应用内部用HDR浮点仍可以输出SDR？为什么只改窗口可以保留历史，而改内部采样尺寸通常要重置？下一节按授权直接回答并继续。
