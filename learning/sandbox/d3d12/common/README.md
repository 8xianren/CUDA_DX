# D3D12共享显示组件

从R.13窗口主线提取，供R.13和PT.10共同使用，不另建设备/队列或复制积分器。

|文件|职责|
|---|---|
|window_display.h|Win32窗口、双缓冲交换链、RTV/光栅PSO、尺寸/最小化、显式状态与实际Back Buffer读回|
|hdr_display.hlsl|全屏三角形、源/目标像素中心映射、任意明确字节步长的HDR读取、曝光/Reinhard/sRGB与负对照|

输入RGB位于每个历史像素记录开头12B，步长通过48B根常量指定：R.13为16B，PT.10为128B。窗口对象借用device/queue；调用者必须在Resize/析构前完成Fence并清理旧录制引用。默认正常显示一次手动sRGB编码到UNORM，mode1/2/3是截断/漏编码/重复编码诊断。

PT.10降噪回接新增record可选sourceState和byteOffset：从COMMON共享buffer的output平面读取16B步长float4，结束恢复COMMON；默认UAV/offset0保持旧调用。直接借用GPU地址，无CPU图像上传。最终全链路入口为`path_tracing/dxr-path-tracer/verify_final.ps1`，归档于`results/pt10-final/`，见[最终验收讲义](../../../笔记/path_tracing/PT.10-降噪窗口与质量性能验收.md)。

从仓库根目录构建并验证所有受影响调用者：

```powershell
.\learning\sandbox\path_tracing\dxr-path-tracer\verify_display.ps1
```

脚本自身定位。结果直接写`path_tracing/dxr-path-tracer/results/pt10-display/`；R.13兼容结果在其r13-regression子目录。C++通过共享CMake构建，显示shader通过DXC vs_6_0/ps_6_0构建；旧R.13宿主用build.ps1/sm_120重编译。完整命令、可运行交互入口和验收见[PT.10共享主线](../../path_tracing/dxr-path-tracer/README.md)。

讲义：[PT.10曝光色调映射与窗口显示](../../../笔记/path_tracing/PT.10-曝光色调映射与窗口显示.md)。R.13原头文件/shader保留include兼容入口，原命令仍可使用；必须同步重编译宿主与显示shader以使用新步长字段。
