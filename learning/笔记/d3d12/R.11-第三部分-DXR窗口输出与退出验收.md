# R.11 第三部分：DXR 窗口输出与退出验收

## 验收结果（2026-10-08）

独立文件 `learning/sandbox/d3d12/r11-03-window/dxr_window_pipeline.cu` / `dxr_window.hlsl`，保留前两部分源码。RTX 5070 / DXR Tier 1.1，修正退出同步后真实运行180帧：每帧 DispatchRays 840×480、Present 返回 S_OK，最终 fence=182、completed=182；颜色读回通过，渲染后和资源释放后的 InfoQueue 均0 error /0 warning，进程退出码0。stderr为空，无工具超时。此前截图确实显示红绿三角形，但截图不是完整验收依据。

## 2173 诊断过程与结论

1. 原版和仅加无缓冲stdout的版本都能完成3帧、读回与零Debug统计，却返回2173。不是窗口提前关闭，也不是工具超时。
2. Python subprocess捕获子进程同样返回2173，排除只是PowerShell传播错误码的问题。
3. 显式分阶段Reset定位：释放back0/back1、swap3后，在释放最后一个swap1接口时退出。调整交换链/窗口释放次序本身不能修复。
4. 保持相同释放顺序，只增加最后一次Present之后queue Signal及fence等待，3帧退出变为0；最终版本180帧也退出0。

因此确定程序有退出时同步缺口，已通过补齐Present之后队列排空修复。原有submit_wait只保证Present之前的渲染/复制工作完成，不能当成最后一次Present之后队列也已排空。2173本身的驱动/DXGI内部含义没有异常栈或转储支撑，不把它解释为某个特定Windows标准错误。这里定位的是可复现失败位置和有效修复，不冒称掌握驱动内部原因。

stdout改为无缓冲，避免异常退出时日志丢失；真正的PASS移到显式释放结束之后，不能刚读回成功就宣称进程成功。交换链、GPU资源和设备依次释放，Debug统计覆盖释放阶段（最后设备析构后的消息不在该InfoQueue采样范围）。

## 绑定与呈现链路

- HLSL `RaytracingAccelerationStructure scene:t0`仍通过global root SRV传入TLAS GPU虚拟地址，不要求给它在堆中创建SRV。
- `RWTexture2D<float4> output:u0`不能沿用buffer root UAV地址绑定；创建shader-visible CBV/SRV/UAV heap，写入TEXTURE2D UAV描述符，再SetDescriptorHeaps和SetComputeRootDescriptorTable绑定。资源Format=R8G8B8A8_UNORM，shader写float4，存储为每通道8-bit归一化值。
- Local b0仍是SBT两项DWORD，HitGroupA/B分别输出红/绿色，local数据影响通道亮度；Miss为深蓝背景。payload从uint改为float4，因此State Object MaxPayloadSizeInBytes=16。
- Win32客户区840×480，flip-discard交换链两个Back Buffer并创建两个RTV。此例不Draw、不绑定RTV，CopyResource不会消费RTV描述符。

重要：不是把同一纹理从UAV直接转PRESENT。离屏输出为COMMON→UAV→COPY_SOURCE，后续帧COPY_SOURCE→UAV；Back Buffer为PRESENT→COPY_DEST→PRESENT。尺寸/格式/采样数相同后CopyResource，Present呈现交换链图像。RTV存在不等于必须走光栅化。

每帧等待GPU才复用同一个allocator，是教学串行方案。商业引擎通常多帧资源并行、独立帧fence，HDR/tonemap后输出交换链；本例直接UNORM复制不是生产色彩管理方案。固定窗口尺寸、不支持ResizeBuffers，单geometry/单射线用途，无AnyHit、阴影或路径积分。最终Present之后的fence保证队列侧工作排空，不等于可观测显示器扫描完成。

## 读回与日志

GetCopyableFootprints取得RowPitch=3584，不能假定840×4=3360；CopyTextureRegion到Readback buffer后，CPU等待fence再Map。三个内部采样位置验证红、绿、背景，而非逐像素证明整幅图。PPM是GPU读回图像，不称为窗口截图。

真实日志关键行：
```text
Window created: 840x480; swapchain buffers=2; RTVs=2
Frame 1: DispatchRays 840x480, Present S_OK, fence=2
Frame 60: DispatchRays 840x480, Present S_OK, fence=61
Frame 120: DispatchRays 840x480, Present S_OK, fence=121
Frame 180: DispatchRays 840x480, Present S_OK, fence=181
Readback A=(195,22,13,255) B=(13,174,41,255) Miss=(10,15,31,255) RowPitch=3584
InfoQueue: errors=0 warnings=0
Final Present drained: fence=182 completed=182
InfoQueue: errors=0 warnings=0
DXR window: PASS; frames=180; shutdown complete; exit=0
NativeExit=0
```

本轮重编译C++并运行已存在的DXIL，未改HLSL也未重新宣称编译shader：
```powershell
& .\learning\sandbox\build.ps1 learning\sandbox\d3d12\r11-03-window\dxr_window_pipeline.cu -NoRun
& .\learning\sandbox\d3d12\r11-03-window\dxr_window_pipeline.exe .\learning\sandbox\d3d12\r11-03-window\dxr_window.dxil 180
$code=$LASTEXITCODE
Write-Output "NativeExit=$code"
exit $code
```

需要重建shader时可使用前次已用的Windows SDK DXC路径（本轮不把它标为重新执行）：
```powershell
& 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\dxc.exe' -T lib_6_3 -Fo learning/sandbox/d3d12/r11-03-window/dxr_window.dxil learning/sandbox/d3d12/r11-03-window/dxr_window.hlsl
```

## 边界和后续

没有验证GPU-based validation、resize、最小化/遮挡、用户提前关闭、设备移除恢复、多帧并行、多geometry/multi-ray-type；不能以本次零Debug消息覆盖这些场景。保留R.11 [~]，注明原计划窗口链路已验收，其余为扩展或待学习边界。前两部分未修改，前两部分本轮未重新运行。
