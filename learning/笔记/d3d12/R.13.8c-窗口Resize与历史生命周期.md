# R.13.8c：窗口Resize、最小化与历史生命周期

2026-10-15。[代码与命令入口](../../sandbox/d3d12/r13-renderer/README.md)。沿用同一WindowDisplay/GpuRaySequence，新增`dxr_resize_runner.h`实验序列。完成R.13的固定内部渲染分辨率、可变窗口输出路径；没有实现任意内部HDR分辨率的动态分配，也没有升级为多反弹路径追踪器。

## 1. 先分清两个尺寸

内部缓冲固定160x96，通常ViewRect=(0,0,160,90)。输出Back Buffer随客户区变化。仅把已算出的同一幅图按比例显示到另一个窗口，不改变像素积分目标，保留HDR和计数。改变内部ViewRect、相机投影或内部渲染网格，才改变成像目标，需要重置；如果改变内部分配尺寸，还需重建history/output/readback/相机参数和Dispatch尺寸。本节对后一种情形只实测固定容量内的ViewRect改变，不冒称动态HDR内存扩缩容已经完成。

这是渲染分辨率与输出分辨率分离的教学实现，保持画面比例、外围黑边；不是随窗口比例自动扩展相机视野，也不是生产超分算法。

## 2. 为什么WM_SIZE里不直接释放Back Buffer

消息只意味着CPU知道客户区变化，不意味着GPU完成旧尺寸工作。ResizeBuffers要求旧Back Buffer的引用已解除。流程为：

```
WM_SIZE记录pending尺寸/最小化状态
渲染安全点：退役旧帧（先用旧尺寸完成读回）
等待相关Fence完成
Reset旧allocator/list并关闭空list，丢弃旧命令记录
释放旧Back Buffer COM引用与尺寸相关readback
ResizeBuffers
GetBuffer重新取得资源；覆写RTV；重新查询footprint并分配readback
更新viewport/scissor、显示矩形
继续渲染
```

GpuRaySequence::discard_recordings先flush，再Reset两槽allocator/list并Close空list；不销毁HDR、不回退Fence。WindowDisplay::apply_resize的前提是调用方已经执行该安全点。窗口回调只写pendingW/pendingH/minimized，不调用D3D12/DXGI资源释放。持续消息可以覆盖pending而不在回调里反复重建。

“GPU使用结束”与“CPU仍持有旧资源引用”是两件事。Fence满足前者；ComPtr::Reset解除本应用资源引用，丢弃旧命令避免随后执行旧绑定。D3D12 descriptor不是持有资源COM引用的智能指针；本实现保留RTV heap容量，取得新buffer后覆写其描述符，绝不继续使用旧descriptor内容。不要把D3D11 ClearState照搬成D3D12 API。

## 3. 消息入口与尺寸来源

窗口创建时通过lpParam传this；WM_NCCREATE从CREATESTRUCT::lpCreateParams取出并存入GWLP_USERDATA；随后回调可找到WindowDisplay实例。普通课程窗口保持固定样式；resize模式启用WS_OVERLAPPEDWINDOW。

WM_SIZE中wParam为SIZE_MINIMIZED时设置暂停；其它尺寸从GetClientRect查询客户区，不拿外边框尺寸当输出尺寸。WM_SIZE的lParam只携带宽高低16位，GetClientRect避免依赖这种截断表示。本课当前限制最大4096x4096，超过范围报告失败，并非无限尺寸支持。

自动测试用SetWindowPos调整真实客户区（先AdjustWindowRect加上非客户区），ShowWindow(SW_MINIMIZE/SW_RESTORE)产生真实最小化/恢复消息，没有伪造WM_SIZE来声称窗口改变。本机1像素客户区宽度请求实际得到120像素，最终极小测试为真实120x1窗口，内接内容区为1x1。不能把请求尺寸当实际尺寸。

## 4. ResizeBuffers与尺寸资源

```cpp
HRESULT ResizeBuffers(UINT BufferCount, UINT Width, UINT Height,
                      DXGI_FORMAT NewFormat, UINT SwapChainFlags);
```

本课调用(0,pendingW,pendingH,DXGI_FORMAT_UNKNOWN,0)：保留双buffer数量、使用正的客户区尺寸、保留RGBA8_UNORM格式、保持原本为0的flags。flags不是无条件“传0即可”；如果创建时启用了其它必要标志，应按其规则保留。

Width/Height传0在该API中有使用客户区尺寸的含义，不是“创建零尺寸资源”或“最小化专用指令”。本课在minimized/零客户区时根本不调用ResizeBuffers。

成功后重新GetBuffer、CreateRenderTargetView，Back Buffer以PRESENT状态进入后续流程。PSO/Root Signature不因宽高变化而重建，因为本课输出格式和shader协议未变；RTV heap仍2项，可以复用。readback必须根据新footprint重建，不能复用旧RowPitch。ResizeBuffers或资源创建失败由现有check/require报告并终止；没有设备丢失恢复、回滚旧资源或重试保证。

## 5. 等比例内接矩形推导

源ViewRect尺寸Ws,Hs，目标客户区Wd,Hd。统一缩放因子s应满足s*Ws<=Wd、s*Hs<=Hd，并尽可能大，所以s=min(Wd/Ws,Hd/Hs)。实现在整数域判断Wd*Hs<=Hd*Ws决定由宽还是高限制，缩放维度向下取整，极小窗至少1x1。

dw=floor(s*Ws)，dh=floor(s*Hs)，dx=floor((Wd-dw)/2)，dy=floor((Hd-dh)/2)。奇数余量允许两边差1像素；取整也使比例存在最多约1像素的栅格误差。窗口全区域画三角形，PS在矩形外输出RGBA=(0,0,0,1)，不会遗留旧尺寸内容。

目标矩形内第i个像素中心对应源坐标sx=sourceX+floor((i+0.5)*Ws/dw)。GPU写成整数有理式sourceX+((2*i+1)*Ws)/(2*dw)，在本课受限尺寸内不溢出；CPU验证使用double公式独立对照。相同方法处理y，最后index=sy*160+sx。不需要回到相机逆投影，这里只在显示已有图像。

显示常量从.8b初版4DWORD升级为12DWORD/48B：sourceRect uint4、destination uint4、sourceStride uint、exposureEV float、reserved uint2。root signature、SetGraphicsRoot32BitConstants和HLSL同步修改，宿主及VS/PS必须一起重编译；不可沿用旧16B协议的PS DXIL。

## 6. 最小化暂停与恢复

最小化时先收束上一帧，再跳过新的Dispatch/Draw/Present/Signal，不增加随机序号和history count，不调用零尺寸ResizeBuffers，保留最近有效资源及HDR。继续处理消息，用短超时消息等待避免忙等。恢复后若尺寸相同，资源无需重建；若成像目标也没变，历史接着累积。恢复时若相机/场景已经改变，仍由TargetKey判定reset，不能因为“恢复窗口”就绕过失效判断。

当前测试是有限序列，暂停3个消息循环tick后自动恢复，不是完整无限运行的编辑器事件循环。阶段最后一帧故意不flush，下阶段安全点才退役；这验证CPU未退役提交的处理顺序，不保证GPU在某个具体CPU时刻仍物理执行着该帧。

## 7. 实测与验收边界

2026-10-15 RTX5070，8阶段各8帧：

|阶段|Back Buffer|ViewRect变化|历史末计数|资源代数|
|---|---|---|---|---|
|initial|480x270|初始160x90|8|0|
|odd-size|641x359|无|16|1|
|portrait|321x481|无|24|2|
|最小化/同尺寸恢复|321x481|无|32|2|
|wide-new-view|800x200|(20,3,120,90)|8|3|
|same-size-old-view|800x200|恢复(0,0,160,90)|8|3|
|original-size|480x270|无|16|4|
|one-row|120x1|无|24|5|

64帧Present/64帧读回，Back Buffer各32次；资源重建5次；历史重置3次（含初始化）；最小化跳过3tick且Fence维持25；最终Fence65/65。HDR独立平均误差1.14e-7，几何/阴影/非法值均0；显示RGB最大1码、超容限通道0、alpha错误0；Debug0/0，PASS。

实测RowPitch：641x359为2816，有效行2564；321x481为1536，有效行1284；800x200为3328，有效行3200；120x1为512，总必要空间480。查询footprint不能被“width*4就是行步长”的假设替代。

全章回归：R.13.1–2数学20组检查，R.13.4属性（同时覆盖.3相机/DXR基础）、.5直接光、.6统计累积、.7失效、.8a显示数学、.8b窗口均通过。日志保存在本课results/r13-08c/regression.txt。PNG取自真实Back Buffer PPM并仅为排版缩放，已查看；不同帧样本数也不同，不把噪声变化都归因于resize。

![不同窗口输出](../../sandbox/d3d12/r13-renderer/results/r13-08c/gpu_display.png)

[本节日志](../../sandbox/d3d12/r13-renderer/results/r13-08c/validation.txt) · [逐帧CSV](../../sandbox/d3d12/r13-renderer/results/r13-08c/resize_events.csv) · [全章回归](../../sandbox/d3d12/r13-renderer/results/r13-08c/regression.txt)

## 8. 命令

仓库根目录，先按主README编译history DXIL。显示协议变更后重新编译VS/PS与宿主：

```powershell
$lesson='learning/sandbox/d3d12/r13-renderer'
$dxc='C:/Program Files (x86)/Windows Kits/10/bin/10.0.26100.0/x64/dxc.exe'
& $dxc -T vs_6_0 -E VSMain -Fo "$lesson/dxr_display_vs.dxil" "$lesson/dxr_display.hlsl"
& $dxc -T ps_6_0 -E PSMain -Fo "$lesson/dxr_display_ps.dxil" "$lesson/dxr_display.hlsl"
& learning/sandbox/build.ps1 "$lesson/dxr_view_pipeline.cu" -NoRun
New-Item -ItemType Directory -Force "$lesson/results/r13-08c" | Out-Null
& "$lesson/dxr_view_pipeline.exe" "$lesson/dxr_history.dxil" resize 2>&1 | Tee-Object "$lesson/results/r13-08c/validation.txt"
& "$lesson/dxr_window_preview.ps1" -Resize
```

## 9. 自测与后续

1. 仅窗口从480x270变为641x359，内部像素网格和相机没变，是否必须清空HDR？为何本课不清空？
2. Fence已完成但还持有GetBuffer返回的旧ComPtr，能否认为ResizeBuffers的前提已满足？
3. 最小化后恢复同尺寸，为什么资源代数和历史epoch可以都不增加？

R.13目标范围内已完成：引擎式相机、DXR直接光、像素采样/渐进累积、历史失效、SDR窗口和输出resize。不是完整多反弹路径追踪器；内部动态分辨率、重投影、设备恢复等不在当前实现中。按既定路线，下一章C.1开始glTF对象模型，然后接入真实场景，后续PT.6再讲BSDF采样/NEE/MIS。

官方依据：[ResizeBuffers](https://learn.microsoft.com/en-us/windows/win32/api/dxgi/nf-dxgi-idxgiswapchain-resizebuffers)、[WM_SIZE](https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-size)。
