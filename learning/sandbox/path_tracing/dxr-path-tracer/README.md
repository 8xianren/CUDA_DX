# PT.8–PT.10共享DXR路径追踪主线

本目录保留多课共用的一份实现。PT.8限定材质/积分模型与PT.10核心集成均已完成验收：持久GPU历史/重置、SDR窗口、OIDN CUDA消费者、External Memory/Fence以及质量/GPU时间/射线/显存报告。保留同步参考查看器与声明的模型边界；后续PT.9另建CUDA求交/执行架构对照，不替换本主线。

|文件|职责|
|---|---|
|pbr_resources.h/.cpp|64B材质表、每材质三种sampler、能力/参数检查；复用C/D几何与纹理上传|
|surface.hlsli|16B身份/重心payload，读取VB/IB、world、几何法线、UV0、顶点色和三类纹理|
|pbr.hlsli|GGX单次反射、基线/修正漫反射、混合PDF、delta/null与保留采样微面法线|
|energy_lut.h/.hlsli|133144字节float表格式/检查、log(alpha)与四次方余弦节点的CPU/GPU查询|
|path_config.h|128B配置头、64B世界三角形灯、112B像素读回布局|
|path_render.cpp|相机基、灯面积CDF、教学IOR覆盖、共享后端调用、分批CPU合并、稀疏独立CPU求交与PFM输出|
|path_integrator.hlsl|顺序TraceRay多反弹、NEE/Power MIS、delta/介质状态、etaScale RR与诊断|
|make_gallery.py|标准glTF粗糙度场景：16球、两块灯、地板/背景|
|verify_path.ps1 / analyze_gallery.py|八组运行、PBR回归、线性HDR统计/MSE和实际渲染预览|
|path_scene.h|PT.8/PT.10共用相机、世界三角形、面积灯CDF、配置打包与教学IOR|
|path_pixel.hlsli|112B批次像素与128B历史像素的共享shader布局|
|path_history.h/.cpp / path_accumulate.hlsl|历史键/代号/计数、持久GPU资源、批次录制、线性加权和显式同步|
|path_history_test.cpp / verify_history.ps1 / analyze_history.py|不等长分批、真实场景编辑重置、NaN历史、Resize拒绝、线性收敛图和共享后端回归|
|path_viewer.cpp|GPU历史直接显示、实际Back Buffer验收、曝光/编码反例、窗口与内部尺寸分离；可选持续交互入口|
|verify_display.ps1 / verify_display_compat.ps1 / analyze_display.py|显示16阶段、GPU历史与R.13兼容回归、实际读回PNG；共用d3d12/common显示组件|

当前限定OPAQUE、单面、UV0、几何法线、mip0。MASK/BLEND、doubleSided、normal/AO纹理明确拒绝；缺失纹理按各槽默认值处理。基础色/发光走sRGB RGB解码，MR走线性G/B；基础色还乘顶点色。

旧基线漫反射/镜面耦合不满足白炉能量界，最大输出1.2686569；保留作负对照。使用PBR_ENERGY_BALANCED编译并在MaterialBindings::energy提供有效表，可启用修正；其已测最大白炉参考1.00006965。path_integrator.hlsl默认启用修正模型。

从仓库根目录构建/运行当前PT.8验收：

```powershell
.\learning\sandbox\path_tracing\pt08-materials\verify_pbr.ps1
.\learning\sandbox\path_tracing\pt08-materials\verify_energy_gpu.ps1
```

共享库目标`pbr_render`由`d3d12/gltf-scene/CMakeLists.txt`构建并链接scene_render；可执行文件为`pt08-materials/build/Release/pbr_test.exe`。验证脚本自身定位路径，不依赖当前目录。作为PT.8专项实验，生成资源/CSV/日志存于相邻`pt08-materials/results/pbr/`，主线后续自身输出按课节存`results/<课节>/`，不混放。

本课[讲义](../../../笔记/path_tracing/PT.8-glTF材质与GPU混合采样.md)与[验证程序说明](../pt08-materials/README.md)。后端同步调度只有一份：`gltf-scene/src/material_sampling.cpp`中的DispatchMaterialBuffer；D.3原接口只是其兼容封装，D.3与D.4受影响回归已通过。
## 能量模型进度补充（2026-10-21）

非金属双侧归一化剩余能量闭合已完成[CPU推导](../../../笔记/path_tracing/PT.8-漫反射与镜面能量耦合.md)及[GPU表/窄高光验收](../../../笔记/path_tracing/PT.8-GPU能量表与窄高光数值稳定性.md)。共享根参数10映射t7，表通过InstanceUpload由MaterialBindings持有直到Fence结束；旧shader不读取新增绑定。新表/资产/日志在相邻pt08-materials/results/energy-gpu，主线今后的渲染输出仍按results/<课节>/组织。

## PT.8共享积分器与粗糙度图像

[讲义与完成审计](../../../笔记/path_tracing/PT.8-共享积分器与粗糙度场景验收.md)。仓库根目录运行（脚本内部与启动工作目录无关）：

```powershell
.\learning\sandbox\path_tracing\dxr-path-tracer\verify_path.ps1
```

宿主CMake/VS2022 Release，shader DXC lib_6_3/HV2021；CPU仅构表/组织/验收，实际渲染为RTX5070 DXR，无CUDA kernel。可执行文件build/Release/path_render.exe。从本目录单独运行：

```powershell
.\build\Release\path_render.exe .\results\pt08\gallery.gltf .\results\pt08\path.dxil .\results\pt08\energy-lut.bin .\results\pt08\custom 384 192 256 8 1 0 1 12
python .\analyze_gallery.py
```

参数依次为glTF、DXIL、能量表、输出目录、宽、高、SPP、K、mode、seed、RR开关、灯倍率。mode0仅BSDF、1为MIS、2为故意双计数；普通复现使用mode1。八个预定义case为primary/direct/mis/bsdf/double/rr/reference/no-light；分析脚本读取完整八组结果，custom单次运行不替代完整验收。

配置t6为128B头后接64B灯记录，不新建另一套DXR后端；材质64B的emission.w接受可选教学IOR，默认0不改变前课。标签teaching_glass在本宿主被显式覆盖为IOR1.5，不是glTF透射扩展实现。玻璃只支持互不嵌套的封闭网格；内部漏到环境、非法介质切换、非有限数值均判失败。

所有本节输出直接写results/pt08：资产、能量表、DXIL、验证日志、comparison.json、总览PNG/SVG；各case子目录包含线性HDR radiance.pfm、112B/像素的pixels.bin、summary.json、run.txt、preview.png。每批最多32spp，CPU加权合并线性矩；尚无持久GPU历史。预览Reinhard+sRGB，不用于MSE或能量验收。

分析/绘图沿用相邻pt08-materials/results/ggx/plot_packages中的numpy/matplotlib/Pillow隔离依赖。几何/统计CPU和GPU数值验收由C++执行，Python再比较八组均值与图像MSE。

2026-10-21：63496三角形、20实例、4灯三角形，总灯面积27。八组共180486144相机路径样本/522047572 TraceRay，512条CPU主射线审计，K0额外1024 CPU辐亮度样本最大差2.63751e-9；invalid/nonfinite全0，Debug0、Validator0/0。256spp MIS均值Y=.41353977，BSDF=.41351210，高样本参考=.41341498；重复计数=.64142387。线性MSE分别.00144223/.00694283，MIS约改善4.814倍，但不是等时间/等射线比较。RR减少射线4.2825%、均值一致。修改材质工厂/Surface后，前课1966080路径GPU材质回归通过。

已查看粗糙度扫描与对照图。保持几何法线、UV0、mip0、单面OPAQUE的范围；玻璃无吸收，镜面极限显式delta，固定K8有截断偏差，固定1e-4偏移只对当前场景尺度验收。成熟降噪器、GPU历史重置、窗口显示和公平性能报告属于PT.10。



## PT.10 持久GPU线性历史与重置（本小节已验收）

复用PT.8资产与积分器，128B PathConfig偏移104现在是sampleOffset，默认0保持旧入口行为。路径shader按全局样本编号取随机数；path_accumulate.hlsl按样本数加权，将112B批结果合入128B持久历史，每像素另存uint计数/代号。t0批SRV→u0历史UAV的compute与DXR共用DIRECT队列，显式transition/UAV barrier。

MaterialRayPipeline位于共享后端src/material_sampling.h/.cpp，缓存根签名/State Object/SBT；Record不提交或等待。PathHistory持有输出、历史和各批配置Upload；Flush提交并等Fence后回收Upload，Readback仅在检查点复制。场景资源和对象在Flush/Readback完成前不能释放；Resize有未提交批次时拒绝。材质/场景编辑必须更新实际GPU资源并递增对应revision。

工作目录可为仓库根目录，脚本自行定位：

```powershell
.\learning\sandbox\path_tracing\dxr-path-tracer\verify_history.ps1
```

先完成PT.8的verify_path.ps1以生成gallery.gltf/bin、energy-lut.bin和PBR回归资产。脚本构建path_history_test/path_render/pbr_test/scene_boundary_test，用DXC编译路径lib_6_3与累积cs_6_0，再运行历史验收、PT.8/PBR/D.4回归和绘图。没有CUDA kernel。

从本目录单独运行：

```powershell
.\build\Release\path_history_test.exe .\results\pt08\gallery.gltf .\results\pt10-history\path.dxil .\results\pt10-history\accumulate.dxil .\results\pt08\energy-lut.bin .\results\pt10-history
```

五个参数依次为glTF、路径DXIL、累积DXIL、能量表、输出目录。新结果直接写results/pt10-history：history.csv记录真实编辑与全新历史对照；convergence.csv记录SPP/射线；spp*.pfm和reference1024.pfm保留线性HDR；history-convergence.png/.svg为预览，analysis.json记录线性MSE。run/build及各回归日志同目录。

实测2+5+6对一次13spp最大归一化差3.06463e-7，路径计数/首样本特征一致；相机、尺寸、材质、场景、灯、seed重置通过，NaN旧历史重置误差0。128×64的1→256spp MSE .484238→.00272933。Debug/GPU Validation0，Fence33/33；共享后端三项回归通过。完整讲义：[GPU线性累积与历史重置](../../../笔记/path_tracing/PT.10-GPU线性累积与历史重置.md)。

当前是离屏GPU持久历史，检查点/每128spp命令组仍同步等待；未完成交互显示、External Fence/降噪及性能验收，PT.10保持进行中。原PT.8入口仍保留CPU批次平均用于回归，并未冒充新历史路径。


## PT.10 曝光与实际窗口显示（本小节已验收）

共享显示实现位于[d3d12/common](../../d3d12/common/README.md)，R.13保留include兼容入口。ByteAddressBuffer根SRV显式读取128B步长的历史RGB；48B根常量指定源/目标矩形、行跨度、曝光、字节步长和诊断模式。正常路径为曝光→Reinhard→一次手动sRGB→RGBA8_UNORM交换链。UploadContext/PathHistory的可选beforeSignal回调使提交顺序为Execute→Present→Signal→Wait。

仓库根目录运行，脚本自行定位：

```powershell
.\learning\sandbox\path_tracing\dxr-path-tracer\verify_display.ps1
```

依赖已完成的PT.8资产与能量表。构建CMake/VS2022宿主，编译路径lib_6_3、累积cs_6_0、共享显示vs_6_0/ps_6_0；运行16帧自动显示、GPU历史回归、读回分析，最后构建并运行R.13的96帧window与64帧resize兼容测试。旧.cu宿主按build.ps1/sm_120重编译，没有新增CUDA kernel。

结果全部直接写results/pt10-display：display.csv记录每阶段状态，PPM为实际Back Buffer读回，PNG只转换字节/排版；analysis.json记录显示码值，history-regression和r13-regression保存受影响回归。共享窗口每像素CPU double对照RGB最大1码，alpha全255；16 Present、Fence20/20、Debug0；曝光和显示模式改变时历史逐字节不变。R.13 window/resize与前节历史回归均通过。

从本目录开启持续交互查看器：

```powershell
.\build\Release\path_viewer.exe .\results\pt08\gallery.gltf .\results\pt10-display .\results\pt08\energy-lut.bin .\results\pt10-display\interactive interactive
```

参数为场景、shader目录、能量表、输出目录、模式。interactive提供+/-曝光、WASD相机平移、R重置、T切换Reinhard/截断、Esc退出；窗口可调整大小，最小化暂停。它仍是逐帧同步/读回的参考查看器，没有鼠标自由相机或多帧高吞吐调度，不用于宣称最终性能。自动测试验证相同渲染/显示入口的状态变化，不包含自动键盘操纵。

只改交换链尺寸保持内部历史；改内部采样尺寸重置。该显示小节尚未接降噪；后续互操作见下节。讲义：[曝光色调映射与窗口显示](../../../笔记/path_tracing/PT.10-曝光色调映射与窗口显示.md)。

## PT.10 降噪特征、CUDA共享缓冲和OIDN（2026-10-21）

已验收真实DXR history→D3D compute打包→CUDA外部消费者→D3D读回。`flags&2`开启全部主样本的albedo/normal/coverage/view-depth矩，按相同样本权重跨批累积；position/ID保留首样本语义。OIDN 2.5.0为可替换成熟模块，线性HDR输入，不覆盖物理history。

|文件|职责|
|---|---|
|`path_integrator.hlsl`、`path_accumulate.hlsl`|主样本特征与批次加权历史|
|`path_pack.hlsl`|128B history转六个float4平面，96B/像素共享packet|
|`path_interop.h/.cpp`|LUID匹配、共享内存/Fence、D3D→CUDA→D3D队列时间线、末尾读回|
|`path_cuda.h/.cu`|sm_120透传参考与字段/边界/stamp审计|
|`path_oidn.cpp`|PathConsumer接口实现，指定CUDA stream，OIDN RT异步过滤|
|`path_guide_validation.h`、`path_interop_test.cpp`|独立CPU主射线、分批、重置/resize、原始history不变与质量输入|
|`setup_oidn.ps1`|固定官方2.5.0归档与SHA256，保存build/deps，不安装系统环境|
|`verify_interop.ps1`、`analyze_interop.py`|构建/验收/sanitizer/回归、PFM误差与PNG图|

从仓库根目录：

```powershell
.\learning\sandbox\path_tracing\dxr-path-tracer\verify_interop.ps1
```

要求既有PT.8 gallery/能量表、CMake、VS2022、DXC、CUDA13.3。CMake可选`PT10_INTEROP=ON`启用CUDA_ARCHITECTURES120、共享CUDA runtime与OIDN链接；不需要该课时可设OFF。脚本临时把OIDN bin加到当前进程PATH并在finally恢复。`-SkipSanitizer`只跳过该工具，默认执行memcheck含leak-check full。混合工程沿用glTF-scene的CMake/VS初始化；日常独立.cu仍用sandbox/build.ps1。

结果直接写`results/pt10-interop/`：interop.csv为交接值、GPU计数和CUDA event观察；PFM为线性颜色/有符号normal；summary.json为全图及固定亮区MSE；run/memcheck/history-regression日志、两张对比PNG。quick sanitizer保存在子目录sanitizer，不覆盖full参考。直接执行exe需先将`build/deps/oidn-2.5.0.x64.windows/bin`加至进程PATH；参数依次为scene、shader-directory、energy.bin、output-directory、full或quick。

实测CPU 64×13主射线guide差1.346e-7，2+5+6对13spp差3.06463e-7；开关guide不改变radiance。共享透传/相机重置/95×49/重复OIDN全部通过。full Fence19/19、Debug0；memcheck 0错误/0泄漏，quick Fence10/10；history回归Fence33/33；PT.8 K0回归也通过。

192×96/32spp相对独立1024spp参考，全图线性MSE：原始.00919809、OIDN仅颜色.01345646、OIDN带guides .01861140。参考maxRGB>2的2.501%像素贡献guides版本91.775%平方误差；其余区域MSE .00647021→.00157003。保留真实结果，不把平滑等同准确。CUDA event本次guides重复.486208ms，包含审计、验证环境且未充分统计，不是正式性能报告。

该小节验收到无窗口消费者；降噪显示与完整评测由下节完成。没有时域降噪、运动向量、生产多帧调度或设备恢复。讲义：[降噪特征与CUDA外部消费者](../../../笔记/path_tracing/PT.10-降噪特征与CUDA外部消费者.md)。

## PT.10 降噪窗口与整章评测（2026-10-21完成）

|文件|职责|
|---|---|
|`path_final.cpp`|verify/benchmark/interactive三个入口，共享同一场景、积分器、history和外部消费者|
|`path_metrics.h`|6槽D3D timestamp、Fence后读回与同LUID进程DXGI内存查询|
|`path_interop.h/.cpp`|回接列表中的显示回调、Present、计时、完成后清旧命令引用以支持ResizeBuffers|
|`verify_final.ps1`|完整构建、窗口/sanitizer、独立性能进程、分析及旧课回归|
|`analyze_final.py`|24组输入×3输出线性误差、54条稳态计时统计、PFM与真实Back Buffer绘图|
|`view_final.ps1`|临时配置OIDN DLL搜索路径后启动交互查看器，退出恢复PATH|

仓库根目录运行：

```powershell
.\learning\sandbox\path_tracing\dxr-path-tracer\verify_final.ps1
.\learning\sandbox\path_tracing\dxr-path-tracer\view_final.ps1
```

第一条自动退出；第二条由用户主动启动持续窗口，N切原始/仅颜色/guides，+/-曝光，WASD相机平移，R重置，Esc退出。仍是同步参考入口，不是完整鼠标自由相机。源码参数依次为scene、shader目录、energy.bin、output目录、verify/benchmark/interactive；直接exe运行前需将本课OIDN bin加入进程PATH。

结果全部直接写`results/pt10-final/`。window保存10阶段实际Back Buffer/metadata；sanitizer保存完整窗口链的memcheck结果；benchmark保存timings/quality/memory CSV和PFM；summary.json与三张PNG是分析产物；硬件/Toolkit输出独立保存；display/interop/history/r13-regression为兼容验收。`verify_display_compat.ps1 -OutputDirectory <目录>`用于本节归档，未指定仍保持旧默认路径。

窗口10/10逐码通过、RGB差≤1、alpha255、Fence13/13、Debug0；CUDA memcheck 0错误/0泄漏。原始history在降噪/曝光/窗口变化时逐位不变；相机/内部尺寸/手动重置依次4spp/gen2/3/4。PT.10旧16帧显示、interop/history、R.13 window96/resize64均回归通过。

性能模式独立进程关闭Debug/GBV，保留相同shader与同步读回；每模式3次预热+9次测量，32spp固定seed重置。384×192 guides：DXR+累积中位4.780352ms、CUDA消费者+audit .777504ms、包含交接和HDR读回的D3D区间6.30336ms；7,025,410条TraceRay。CUDA区间嵌套在D3D交接区间，不能重复相加。进程本地显存采样约310.645MiB；显式batch/history/packet逻辑总23.625MiB是另一口径。当前驱动610.88、CUDA13.3.33、RTX5070/sm_120。

质量：两分辨率×三种子×4/16/64/256spp，对各自独立1024spp参考。384×192原始平均MSE .07016961→.00137442，guides .02582719→.00266407；低SPP改善、高SPP可能损失精度。保留全部数据，不预设降噪始终更好。完整边界、API参数、时间线与章节逐项验收见[降噪窗口与质量性能验收](../../../笔记/path_tracing/PT.10-降噪窗口与质量性能验收.md)。
