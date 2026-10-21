# R.13 共享渲染主线（R.13.3–8已验收，固定内部网格/可变窗口输出）

各小节逐步扩展同一程序，因此保留一份源码，避免复制不同版本后无法判断应修改哪份。目录使用稳定名称`r13-renderer`，不随小节增长而反复改名。

|文件|职责/所属小节|
|---|---|
|dxr_view_pipeline.cu|D3D12宿主、AS、资源、管线/SBT、双槽Fence、读回与验证分派|
|dxr_view.hlsl|R.13.3矩阵相机主射线；R.13.4命中属性；光照入口|
|dxr_view_reference.h|R.13.1–3相机数学和CPU参考|
|dxr_surface_reference.h|R.13.4独立几何验证及诊断图|
|dxr_surface_preview.py|R.13.4诊断图排版|
|dxr_direct_light.hlsli|R.13.5 Lambert、矩形灯NEE、阴影Miss|
|dxr_lighting_reference.h|R.13.5 CPU面积积分参考、数值验收、PFM输出|
|dxr_lighting_preview.py|R.13.5线性PFM显示预览|
|results/r13-04/|属性与法线诊断结果|
|results/r13-05/|直接光PFM、预览PNG、验证日志|
|dxr_progressive_sampling.hlsli|R.13.6四维采样与参数|
|dxr_progressive_accumulation.hlsli|R.13.6 GPU线性在线平均|
|dxr_progressive_runner.h|R.13.6帧提交、共享历史、实验序列|
|dxr_progressive_reference.h|R.13.6 CPU参考与收敛统计|
|dxr_progressive_preview.py|R.13.6离线预览|
|results/r13-06/|各seed的1/16/256 spp、2048 spp参考、CSV、日志和PNG|
|dxr_gpu_sequence.h|R.13.6/7共用的两槽、GPU历史、提交和读回|
|dxr_history_policy.h|R.13.7目标Key、自动reset、epoch与计数|
|dxr_history_reference.h|R.13.7独立计数/均值/几何/灯光验证|
|dxr_history_runner.h|R.13.7状态变化、错误历史混合实验|
|dxr_history_preview.py|R.13.7残影及曝光/色调映射对照|
|results/r13-07/|18段状态PFM、错误/正确图像、逐帧CSV与日志|
|dxr_display_reference.h|R.13.8a曝光、Reinhard、sRGB与量化的CPU数学参考|
|dxr_display_probe.cu|R.13.8a数值扫描、PFM读取与BMP对照；没有GPU dispatch|
|dxr_display_preview.ps1|仅加标题、BMP转PNG，无光照计算|
|results/r13-08a/|显示数值CSV、验收日志、编码/曝光对照图|
|dxr_display.hlsl|兼容入口，实际VS/PS在../common/hdr_display.hlsl，与PT.10共享|
|dxr_window_display.h|兼容入口，实际窗口/交换链/PSO/读回在../common/window_display.h|
|dxr_window_runner.h|复用DXR提交层，96帧窗口/曝光/历史验收|
|dxr_window_preview.ps1|实际Back Buffer的PPM转PNG和标题，无颜色计算|
|results/r13-08b/|窗口验收日志、32/64/96帧PPM和PNG|
|dxr_resize_runner.h|R.13.8c真实尺寸/最小化恢复/历史对照，复用窗口实现|
|results/r13-08c/|8阶段PPM、尺寸CSV、resize日志与全章回归日志|

从仓库根目录运行，每步成功后再执行下一步：

```powershell
$lesson='learning/sandbox/d3d12/r13-renderer'
$dxc='C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\dxc.exe'
& $dxc -T lib_6_3 -Fo "$lesson/dxr_view.dxil" "$lesson/dxr_view.hlsl"
& $dxc -T lib_6_3 -D ENABLE_DIRECT_LIGHT=1 -Fo "$lesson/dxr_lighting.dxil" "$lesson/dxr_view.hlsl"
& learning/sandbox/build.ps1 "$lesson/dxr_view_pipeline.cu" -NoRun
& "$lesson/dxr_view_pipeline.exe" "$lesson/dxr_view.dxil"
& "$lesson/dxr_view_pipeline.exe" "$lesson/dxr_lighting.dxil" lighting
python "$lesson/dxr_surface_preview.py"
python "$lesson/dxr_lighting_preview.py"
```

输出以DXIL所在目录为基准，自动建立相应results子目录。预览脚本也从自身所在目录定位结果，不需要手动移动图像。默认诊断版与lighting版必须使用对应DXIL。

## R.13.6 采样与累积

继续从仓库根目录运行（变量沿用上面的定义）：

```powershell
& $dxc -T lib_6_3 -D ENABLE_DIRECT_LIGHT=1 -D ENABLE_PROGRESSIVE=1 -Fo "$lesson/dxr_progressive.dxil" "$lesson/dxr_view.hlsl"
& learning/sandbox/build.ps1 "$lesson/dxr_view_pipeline.cu" -NoRun
& "$lesson/dxr_view_pipeline.exe" "$lesson/dxr_progressive.dxil" progressive
python "$lesson/dxr_progressive_preview.py"
```

progressive模式固定160×96输出/160×90视图，每帧在每个有效像素内采样一个位置，生成一条主射线；命中后采样一个灯面位置，得到本次像素颜色估计。“相机样本”指主射线生成输入的采样，不是对相机对象取样，也不是已经算出的颜色；详见[R.13.6第2节术语说明](../../../笔记/d3d12/R.13.6-像素采样与线性HDR累积.md)。2048 spp独立参考、8种子1/16/256 spp、固定中心/冻结随机/HDR零值/重复种子对照。GPU历史在线性空间平均，CPU逐帧验证同样本平均，所有测试结果直接写入`results/r13-06/`。2026-10-14实测PASS，Fence4641/4641、Debug0/0。

## R.13.7 历史有效性与reset

从仓库根目录运行，变量沿用上文：

```powershell
& $dxc -T lib_6_3 -D ENABLE_DIRECT_LIGHT=1 -D ENABLE_PROGRESSIVE=1 -D ENABLE_HISTORY=1 -Fo "$lesson/dxr_history.dxil" "$lesson/dxr_view.hlsl"
& learning/sandbox/build.ps1 "$lesson/dxr_view_pipeline.cu" -NoRun
& "$lesson/dxr_view_pipeline.exe" "$lesson/dxr_history.dxil" history
python "$lesson/dxr_history_preview.py"
```

18段状态自动判定，256次Dispatch；另有旧相机64+新相机32的错误混合及干净32样本对照。RNG序号与历史计数分离；曝光与显示曲线只影响离线预览，不触发目标reset。2026-10-14验收PASS：14次reset（含初始化），策略errors=0，Fence385/385、Debug0/0；旧三种模式回归通过。场景变化使用实例mask，未实现动态AS修改；真实窗口与资源resize待R.13.8。

## R.13.8a SDR显示契约（CPU参考）

从仓库根目录运行，默认读取R.13.7的`correct-reset.pfm`（缺失时先运行上面的history模式）：

```powershell
$lesson='learning/sandbox/d3d12/r13-renderer'
& learning/sandbox/build.ps1 "$lesson/dxr_display_probe.cu" -NoRun
& "$lesson/dxr_display_probe.exe"
& "$lesson/dxr_display_preview.ps1"
```

2026-10-15 CPU实测PASS：100001点与阈值锚点、21组显示数值；线性0.5漏/正确/重复编码分别128/188/223。读取真实DXR HDR但没有新增GPU提交；.8b窗口显示、.8c resize与整体验收仍待完成。输出基于exe目录，PNG脚本基于自身目录。显示函数拒绝非有限/负辐射值，曝光补偿限制[-16,16]。

## R.13.8b GPU显示与窗口

从仓库根目录运行，先按R.13.7命令编译`dxr_history.dxil`，再编译显示shader和宿主：

```powershell
$lesson='learning/sandbox/d3d12/r13-renderer'
$dxc='C:/Program Files (x86)/Windows Kits/10/bin/10.0.26100.0/x64/dxc.exe'
& $dxc -T vs_6_0 -E VSMain -Fo "$lesson/dxr_display_vs.dxil" "$lesson/dxr_display.hlsl"
& $dxc -T ps_6_0 -E PSMain -Fo "$lesson/dxr_display_ps.dxil" "$lesson/dxr_display.hlsl"
& learning/sandbox/build.ps1 "$lesson/dxr_view_pipeline.cu" -NoRun
New-Item -ItemType Directory -Force "$lesson/results/r13-08b" | Out-Null
& "$lesson/dxr_view_pipeline.exe" "$lesson/dxr_history.dxil" window 2>&1 | Tee-Object "$lesson/results/r13-08b/validation.txt"
& "$lesson/dxr_window_preview.ps1"
```

window模式固定480x270，直接展示160x90有效历史的3倍最近邻图；96帧自动结束（EV0/+1/-1各32帧），逐帧等待并读回用于教学验收，不是高吞吐持续编辑器。关闭窗口会安全结束并报告验收未完成。VS/PS从传入DXIL同目录读取；结果位于其results/r13-08b，无CPU上传成像。2026-10-15 RTX5070实测96 Present、Back Buffer各48次、逐RGB误差<=1码、alpha全255、Fence97/97、Debug0/0。resize/最小化留待.8c。

## R.13.8c resize与最小化

先执行上文VS/PS与宿主构建命令：显示常量现为48B/12DWORD，旧16B协议的DXIL不可混用。默认`window`模式仍通过原96帧验收。

```powershell
New-Item -ItemType Directory -Force "$lesson/results/r13-08c" | Out-Null
& "$lesson/dxr_view_pipeline.exe" "$lesson/dxr_history.dxil" resize 2>&1 | Tee-Object "$lesson/results/r13-08c/validation.txt"
& "$lesson/dxr_window_preview.ps1" -Resize
```

工作目录仍为仓库根目录，变量沿用上文。resize模式自动8阶段64帧结束，测试奇数/竖屏/宽屏/120x1、最小化与恢复；内部HDR固定160x96，显示等比例内接并留黑边；另以改变源ViewRect验证历史重置。只改窗口不重置HDR。2026-10-15 RTX5070：5次尺寸资源重建、3次历史reset（含初始化）、最小化跳过3tick；Fence65/65、Debug0/0、RGB误差<=1码，PASS。R.13各阶段回归通过。没有任意内部渲染尺寸的动态分配、设备恢复或持续交互编辑器。

## 对应讲义

- [R.13.3 矩阵相机与帧资源](../../../笔记/d3d12/R.13.3-矩阵相机接入DXR与帧资源.md)
- [R.13.4 命中属性与法线](../../../笔记/d3d12/R.13.4-从命中约束推导位置与法线.md)
- [R.13.5 Lambert与NEE](../../../笔记/d3d12/R.13.5-Lambert矩形灯NEE与线性光照图.md)
- [R.13.6 像素采样与累积](../../../笔记/d3d12/R.13.6-像素采样与线性HDR累积.md)
- [R.13.7 历史有效性与重置](../../../笔记/d3d12/R.13.7-历史有效性与重置.md)
- [R.13.8a SDR显示变换与sRGB编码契约](../../../笔记/d3d12/R.13.8a-SDR显示变换与sRGB编码契约.md)
- [R.13.8b GPU显示通道与窗口Present](../../../笔记/d3d12/R.13.8b-GPU显示通道与窗口Present.md)
- [R.13.8c 窗口Resize与历史生命周期](../../../笔记/d3d12/R.13.8c-窗口Resize与历史生命周期.md)


2026-10-21 PT.10共享显示更新：t0改为ByteAddressBuffer，48B常量原保留字段明确为pixelByteStride和mode；R.13默认16B/正常显示保持原行为。宿主和shader需同步重编译。共享代码及PT.10回归命令见[common](../common/README.md)。window96帧与resize64帧回归均通过，RGB≤1码、Debug0/0；新结果直接归PT.10的results/pt10-display/r13-regression，未覆盖本目录历史结果。
