# R.13.8b：GPU显示通道与窗口Present

2026-10-15。前置R.13.8a。后续.8c已将显示常量升级为48B以支持源/目标矩形；下文原始固定3倍实验结果保持有效，运行时应重编译当前VS/PS与宿主。代码入口：[共享渲染主线README](../../sandbox/d3d12/r13-renderer/README.md)。本节完成真实窗口与GPU显示pass；R.13.8c的resize、最小化、资源重建和全章验收仍待完成。

## 1. 问题、约定和数据流

上一节验证D=Q8(S(T(2^EV H)))。现在H已经驻留GPU；只需在DXR后记录一个光栅pass读取H并写Back Buffer。CPU不应为了显示而先读回HDR再上传。当前CPU读回是验收支路，不参与窗口成像。

当前固定约定：历史160x96、ViewRect=(0,0,160,90)，元素float4=16B，xyz未曝光线性RGB、w样本数；窗口客户区/Back Buffer=480x270，最近邻3倍。只显示有效的前90行。全屏三角形、无VB/IB、无深度、无剔除、无混合、无MSAA；不是新一轮场景几何绘制。

选择手动sRGB路径：PS执行曝光/Reinhard/sRGB，PSO RTVFormats[0]和实际RTV均R8G8B8A8_UNORM。alpha=1。没有重复SRGB RTV编码。交换链显式设RGB_FULL_G22_NONE_P709作为传统SDR展示声明；这是DXGI命名，不代表shader把精确sRGB分段函数替换成pow(1/2.2)，也不代替编码计算。没有HDR10/PQ输出。

## 2. 为什么一个三角形能覆盖屏幕

取裁剪空间w=1，顶点(-1,-1)、(-1,3)、(3,-1)。三角形约束为x>=-1、y>=-1、x+y<=2，所有[-1,1]^2内点均满足，所以覆盖整个视口；多余部分裁剪。VS用SV_VertexID生成顶点，不需要顶点缓冲。PS使用SV_Position目标像素中心，floor后整除3得到源坐标：sx=floor(x/3)，sy=floor(y/3)，buffer index=sy*160+sx。窗口位置不需要反投影：它只是展示已有图像，不生成新主射线。

`dxr_display.hlsl`中VSMain/PSMain分别编译vs_6_0/ps_6_0。2026-10-21共享更新后t0=ByteAddressBuffer，R.13显式16B步长；b0为12个DWORD：uint4源矩形、uint4目标矩形、uint源行步长、float曝光补偿、uint像素字节步长、uint显示模式。实际实现提取到`d3d12/common`并与PT.10共用，原文件为include入口。CPU Constants精确48B，static_assert确认；.8b初版16B协议已被.8c扩展替代。Root constants复制值，无需256B CBV分配；根SRV传GPU VA，不复制buffer数据也不持有生命周期。

## 3. 资源、视图和PSO的职责

|对象|用途与所有权|
|---|---|
|共享history|GpuRaySequence拥有；DXR写、PS读；始终留GPU|
|swap chain|WindowDisplay拥有；与同一DIRECT queue及HWND关联|
|两张Back Buffer|交换链管理资源，WindowDisplay通过GetBuffer持有COM引用；不可在在途时释放|
|RTV heap|WindowDisplay拥有，2项CPU descriptor；不是shader-visible heap|
|graphics root signature/PSO|WindowDisplay拥有；与DXR state object分开|
|显示readback|WindowDisplay拥有的一块READBACK buffer；本节逐帧等待后复用|
|DXR输出readback/allocator/相机槽|复用GpuRaySequence的两槽；本节逐帧flush，因此未利用两槽重叠|

RTV描述的是目标资源/格式，不是一张额外图像。GetDescriptorHandleIncrementSize返回descriptor步长，不是像素字节数，不能硬编码32。根SRV可直接绑定buffer GPU VA；不是纹理SRV的通用替代。本节用结构化buffer所以不建SRV descriptor heap或sampler。

## 4. 关键API与参数

### 创建交换链

```cpp
HRESULT CreateSwapChainForHwnd(
    IUnknown* pDevice, HWND hWnd,
    const DXGI_SWAP_CHAIN_DESC1* pDesc,
    const DXGI_SWAP_CHAIN_FULLSCREEN_DESC* pFullscreenDesc,
    IDXGIOutput* pRestrictToOutput, IDXGISwapChain1** ppSwapChain);
```

D3D12的pDevice实际传DIRECT command queue，不是ID3D12Device。hWnd是固定客户区窗口；desc指定480x270、RGBA8_UNORM、BufferCount=2、SampleDesc.Count=1、RENDER_TARGET_OUTPUT、FLIP_DISCARD；两个可选指针null表示窗口模式、不限定输出；最后接收拥有的COM接口。HRESULT失败由check打印并终止。本节不实现设备丢失后的重建恢复。

每帧调用GetCurrentBackBufferIndex取得当前可绘制buffer，不能把DXR帧槽序号假定为交换链buffer索引。FLIP_DISCARD不保证提交后旧内容可复用，本课全屏覆盖，不依赖旧像素。

### 绑定历史和显示常量

```cpp
void SetGraphicsRootShaderResourceView(UINT RootParameterIndex,
                                      D3D12_GPU_VIRTUAL_ADDRESS BufferLocation);
void SetGraphicsRoot32BitConstants(UINT RootParameterIndex, UINT Num32BitValues,
                                  const void* pSrcData, UINT DestOffsetIn32BitValues);
```

调用分别是(0,historyVA)、(1,12,&constants,0)。0/1是root参数索引，t0/b0是不同寄存器命名空间。这12个DWORD中float按原始32位模式复制，不要把EV转换为整数。buffer stride来自shader的float4类型。

### 绑定目标并绘制

```cpp
void OMSetRenderTargets(UINT NumRenderTargetDescriptors,
    const D3D12_CPU_DESCRIPTOR_HANDLE* pRenderTargetDescriptors,
    BOOL RTsSingleHandleToDescriptorRange,
    const D3D12_CPU_DESCRIPTOR_HANDLE* pDepthStencilDescriptor);
void DrawInstanced(UINT VertexCountPerInstance, UINT InstanceCount,
                   UINT StartVertexLocation, UINT StartInstanceLocation);
```

OM参数为(1,&rtv,FALSE,nullptr)：一个CPU handle，按handle数组解释，无DSV。Draw为(3,1,0,0)：三顶点、一个实例、顶点及实例起始0。viewport/scissor均480x270；三角形列表拓扑。PSO汇总VS/PS、root、输出格式、光栅/深度/混合状态；它本身不选择本帧具体哪张Back Buffer，后者由RTV绑定决定。

### Present

```cpp
HRESULT Present(UINT SyncInterval, UINT Flags);
```

本课(1,0)，采用垂直同步间隔1，无额外flags。Present提交展示请求，不是“CPU可回收全部资源”的完成证明。DXGI_STATUS_OCCLUDED单独计数，失败HRESULT终止；提前关闭窗口被标为验收未完成，不冒称96帧通过。窗口回调仅记录关闭意图，外层先排空GPU再销毁。

## 5. 状态和同步：两条资源轨迹

history：UAV（DXR写）->PIXEL_SHADER_RESOURCE（PS读）->UAV（供下一帧）。第一条transition建立之前写与之后读的顺序，不需要紧邻重复UAV barrier。

Back Buffer：PRESENT->RENDER_TARGET（Draw写）->COPY_SOURCE（仅为验收读回）->PRESENT。没有诊断copy时应从RENDER_TARGET直接回PRESENT。Present前必须恢复展示状态；Present不是绘制命令，也不替我们执行曝光。

每帧CPU：记录DXR+显示+copy，Close，ExecuteCommandLists，Present，queue Signal递增Fence，等待，Map并验证。Fence说明此前队列工作完成，不说明面板已扫描显示。Map本身不等待GPU。

GpuRaySequence新增两个可选回调：RecordTail在DispatchRays之后记录显示，约定返回时history恢复UAV；submitted在Execute之后/Signal之前执行Present。旧课程不传回调，维持原有行为。本课每帧flush，故单个显示readback可安全复用；直接删除flush会引入覆盖风险，需要帧槽化readback及对应完成值。引擎通常减少逐帧CPU读回、让多帧在途；本课为数值验收串行化，不能据此评价渲染性能。

## 6. Readback布局不是纹理物理布局

```cpp
void GetCopyableFootprints(const D3D12_RESOURCE_DESC* pResourceDesc,
    UINT FirstSubresource, UINT NumSubresources, UINT64 BaseOffset,
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT* pLayouts, UINT* pNumRows,
    UINT64* pRowSizeInBytes, UINT64* pTotalBytes);
```

传Back Buffer desc、0号子资源、数量1、偏移0；取得footprint和总字节数，其余可选输出null。每行有效字节480*4=1920，但API返回RowPitch=2048（256对齐）。因此CPU地址=base+Offset+y*2048+x*4；不能用y*1920。总所需552832字节，最后一行只需1920有效字节，所以不强行等于2048*270。这是可复制的线性布局，不是在描述GPU纹理本身的tiling。

CopyTextureRegion把Back Buffer subresource0复制到readback的PLACED_FOOTPRINT，坐标0,0,0，source box=null复制整个子资源。Fence完成后Map；Unmap的noWrite范围为[0,0)。验证RGBA8每个像素：RGB与CPU double参考允许最多1码误差，alpha必须255。一个码差可能来自GPU浮点/pow与CPU double、量化边界差异，不能只凭差值归因于某一个因素。

## 7. 构建运行与本机结果

仓库根目录，逐步成功后执行下一步：

```powershell
$lesson='learning/sandbox/d3d12/r13-renderer'
$dxc='C:/Program Files (x86)/Windows Kits/10/bin/10.0.26100.0/x64/dxc.exe'
& $dxc -T lib_6_3 -D ENABLE_DIRECT_LIGHT=1 -D ENABLE_PROGRESSIVE=1 -D ENABLE_HISTORY=1 -Fo "$lesson/dxr_history.dxil" "$lesson/dxr_view.hlsl"
& $dxc -T vs_6_0 -E VSMain -Fo "$lesson/dxr_display_vs.dxil" "$lesson/dxr_display.hlsl"
& $dxc -T ps_6_0 -E PSMain -Fo "$lesson/dxr_display_ps.dxil" "$lesson/dxr_display.hlsl"
& learning/sandbox/build.ps1 "$lesson/dxr_view_pipeline.cu" -NoRun
New-Item -ItemType Directory -Force "$lesson/results/r13-08b" | Out-Null
& "$lesson/dxr_view_pipeline.exe" "$lesson/dxr_history.dxil" window 2>&1 | Tee-Object "$lesson/results/r13-08b/validation.txt"
& "$lesson/dxr_window_preview.ps1"
```

window模式必须匹配history DXIL。VS/PS从该DXIL同目录加载。窗口运行96帧自动结束，0/+1/-1 EV每段32帧；不是持续运行的交互编辑器。输出位置在DXIL目录下results/r13-08b。快照来自真实Back Buffer；PS脚本只把PPM转PNG加标题，无Python、无重新着色。

2026-10-15 RTX5070实测：96 Present/96读回；两个buffer各48次；occluded=0；RGB最大误差1码，超过容限通道0，alpha错误0；HDR独立CPU平均最大差2.05e-7，几何/阴影/非法值0；曝光改变不reset，只有初始化reset1次，历史连续1..96；Fence97/97（AS构建占1）；Debug errors/warnings=0/0，PASS。数字为本次实际运行，不从旧环境推断。

图依次32spp/EV0、64spp/EV+1、96spp/EV-1。不同帧样本数也不同，不能称为严格“同样本仅改曝光”的对照；.8a已有同PFM对照，本节对每帧实际HDR独立验证显示字节。

![GPU实际输出](../../sandbox/d3d12/r13-renderer/results/r13-08b/gpu_display.png)

[日志](../../sandbox/d3d12/r13-renderer/results/r13-08b/validation.txt)。PNG已查看；这验证Back Buffer数据，不是显示器光度校准或桌面截图。

## 8. 自测与后续

1. 为什么history从UAV变为PIXEL_SHADER_RESOURCE，展示后还要变回UAV？为什么这不是复制一份history？
2. Present成功之后，为什么不能直接Map读回并认为GPU已经完成？
3. width*4=1920而RowPitch=2048时，读取第y行应使用哪个步长？这个步长是否等于GPU纹理内部排布？

R.13.8c补上resize/最小化、Back Buffer引用释放与重建、尺寸/历史有效性及资源同步。本节固定分辨率，禁止尺寸控制和AltEnter，未声称处理所有OS窗口变化或设备恢复。

官方资料：[CreateSwapChainForHwnd](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_2/nf-dxgi1_2-idxgifactory2-createswapchainforhwnd)、[根SRV](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12graphicscommandlist-setgraphicsrootshaderresourceview)、[OMSetRenderTargets](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12graphicscommandlist-omsetrendertargets)、[Present](https://learn.microsoft.com/en-us/windows/win32/api/dxgi/nf-dxgi-idxgiswapchain-present)、[GetCopyableFootprints](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12device-getcopyablefootprints)。
