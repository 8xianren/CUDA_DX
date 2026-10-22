# F.1–F.10：抗锯齿、时域重建与官方超分实验室

本目录是一份共享的 **D3D12 光栅与重建教学工程**。用同一场景、相机轨迹和曝光比较 No AA、4× MSAA、FXAA、TAA、空间缩放、官方 NIS、官方 FSR 和官方 XeSS，再单独验证官方帧生成。设备、命令列表、Fence 和基本资源操作复用 C/D 的 `gltf-scene/src/gpu_upload.*`；不复制整套渲染后端。

本课建立的是 F 阶段验收实验室，**没有自动把这些功能合并到 H 人物路径追踪 Demo**。H 的人物动画、CUDA 蒙皮、DXR 路径积分和降噪仍在其原模块中。将 F 的成熟重建接口接入 H 时，还需要对接人物运动、几何 guides、透明材质、曝光和渲染分辨率，不能把这里的数字直接写成 H 的 FPS。

架构与所有权见 [ARCHITECTURE.md](ARCHITECTURE.md)。学习总入口见 [learning/README](../../../README.md)，本线路入口见 [D3D12 / DXR](../README.md)。

2026-10-22 在 RTX 5070 上，FSR 与 XeSS 的 Native / Quality / Balanced / Performance 已各完成 120 帧官方 GPU 重建，八组均无 fallback、Debug/GPU Validation 告警错误为 0。实际 FSR provider 为 **3.1.5**，XeSS-SR runtime 为 **2.0.2.0**；这与下载包的版本号分开记录。质量比较、独立 GPU 成本及测量限制见 [F.10](../../../笔记/d3d12/F.10-固定序列质量与性能评测.md)。

## 课程、源码与讲义

|课程|实现 / 验收位置|讲义|
|---|---|---|
|F.1 MSAA 与 Alpha-to-Coverage|`src/scene.cpp`、`src/main.cpp::F1`、`results/f1`|[F.1](../../../笔记/d3d12/F.1-MSAA与AlphaToCoverage.md)|
|F.2 离屏 HDR 与后处理链|`src/gpu_resources.*`、`src/post_chain.*`、`shaders/display.hlsl`、`results/f2`|[F.2](../../../笔记/d3d12/F.2-离屏HDR与后处理资源流.md)|
|F.3 FXAA|`shaders/post.hlsl::FxaaCS`、独立 CPU/GPU oracle、F.10 序列|[F.3](../../../笔记/d3d12/F.3-FXAA边缘方向搜索.md)|
|F.4 时域输入|`src/temporal_contract.h`、`shaders/scene.hlsl`、`results/f4`|[F.4](../../../笔记/d3d12/F.4-时域重建输入契约.md)|
|F.5 TAA 重投影与拒绝|`TaaCS`、`audit_temporal.py`、`results/f5` 和 F.10 消融序列|[F.5](../../../笔记/d3d12/F.5-历史重投影与拒绝.md)|
|F.6 DRS 与空间超分|Bilinear/Bicubic、官方 NIS、`results/f6`|[F.6](../../../笔记/d3d12/F.6-动态分辨率与空间超分.md)|
|F.7 FSR|`src/sdk_upscalers.*`、FSR 4 档、reset/resize/DRS/fallback|[F.7](../../../笔记/d3d12/F.7-FidelityFX官方超分接入.md)|
|F.8 XeSS / DLSS / Streamline|XeSS 4 档实际后端；DLSS / SL 仅官方接口对照|[F.8](../../../笔记/d3d12/F.8-DLSS_Streamline_XeSS输入契约.md)|
|F.9 帧生成与显示节奏|独立 `framegen_demo`、官方 FSR FG、ETW / DXGI 取证、`results/f9`|[F.9](../../../笔记/d3d12/F.9-官方帧生成与显示节奏.md)|
|F.10 图像与性能评测|`analyze_sequences.py`、19 种模式 × 120 帧、独立 benchmark|[F.10](../../../笔记/d3d12/F.10-固定序列质量与性能评测.md)|

Native、Quality、Balanced、Performance 均通过真实 SDK 查询内部尺寸，再调用官方 GPU 实现。XeSS 的同名档位不保证与 FSR 像素数相同。DLSS / Streamline 没有伪装成可运行菜单，也没有自写闭源神经重建替代物。

## 新电脑构建与完整验收

以下命令均在**仓库根目录**运行。脚本按自身目录定位输入；`f_lessons.exe` 按可执行文件位置定位本课，因此不依赖启动 shell 恰好在源码目录。

需要 Windows、VS 2022 C++ 工具链、Windows SDK、CMake ≥3.24、PATH 可找到的 `dxc` 和 Python 3。复用的 `UploadContext` 当前要求 D3D12 FL12.1 / DXR 设备，并默认启用 D3D Debug Layer + GPU Validation；本机为 RTX 5070。本目录没有 CUDA kernel，因此无需给此 C++ 工程追加 `-arch`；涉及 CUDA 的其他课程仍必须按仓库规则使用 `sm_120`。

图像分析脚本需要 NumPy、Pillow；后者只编码预览图，不参与数值误差计算：

```powershell
python -m pip install numpy Pillow

# 第一次构建自动下载固定版本 NIS / FidelityFX / XeSS 并核 SHA256。
& learning/sandbox/d3d12/aa-reconstruction/build.ps1

# 已完成构建后，进行完整 F 验收；含 19×120 帧质量序列和独立性能序列。
& learning/sandbox/d3d12/aa-reconstruction/verify.ps1 -SkipBuild
```

完整验收会运行短窗口、离屏序列和 F.9 帧生成窗口，需要数分钟并生成约 9 GB 量级的本地浮点序列。让窗口正常完成；`suite` 的窗口只用于自动验收，结束后会退出。它目前不是带菜单、鼠标相机或模式切换按钮的交互 viewer；`sequence` 与 `bench` 是离屏程序。

只想恢复第三方包、暂不编译时：

```powershell
python learning/sandbox/d3d12/aa-reconstruction/fetch_nis.py
& learning/sandbox/d3d12/aa-reconstruction/fetch_sdks.ps1
```

依赖恢复后重复构建可用 `build.ps1 -SkipFetch`。完整 `verify.ps1` 默认同时构建并验收 F.9；`-SkipFrameGeneration` 或 `-SkipBenchmark` 适合定向迭代，但带这些选项的运行不能当作完整 F.1–F.10 验收。

## 日常运行与单项复现

```powershell
# F.1/F.2/F.4/F.6 的窗口、资源、输入与缩放自动验收。
& learning/sandbox/d3d12/aa-reconstruction/build/Release/f_lessons.exe suite

# 单一算法 120 帧质量序列；第 60 帧有 Camera Cut。
& learning/sandbox/d3d12/aa-reconstruction/build/Release/f_lessons.exe sequence fsr-quality 120
& learning/sandbox/d3d12/aa-reconstruction/build/Release/f_lessons.exe sequence xess-balanced 120

# 专门检验缺 SDK 回退、内部尺寸变化和新输出尺寸。
& learning/sandbox/d3d12/aa-reconstruction/build/Release/f_lessons.exe sequence fsr-unavailable 8
& learning/sandbox/d3d12/aa-reconstruction/build/Release/f_lessons.exe sequence fsr-dynamic 16
& learning/sandbox/d3d12/aa-reconstruction/build/Release/f_lessons.exe sdk-resize

# 性能模式关闭调试验证与大图读回；结果必须与质量序列分开解释。
& learning/sandbox/d3d12/aa-reconstruction/build/Release/f_lessons.exe bench fsr-quality 40

# 独立 CPU 数学约定，以及 shader 对 CPU oracle 的对照。
python learning/sandbox/d3d12/aa-reconstruction/verify_sdk_contracts.py
& learning/sandbox/d3d12/aa-reconstruction/build/Release/f_sdk_probe.exe learning/sandbox/d3d12/aa-reconstruction/build/deps learning/sandbox/d3d12/aa-reconstruction/results/f7/sdk-probe.json
python learning/sandbox/d3d12/aa-reconstruction/audit_temporal.py --emit-fixtures
& learning/sandbox/d3d12/aa-reconstruction/build/Release/f_lessons.exe oracle
python learning/sandbox/d3d12/aa-reconstruction/audit_temporal.py --gpu-oracle-root learning/sandbox/d3d12/aa-reconstruction/results/f5/oracle-input

# 单独构建并运行官方帧生成验收。
& learning/sandbox/d3d12/aa-reconstruction/build_framegen.ps1 -Run

# 19 组质量序列齐全后，重算图像评测与可分享报告。
python learning/sandbox/d3d12/aa-reconstruction/analyze_sequences.py
```

`sequence/bench` 支持的常规方法：`reference`、`noaa`、`msaa4`、`fxaa`、`taa`、`taa-no-reprojection`、`taa-no-rejection`、`taa-no-clamp`、`bilinear`、`bicubic`、`nis`、`fsr-native`、`fsr-quality`、`fsr-balanced`、`fsr-performance`、`xess-native`、`xess-quality`、`xess-balanced`、`xess-performance`。三个 `taa-no-*` 是有意关闭机制的负对照，不是建议的画质预设。

## 文件职责与生成结果

|位置|职责|
|---|---|
|`src/main.cpp`|组织 F.1/F.2/F.4/F.6 验收、统一序列、计时与读回；不实现厂商算法|
|`src/gpu_resources.*`|Texture 状态、描述符、Window/SwapChain、GPU timestamp、带行 pitch 的读回|
|`src/scene.*` / `shaders/scene.hlsl`|可控几何、alpha-test / 粒子压力场景、真实深度与 motion guides|
|`src/temporal_contract.h`|jitter、UV 换算、history 失效原因|
|`src/post_chain.*` / `shaders/post.hlsl`|FXAA、TAA、空间重建与状态绑定；NIS 只包装官方实现|
|`src/sdk_upscalers.*`|官方 FSR / XeSS 的模块边界、上下文、资源输入、错误状态|
|`src/sdk_probe.cpp`|初始化、质量查询、resize 生命周期和缺 DLL 注入；不声称图像质量|
|`src/framegen_demo.cpp` / `framegen/`|独立真实窗口与官方帧生成 swapchain，避免改变主质量基线|
|`shaders/display.hlsl`|重建之后 tone mapping / sRGB 与输出分辨率 UI|
|`shaders/reference.hlsl`|4× 横纵高分辨率光栅的 4×4 box 汇聚，用作有限参考|
|`audit_temporal.py`|独立 CPU oracle、固定输入、负对照与 GPU 数值差异|
|`analyze_sequences.py`|同一真实帧的误差、时域误差变化、ROI、截图和报告|
|`verify_framegen.py`|运行 FG on/off、检查 UI/插值位置、记录 ETW 与 DXGI 测量范围|

结果直接写入本课 `results/`：

- `f1/f2/f4/f6`：窗口 / 资源 / motion / 动态尺寸实验；`f5`：CPU/GPU oracle。
- `f7`：SDK probe、数学契约、DLL 身份和输出 resize；FSR/XeSS 的统一图像序列位于 F.10 目录。
- `f9/on`、`f9/off`：真实帧与生成帧日志、实际输出图像、PresentMon 和 DXGI 统计；`f9/summary.json` 给出计量边界。
- `f10/sequences/<method>`：每帧线性 HDR `.f32`、关键帧预览、`frames.csv` 和运行摘要。
- `f10/benchmark/<method>`：关闭调试和读回的 GPU timestamp 成本。没有 Present，不能换算成整个游戏的端到端显示 FPS。
- `f10/quality`：`coverage.json`、质量 `summary.json` / `metrics.csv`、可视化和可分享报告。缺帧时默认失败，不补造结果。
- `verification`：整套命令的日志。

## 第三方组件与提交边界

|组件|固定来源|许可 / 用途|
|---|---|---|
|NVIDIA Image Scaling|[nis.lock.json](nis.lock.json) 的官方 commit 与逐文件 hash|MIT；空间缩放参考实现|
|FidelityFX/FSR SDK|[sdk_manifest.json](sdk_manifest.json)，v2.3.0|官方总许可和逐文件例外；实际 SR provider 由运行时查询|
|Intel XeSS SDK|同清单，v3.0.2|Intel SDK 许可；实际 `libxess.dll` 执行|
|PresentMon|[framegen/presentmon-manifest.json](framegen/presentmon-manifest.json)|官方工具及固定 hash，F.9 用来获取独立呈现证据|

下载物放 `build/deps` 或 `external`；编译物在 `build`。DLL、EXE、对象文件、第三方依赖树和大量 `.f32/.rgba/PPM/PNG` 运行原图不提交。小型 JSON/CSV/日志和教学源码可提交；另一台电脑通过上述命令重建图像与报告。发布时继续使用个人 `cuda-dx` remote，不向 NVIDIA 教程的 `origin` 推送学习文件。

固定场景中的有限高分辨率参考不是解析真值；透明粒子 guide 是教学用单层近似。相同质量名称、不同内部像素数不能直接做等工作量结论。F.9 的 ETW 呈现记录不是光学传感器测到的 input-to-photon 延迟；详细限制以各课讲义与结果 JSON 为准。
