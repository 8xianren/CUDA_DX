# F.10 固定序列质量与性能评测

[课程工程与命令](../../sandbox/d3d12/aa-reconstruction/README.md) · [上一课：帧生成](F.9-官方帧生成与显示节奏.md) · [讲义索引](README.md)

本课把F.1–F.9收束成可重复的实验。问题不是“打开一个选项后截图是否更漂亮”，而是：在同一时刻、同一几何、同一曝光下，算法输出偏离参考多少；这种误差随时间如何变化；为此支付多少GPU工作。源码入口为[main.cpp](../../sandbox/d3d12/aa-reconstruction/src/main.cpp)中的`Sequence`，评测入口为[analyze_sequences.py](../../sandbox/d3d12/aa-reconstruction/analyze_sequences.py)，最终证据由[summarize_verification.py](../../sandbox/d3d12/aa-reconstruction/summarize_verification.py)汇总。

## 1. 先定义要测的东西

游戏开发中“更清楚”“更稳定”“更快”是三个不同问题。锐化可能让单帧轮廓更鲜明，却增强运动中的闪烁；强历史权重可以稳定背景，却把移动角色拖成尾巴；显示帧数增加，也不说明游戏输入采样加快。要让结论有因果意义，必须固定其它变量，只改变被比较的处理链。

因此本课固定输出640×360，固定时刻`t=frame/60`，连续120帧；橙色物体平移并旋转，细长斜线测试覆盖，绿色裁剪叶片测试高频边缘，棋盘测试纹理采样，青色半透明粒子测试透明运动与响应遮罩。第60帧相机切换，所有需要历史的模式显式reset；没有在不同模式中随意改变曝光、相机路径或动画速度。UI在最终输出分辨率合成，不进入图像质量评分。

投影宽高比固定为640/360；SDK推荐内部尺寸可能经过整数取整，例如426/240不严格等于640/360，不能再拿内部尺寸构造相机投影。`SceneFrame.outputAspect`表达稳定视锥，viewport仍按内部尺寸设置。该问题在复核中修复，四个比例不一致的SDK档位连同DRS/resize重新采集；比例本来相同的配置不受影响。

19种模式分别是参考、NoAA、4×MSAA（alpha clip与其它模式一致；A2C单独在F1比较）、教学FXAA、教学TAA及三个消融、双线性、双三次、官方NIS、FSR四档和XeSS四档。消融表示只关闭一个组成部分，观察它对结果的影响：`taa-no-reprojection`、`taa-no-rejection`、`taa-no-clamp`。它不是另一种经过完整优化的产品方案。

纹理压力场景曾有一个真实问题：最初单像素交替的棋盘在第一层mip就平均成灰色，后续采样几乎没有纹理细节，无法支撑“高频纹理质量”的结论。最终版本改为256²纹理中的8×8 texel棋盘格、真实mip链及UV×3，然后完整重采集所有方法。这个修正说明：验证场景必须确实激发目标现象，代码中存在一张纹理不代表实验已经测到纹理混叠。

## 2. 从像素面积积分到有限参考

一个输出像素希望表示一小块屏幕面积内的平均辐射亮度，而不是中心处一个点的颜色。连续图像记为`L(x,y)`，单位面积像素P的理想结果是`∫P L(x,y) dxdy`。解析求积不可行时，可以细分像素面积、取各子区域的代表样本求平均。

本课选择横纵各4倍光栅分辨率：2560×1440渲染后，每个640×360输出像素聚合对应的4×4块：

\[
R_t(x,y)=\frac1{16}\sum_{j=0}^{3}\sum_{i=0}^{3}C_t(4x+i,4y+j).
\]

[reference.hlsl](../../sandbox/d3d12/aa-reconstruction/shaders/reference.hlsl)逐一加载16个线性HDR样本再平均。这里不能用一次双线性采样代替，因为它最多混合相邻4个texel，代表的积分区域不同。先在线性域平均，再进行显示映射；对sRGB数值直接平均会改变能量关系。

这个参考仍是有限采样，不是解析真值。极细几何、alpha裁剪和纹理LOD依然影响它。高分辨率光栅还会自然选择不同mip，所以全帧误差反映的是最终重建效果，不是只隔离某一个滤波器数学误差。不能凭这个小场景给所有游戏、材质或厂商做普遍排名。

## 3. 坐标对齐比挑指标更早

相同frame编号还不够，两个结果必须描述同一个输出格点。若几何经jitter后从`u`移到`u+j`，原抖动图在坐标`q`存储的是稳定图在`q-j`的颜色。要得到稳定格点u，就应读取抖动图的`u+j`，符号是加号。

教学TAA保留抖动网格上的历史，这使它与上一课推导的`previousUV = currentUV + motion + previousJitter-currentJitter`一致。最终另调`UnjitterCS`，用`uv+jitterUV`采样到第三张独立纹理，供显示和本课评测；这张纹理不反向覆盖历史。若直接拿抖动后的历史图与稳定参考逐像素比较，就会把残留的采样位移也算成重建缺陷。本轮审查发现并修复了这个问题，四个TAA模式随后重新采集，额外pass也计入重建时间。

该教学方案有额外双线性滤波，边界使用clamp，所以可能变软。商业实现通常把固定输出格点的重建直接融入时域滤波；这里保留拆开的过程以便分别验证重投影与输出网格变换。CPU/GPU oracle另有正jitter、负jitter、零jitter、边界clamp四例，不用看图猜符号。

SDK的采样周期也不能一概写成8：输入更低时，需要覆盖更多输出亚像素。FSR按实际输入宽度调用官方phase-count查询；XeSS按官方至少`8×(outputWidth/renderWidth)²`的下界向上取整。教学TAA保留8相。最终摘要记录每种配置的真实周期，Benchmark必须与质量捕获一致。依据：[XeSS官方集成指南](https://github.com/intel/xess/blob/main/doc/xess_sr_developer_guide_english.md)。

材质LOD统一为`log2(renderWidth/outputWidth)`；没有给FSR另外加官方建议中可调的−1。这是为了保持本课材质采样基线一致，不代表已替每个SDK寻找最佳参数。相同的“Quality”名字也不是公平工作量单位：必须看实际输入尺寸、输出尺寸与采样周期。

## 4. 从误差定义推导数值

令同一时刻的算法输出为A、参考为R，RGB线性误差为`e=A-R`。有N个RGB分量时，均方误差`MSE=(Σe²)/N`：平方避免正负抵消，也让少数大误差占更大权重。报告同时保留HDR MSE，因为光照值可能超过1，不能为了好看先截断HDR再称为辐射亮度误差。

显示域先固定曝光EV=0，再按与DisplayPS相同的流程`max(HDR,0) → c/(1+c) → sRGB`，得到[0,1]浮点RGB；尚未量化成8位。对显示误差d，`MAE=(Σ|d|)/N`更直接表示平均偏差；`PSNR=10log10(1/MSE_display)`。峰值1来自这个显示域约定，并不是HDR的普遍上限。参考与自身比较MSE=0时PSNR无限大，JSON用明确标记表示，不把Infinity写成不合规范数值。

单帧MAE不能说明闪烁。直接算`A_t-A_(t-1)`又会把本来就应当发生的物体运动当成问题。先对齐到同帧参考，定义`d_t=T(A_t)-T(R_t)`，再统计：

\[
E_{temporal}=\sqrt{\operatorname{mean}_{t,p,c}[(d_t(p,c)-d_{t-1}(p,c))^2]}.
\]

第59→60帧是真实camera cut，故排除这对差分，120帧得到118对。这个数叫“误差的时域变化”，不能直接改名为人眼闪烁评分：误差图案本身随物体移动也会改变固定像素处的数值，而且这里没有运动补偿或感知模型。

全帧数字容易被大片背景淹没，因此另统计静态背景、移动遮挡物、遮挡显露、透明粒子四类ROI。ROI是region of interest，即关心的像素集合；所有方法共用NoAA guide生成的集合，避免各算法自行挑选有利区域。

显露区怎样判定？当前可见点沿motion查询上一帧深度：若上帧实际深度比该点预期的上一帧深度明显更近，说明当时有前景挡住了它。只有这个有方向的关系才记为显露；普通不匹配、越界和cut首帧不一概叫显露。容差为`max(.001, .02×|expectedDepth|)`。guide为单采样，边缘分类会误差；透明guide仅表示最后覆盖的一层，所以透明ROI是压力测试近似，不代表多层透射的完整运动。

## 5. GPU成本的测量与资源寿命

质量捕获开启D3D12 Debug/GPU Validation并读回每帧图像，不能用它作为正式性能数字。另开`bench`进程关闭这两类调试，去掉图像读回；每种模式40帧，排除前8帧，汇总剩余32帧的均值、中位数与p95。本课队列仍逐批等待，未锁定GPU频率，这只是当前机器的小场景成本记录。

`Timer`在[gpu_resources.cpp](../../sandbox/d3d12/aa-reconstruction/src/gpu_resources.cpp)使用两个timestamp查询。关键API原型与约束：

```cpp
HRESULT ID3D12CommandQueue::GetTimestampFrequency(UINT64* pFrequency);
void ID3D12GraphicsCommandList::EndQuery(
    ID3D12QueryHeap* heap, D3D12_QUERY_TYPE type, UINT index);
void ID3D12GraphicsCommandList::ResolveQueryData(
    ID3D12QueryHeap* heap, D3D12_QUERY_TYPE type,
    UINT startIndex, UINT numQueries,
    ID3D12Resource* destination, UINT64 byteOffset);
```

`pFrequency`接收本队列每秒tick数，检查HRESULT后才能使用；timestamp没有BeginQuery，在两个边界分别EndQuery，index为0/1。Resolve的heap/type要对应，startIndex=0、numQueries=2，目的为可供CPU读取的Readback buffer，offset=0且按要求对齐。buffer至少容纳两个UINT64；查询堆和读回资源由Timer持有，覆盖提交的Fence完成后CPU才能Map读取。CPU看到GPU写入的完整64位值后，用浮点`1000×(end-begin)/frequency`得到毫秒，不能整数除法截成0。API依据：[D3D12时间测量](https://learn.microsoft.com/en-us/windows/win32/direct3d12/timing)。

`gpu_frame_ms`范围包括场景、MSAA Resolve（若有）以及重建；`gpu_reconstruction_ms`只包含后处理/SDK dispatch，TAA包含最终Unjitter。两者均不包含后面的深度历史复制、CPU等待、资源初始化、Present、桌面合成与屏幕扫描。因而不能把`1000/gpu_frame_ms`叫作H人物Demo或真实游戏FPS。F.9的窗口/ETW指标在独立链路记录，且其GPU计时开启Debug，也不能直接混入此性能表。

## 6. 实测与如何解释

2026-10-22，RTX 5070 / 驱动610.88：最终汇总 **32组验收全部通过**，19种配置各120帧，共2,280帧质量图；另19×40=760帧GPU成本采集。正确性运行D3D12 Debug/GPU Validation告警与错误为0。下表GPU毫秒仅对应本节定义的离屏区间，排除每种模式前8帧后取32帧均值。

|模式|内部尺寸|显示MAE↓|显示PSNR dB↑|误差时域变化↓|场景+重建 ms|重建 ms|
|---|---|---:|---:|---:|---:|---:|
|reference|2560×1440|0.000000|∞（自身）|0.000000|0.21332|0.06391|
|noaa|640×360|0.009803|29.851|0.010866|0.02043|0.00406|
|msaa4|640×360|0.008032|32.619|0.004263|0.03643|0.00353|
|fxaa|640×360|0.017828|27.161|0.010020|0.03022|0.01414|
|taa|640×360|0.040230|21.713|0.018952|0.03389|0.01420|
|taa-no-reprojection|640×360|0.023024|25.833|0.044766|0.03357|0.01386|
|taa-no-rejection|640×360|0.041968|21.328|0.018332|0.03303|0.01345|
|taa-no-clamp|640×360|0.041840|21.519|0.018880|0.03159|0.01181|
|bilinear|320×180|0.038943|22.168|0.014255|0.01609|0.00407|
|bicubic|320×180|0.033844|23.184|0.018235|0.02339|0.01161|
|nis|320×180|0.030012|24.301|0.014895|0.02710|0.01522|
|fsr-native|640×360|0.012819|30.567|0.009889|0.09200|0.07231|
|fsr-quality|426×240|0.024429|26.291|0.012794|0.07960|0.06314|
|fsr-balanced|376×211|0.028168|25.211|0.013650|0.07705|0.06123|
|fsr-performance|320×180|0.032498|24.032|0.014853|0.07341|0.05819|
|xess-native|640×360|0.018886|27.853|0.011865|0.24034|0.22059|
|xess-quality|377×212|0.024391|25.897|0.015395|0.22982|0.21410|
|xess-balanced|320×180|0.024993|25.786|0.018381|0.23292|0.21766|
|xess-performance|279×157|0.025595|25.604|0.018465|0.23116|0.21694|

结果没有证明教学TAA普遍优于NoAA：本场景TAA显示MAE为0.040230，NoAA为0.009803，实际图中棋盘与细线确实被累计双线性历史滤波软化。关闭重投影后MAE降到0.023024，但误差时域变化升到0.044766（完整TAA为0.018952），说明单帧更锐与时间上更稳定不是同一个目标。

深度拒绝的作用在显露ROI更清楚：完整TAA的显示MAE为0.054282，关闭深度拒绝后升至0.174102，约3.21倍；全帧MAE却只由0.040230变为0.041968。大片背景会掩盖少量新显露边缘的严重错误，这正是不能只报全局平均的原因。

MSAA4统一alpha-clip后，显示PSNR为32.619 dB、误差时域变化0.004263；这里几何边缘占有可观权重，结果不能外推到全屏shader aliasing或PT随机噪声。320×180的双线性、双三次、NIS及部分SDK虽有相同输入面积，滤波、锐化、历史和透明支持仍不同；表格展示本实验的取舍，不给厂商做普适排名。

详表：[质量指标](../../sandbox/d3d12/aa-reconstruction/results/f10/quality/metrics.csv)、[ROI与逐方法摘要](../../sandbox/d3d12/aa-reconstruction/results/f10/quality/summary.json)、[GPU性能摘要](../../sandbox/d3d12/aa-reconstruction/results/f10/benchmark/summary.json)。可打开[同帧对照图](../../sandbox/d3d12/aa-reconstruction/results/f10/quality/contact-sheet.svg)和[逐帧误差曲线](../../sandbox/d3d12/aa-reconstruction/results/f10/quality/error-over-time.svg)。SVG内嵌缩略图便于分享；计算使用完整浮点读回，不使用缩略图。

阅读消融时不要预设每个机制在每个指标上都会单调变好。邻域裁剪可能限制拖影，也可能丢失有用历史；关闭深度拒绝可能降低大片平坦背景的平均误差，却在新显露边缘混入错误前景。应结合ROI、切镜帧和错误分布解释，而不是只挑一个全局数宣布胜负。

## 7. 动手、失败路径与复现

从仓库根目录执行：

```powershell
& learning/sandbox/d3d12/aa-reconstruction/build.ps1
& learning/sandbox/d3d12/aa-reconstruction/verify.ps1 -SkipBuild
```

首次构建按固定hash恢复官方依赖；运行会生成大量本地浮点图像，约数GB至十余GB，保留足够空间。`sequence`用于120帧质量捕获，`bench`用于关闭调试的40帧成本，两者不是交互窗口查看器；F1/F2短窗口、F9真实帧生成窗口另有入口。完整命令见工程README。

分析只读每帧连续RGBA float32，布局为`[height,width,4]`，每像素16字节；只用RGB算误差。D3D12读回时先按GetCopyableFootprints给出的row pitch去掉行padding，不能假定GPU纹理原生就是紧密CPU数组。Python检查字节数、有限值、120帧齐全、输出尺寸相同；缺帧或正式SDK回退时显式失败，不插值补造图像。每种模式在独立进程初始化历史，避免前一种配置的状态残留。

汇总脚本进一步要求Benchmark的provider、尺寸和jitter周期与捕获相同，且fallback=false。专门的`fsr-unavailable`故障注入必须成功走双线性回退，但它不能冒用FSR名义进入性能排名。SDK初始化失败可以选择空间回退；正式dispatch失败则终止该次实验，不能写一个成功摘要继续发布。

源码、第三方版本清单、JSON/CSV/日志、SVG随仓库提交；DLL/EXE/缓存和数GB原始浮点图不提交。新电脑先恢复依赖、构建再运行，已有报告记录的是2026-10-22本机环境，不代表新电脑也已经验证通过。

## 8. 自测答案与课程收束

1. 为什么用同一frame但不同jitter格点仍不公平？因为像素中心对应的屏幕位置不同，误差会混入采样坐标位移。先稳定输出格点，再比较。
2. 为什么Quality档不能直接横比GPU毫秒？厂商推荐的内部尺寸不同，参与光栅与重建的工作量不同，必须同时报告尺寸。
3. PSNR高是否一定没有拖影？不一定，少量移动轮廓的严重错误可能被背景平均掉，需看显露ROI和序列。
4. 帧生成开关后Present数翻倍，输入是否翻倍？不会，输入采样和仿真仍随真实帧节奏，显示与延迟分别测量。
5. F完成是否意味着H已具备所有选项？没有。F把机制与SDK接入在独立可控实验室验收；后续接入H仍需为骨骼变形、材质/透明、PT噪声、历史寿命与帧调度生成正确输入，并再次验收。

至此F的完整链条是：覆盖采样 → 离屏资源流 → 空间边缘滤波 → 时域输入契约 → 历史重建 → 动态分辨率 → 官方超分 → 官方帧生成 → 可重复评测。它为后续H画质迭代提供已经验证的模块和判断方法，但不把教学小场景包装成商业引擎最终效果。
