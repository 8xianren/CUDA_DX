# PT.10：降噪特征与CUDA外部消费者

2026-10-21；RTX 5070 / sm_120、CUDA Toolkit 13.3.33、Windows SDK 10.0.26100、OIDN 2.5.0 CUDA。本节完成真实DXR历史→共享DEFAULT缓冲→CUDA/OIDN→D3D12读回。章节仍进行中，下一节接窗口中的降噪输出与完整质量/性能评测。

[代码与命令](../../sandbox/path_tracing/dxr-path-tracer/README.md)；[结果](../../sandbox/path_tracing/dxr-path-tracer/results/pt10-interop/)；[前节显示](PT.10-曝光色调映射与窗口显示.md)。

## 先回答前节自测

1. 曝光EV描述倍率的对数：倍率m满足EV=log2(m)，故m=2^EV。+1EV是乘2。加1会给黑色也增加能量，改变亮暗比例。
2. HDR是内部线性数据的范围；SDR是输出显示契约。浮点积分结果经过曝光、压缩动态范围的显示曲线、一次sRGB编码和UNORM量化即可进入SDR交换链。二者属于不同阶段。
3. 仅改变窗口大小时，内部采样网格和相机射线分布不变，显示只重排既有像素。改变内部宽高会改变每像素覆盖的射线集合，且可能改变aspect；旧像素估计不再是新像素目标的估计，应重置。

## 1. 从像素问题推导特征定义

颜色C是一个像素足迹内多个主射线样本及其后续路径的平均。降噪器只看到C时，难以判断相邻像素的跳变来自真实材质/几何边界，还是Monte Carlo噪声。我们给它附加与照明不同的场景线索，称为guides（辅助特征）。这像引擎后处理读取G-buffer，但特征的具体语义必须由消费者决定。

假设本节采用均匀像素抖动、箱式像素滤波，每个主样本等权。对第s个主样本定义：

- L_s：完整路径积分贡献；是线性RGB。
- h_s∈{0,1}：主射线是否命中。
- a_s：首命中反照率近似；本课普通材质用基础色，纯金属该值是F0；教学玻璃、发光面、背景取中性(1,1,1)。这是近似特征，不是再乘到L上的材质权重。
- n_s：命中时的世界空间单位几何法线，miss取0。
- z_s=(p_s-eye)·forward：命中位置的正向view-z；miss令h_s z_s=0。这里不是沿射线距离t、NDC深度或硬件depth buffer。

相同像素滤波要求：

```text
C = (Σ L_s)/N
A = (Σ a_s)/N
V = (Σ n_s)/N
coverage = (Σ h_s)/N
depthMoment = (Σ h_s*z_s)/N
conditionalDepth = depthMoment/coverage  (coverage>0；否则0)
```

为什么不能颜色平均32条射线，法线只取第1条？轮廓处32条射线可能一半球体、一半背景；首样本只给出其中一侧，辅助边界和颜色的覆盖关系会错位。纹理细节也有同样问题。

为什么不能把V再归一化？例如一半样本命中n=(0,0,1)，另一半miss，V=(0,0,0.5)。归一化会抹掉这个覆盖特征。即使都命中，(1,0,0)和(0,0,1)的均值也不是单位向量。这不违反“表面法线应归一化”：每个真实表面的n_s仍是单位向量，V是像素统计特征。前课单个命中的法线、材质ID、实例ID属于另一种数据，ID绝不能平均成某个新实例。

深度除coverage得到命中条件下的均值。它在混合前后表面的边界处仍不对应某个真实表面；不能直接拿它当精确时域重投影深度。本节OIDN RT只消费color/albedo/normal，depth仅留诊断，未虚构depth输入。

跨批次M与B个样本时，对C/A/V/coverage/depthMoment全部使用：

```text
mean_new = mean_old + (mean_batch-mean_old) * B/(M+B)
```

代码：`path_integrator.hlsl:25`主样本循环，`:44`特征累加，`:101`求均值；`path_accumulate.hlsl:24`按样本数继续累积。`flags&2`开启该语义；默认flags=1仍保留前课首样本诊断。历史meta.z记录guide模式，历史键也包含flags，避免混用布局语义。position/实例ID仍是首个全局主样本诊断。

**边界**：首命中特征不能描述镜中物体或玻璃后的材质结构；本课未递归求反射/透射特征，没有normal map，没有时域运动信息，也不声称等价商业引擎的完整降噪输入。OIDN对辅助图的要求见[官方文档](https://www.openimagedenoise.org/documentation.html)。

## 2. 从消费者约束推导共享布局

现有history每像素128B，包含112B PathPixel和16B metadata。OIDN需要具有明确pixel stride/row stride的RGB图像，CUDA审计还需要计数与代号。我们保留物理history，GPU compute打包另一块共享buffer，不把显示/降噪结果覆盖到原始估计。

令P=width*height，平面大小S=16P，六平面共96P字节。

|平面|偏移|float4含义|
|---|---:|---|
|0|0S|线性beauty RGB，w=1|
|1|1S|albedo RGB，w=coverage|
|2|2S|平均世界normal XYZ，w=0|
|3|3S|conditionalDepth、coverage、0、0|
|4|4S|消费者output RGB，w=1|
|5|5S|uint4按位：count、generation、error bits、stamp|

像素(x,y)在平面k的地址为`base + k*S + (y*width+x)*16`。FLOAT3描述有效三个分量，但pixel stride是16B，不是12B；row stride为width*16。audit用asfloat/bitcast保存整数位模式，不能用数值float转换存32位stamp。

`path_pack.hlsl:8`用8×8线程组，一线程写一个像素六个位置；CUDA `path_cuda.cu:3`用128线程一维block，末尾超出P的线程退出。96×48与95×49同时验收。共享DEFAULT资源与CUDA block内的`__shared__`存储不是同一个概念。

192×96时逻辑缓冲=1,769,472B，实际D3D分配也为1,769,472B；96×48逻辑442,368B，实际458,752B。导入必须填实际allocation size，映射只填逻辑size。这个数字仅是共享packet分配，不是总显存或OIDN工作集。

## 3. 外部内存：共享的是存储，不是API对象

入口`path_interop.cpp:22`。一个D3D12资源对象、一个Win32 NT HANDLE、一个CUDA external memory对象、一个CUDA device pointer是四个不同概念。它们联系到同一底层资源，但有不同所有权与释放方式。

```cpp
HRESULT ID3D12Device::CreateCommittedResource(
    const D3D12_HEAP_PROPERTIES* heapProperties,
    D3D12_HEAP_FLAGS heapFlags,
    const D3D12_RESOURCE_DESC* resourceDesc,
    D3D12_RESOURCE_STATES initialState,
    const D3D12_CLEAR_VALUE* optimizedClearValue,
    REFIID riidResource, void** resource);
```

本节heap为DEFAULT、NodeMask=1；heapFlags=SHARED；resourceDesc为ROW_MAJOR buffer且ALLOW_UNORDERED_ACCESS；初始COMMON；buffer不用clear value；riid请求ID3D12Resource，输出由ComPtr拥有。

先用D3D `GetAdapterLuid()`匹配CUDA `cudaDeviceProp.luid`与node mask，不能假定CUDA device0就是DXGI adapter0。还检查D3D GetNodeCount()==1，本节不支持linked multi-node。

```cpp
HRESULT ID3D12Device::CreateSharedHandle(
    ID3D12DeviceChild* object,
    const SECURITY_ATTRIBUTES* attributes,
    DWORD access, LPCWSTR name, HANDLE* handle);

cudaError_t cudaImportExternalMemory(
    cudaExternalMemory_t* memory,
    const cudaExternalMemoryHandleDesc* desc);

cudaError_t cudaExternalMemoryGetMappedBuffer(
    void** pointer, cudaExternalMemory_t memory,
    const cudaExternalMemoryBufferDesc* desc);
```

CreateSharedHandle传shared resource、默认安全属性nullptr、GENERIC_ALL、匿名nullptr、HANDLE输出地址。该NT HANDLE由本进程关闭；CUDA导入不会替你CloseHandle。代码用局部RAII对象覆盖成功/失败路径。

import desc全部零初始化后填type=D3D12Resource、win32.handle、实际allocation size、cudaExternalMemoryDedicated。committed resource拥有独立堆，故使用dedicated标志。映射desc填offset0、size=96P、flags0；返回的指针是GPU地址，CPU不得直接解引用。只映射一次完整范围再计算各平面偏移，避免重叠映射的别名问题。

本课通过GPU compute布局转换，随后D3D与CUDA直接访问同一资源，没有D3D读回CPU再cudaMemcpy上传图像的中转。GPU打包写入仍然有带宽和时间成本，不能把这种共享路径叫作“没有任何数据搬运”。[CUDA外部资源互操作](https://docs.nvidia.com/cuda/cuda-programming-guide/04-special-topics/graphics-interop.html)解释了句柄导入模型。

## 4. 从读写依赖推导External Fence时间线

约束一：CUDA读packet必须在D3D写完后。约束二：D3D读output必须在CUDA写完后。约束三：下一次打包和释放资源，必须在上一消费者全部结束后。

一把D3D共享Fence导入为CUDA external semaphore，每轮r从0起：ready=2r+1，done=2r+2。等待条件是Fence达到至少指定值；不是普通二值锁。每个新建Interop实例有独立Fence，旧实例完全退役后可从0重新开始。

```text
D3D DIRECT队列                 CUDA非默认stream
DXR → history accumulate
history UAV→NPSRV
shared COMMON→UAV
Pack
shared UAV→COMMON
history NPSRV→UAV
Signal(sharedFence, ready) ───→ Wait(ready)
                              beginEvent
                              OIDN / passthrough
                              CUDA audit + stamp
                              endEvent
Wait(sharedFence, done)    ←─── Signal(done)
shared COMMON→COPY_SOURCE
Copy shared → READBACK
shared COPY_SOURCE→COMMON
history复制到另一READBACK
Signal(localFence, group)
              CPU只在这里等待完成，再Map/验收/复用资源
```

状态转换和Fence解决不同约束：barrier描述D3D资源访问方式及同队列依赖；外部Fence连接不同API的执行先后。UAV barrier不代替CUDA等待，等待Fence也不代替D3D资源状态。COMMON只是本节约定的交接状态，不意味着正在使用中的资源可以被另一API任意读写。

```cpp
HRESULT ID3D12Device::CreateFence(
    UINT64 initialValue,D3D12_FENCE_FLAGS flags,
    REFIID riid,void** fence);
cudaError_t cudaImportExternalSemaphore(
    cudaExternalSemaphore_t* semaphore,
    const cudaExternalSemaphoreHandleDesc* desc);
cudaError_t cudaWaitExternalSemaphoresAsync(
    const cudaExternalSemaphore_t* semaphores,
    const cudaExternalSemaphoreWaitParams* params,
    unsigned int count,cudaStream_t stream);
cudaError_t cudaSignalExternalSemaphoresAsync(
    const cudaExternalSemaphore_t* semaphores,
    const cudaExternalSemaphoreSignalParams* params,
    unsigned int count,cudaStream_t stream);
HRESULT ID3D12CommandQueue::Signal(ID3D12Fence* fence,UINT64 value);
HRESULT ID3D12CommandQueue::Wait(ID3D12Fence* fence,UINT64 value);
```

CreateFence初值0、SHARED标志、请求ID3D12Fence。再CreateSharedHandle；CUDA semaphore desc填D3D12Fence类型与HANDLE，其余0。wait/signal均传一个semaphore的地址、一个零初始化params的地址、count1、同一stream；params.fence.value分别填ready/done。

`queue.Wait`是GPU队列等待，函数不会像CPU WaitForSingleObject一样阻塞CPU到完成。CUDA Async等待/信号也排进stream。必须先把D3D生产者与ready signal排队，才能让queue等待done；不能将生产者排在其依赖的done等待之后，否则会构成环形依赖。

代码`path_interop.cpp:74`先录制两份command list；`path_interop.cpp:99`在生产者Execute之后的回调排队Signal/Wait/消费者。回接列表有独立allocator，只有上轮localFence完成后才Reset。`PathHistory::Flush`最后的本地Fence涵盖回接列表，因此不仅保护history上传资源，还保护CUDA和共享读回。

本课应用代码在D3D→CUDA→D3D交接中没有CPU等待；末尾仍有同步读回验收，并调用cudaStreamSynchronize检查异步状态。不能据此声称整个程序零CPU阻塞，或已经通过Nsight证明库内部所有行为无阻塞。

## 5. 可替换OIDN消费者

`path_interop.h:7`定义PathConsumer，只暴露Enqueue与CheckCompleted。透传参考由CUDA kernel执行，直接复制color→output，严格逐位验证；它不是降噪。真正降噪由`path_oidn.cpp:4`实现，依赖官方OIDN 2.5.0 Windows二进制，setup脚本固定release及SHA256。

OIDN是训练好的图像重建模块；RT是该库通用光线追踪图像过滤器的名称，不能由这个名称推断它替代DXR射线求交。当前做空间降噪，没有时间历史或运动矢量。

```cpp
OIDNDevice oidnNewCUDADevice(
    const int* deviceIDs,const cudaStream_t* streams,int numPairs);
OIDNBuffer oidnNewSharedBuffer(
    OIDNDevice device,void* devPtr,size_t byteSize);
void oidnSetFilterImage(
    OIDNFilter filter,const char* name,
    OIDNBuffer buffer,OIDNFormat format,
    size_t width,size_t height,size_t byteOffset,
    size_t pixelByteStride,size_t rowByteStride);
void oidnExecuteFilterAsync(OIDNFilter filter);
OIDNError oidnGetDeviceError(OIDNDevice device,const char** outMessage);
```

deviceIDs/streams均传单元素地址，numPairs1；使用前面匹配的CUDA ordinal与同一stream，明确不让库自动选CPU。oidnCommitDevice提交配置后创建buffer和filter。devPtr是CUDA导入映射地址，byteSize=96P；OIDN仅引用它，不接管底层D3D资源。

图像name依次color/albedo/normal/output；所有图像共享同一OIDNBuffer；format FLOAT3；宽高为内部像素尺寸；byteOffset为平面编号×16P；pixelByteStride16、rowByteStride16width。plane1的coverage与plane2的w不会被当成第四图像分量读取。

filter由oidnNewFilter(device,"RT")创建；oidnSetFilterBool设置hdr=true、srgb=false、cleanAux=false，最后oidnCommitFilter。color是线性HDR，尚未曝光/Reinhard/sRGB。有限主样本的辅助图在轮廓处有采样噪声，不能标成cleanAux=true。当前没做辅助图预滤波。

创建与commit放在外部生产者提交前，排除初始化资源分配与准备步骤；每轮只在wait(ready)之后Enqueue。oidnExecuteFilterAsync返回后检查立即错误；末尾Fence/stream完成后再检查设备错误。oidnGetDeviceError读取并清除错误；device为空时也可查设备创建的全局错误。官方的对象/stride/异步契约见[OIDN API](https://www.openimagedenoise.org/documentation.html)。

## 6. 所有权、重建和失败

正常顺序：完成末尾Fence → 释放OIDN filter/buffer/device → cudaFree映射 → cudaDestroyExternalMemory → cudaDestroyExternalSemaphore → 销毁event/stream → COM释放shared resource/fence。NT HANDLE只为导入暂时存在，构造结束已关闭。scene、BLAS/TLAS、材质、能量表活过全部GPU提交。

尺寸改变先完成旧交接、销毁旧消费者和Interop，再重建新尺寸history/packet/OIDN绑定。相机改变只重置history代号/计数；相同尺寸packet可复用。测试实际执行相机重置及95×49资源重建。

构造失败尚未提交，可以按已经成功创建的对象逐一清理并抛异常。提交以后发生无法完成的外部信号/等待错误，不能继续读回或盲目析构可能仍在使用的GPU资源；本节输出fatal并终止进程，交由OS回收。D3D末尾等待有30秒上限。本程序没有设备丢失重建、跨帧异步退役池或完整故障恢复，不能当成生产错误处理方案。

## 7. 本机验收与真实质量结果

从仓库根目录：

```powershell
.\learning\sandbox\path_tracing\dxr-path-tracer\verify_interop.ps1
```

脚本固定下载OIDN、CMake使用VS2022初始化编译器、CUDA_ARCHITECTURES=120，DXC编译ray/accumulate/pack，跑full与memcheck quick，再跑前课GPU history回归、生成PFM/PNG/CSV/JSON。CUDA与C++混合多target沿用共享CMake工程，没有复制另一套D3D上下文。日常独立.cu仍使用sandbox/build.ps1。

|检查|实测|
|---|---|
|64像素×13样本CPU double独立主射线参考|最大归一化差1.346e-7|
|2+5+6对一次13spp，含guide均值|最大归一化差3.06463e-7|
|同样本关闭/开启guides|radiance float4逐位相同|
|共享打包、CUDA透传、stamp/count/generation|全部通过；conditionalDepth最大归一化差1.11358e-7|
|重复交接、相机重置、95×49非整组尺寸|全部通过|
|OIDN重复同图|输出归一化差0；原始history逐位保持|
|D3D Debug/GPU Validation|0 warning/error，full Fence19/19|
|Compute Sanitizer memcheck + leak-check full|0 errors，0 bytes leaked；quick Fence10/10|
|前课GPU history回归|全部通过，Fence33/33、Debug0|
|PT.8 K0回归|1,179,648射线、invalid/nonfinite0、Fence2/2、Debug0|

以上结果证明本次接口、布局、样本均值与同步检查通过，不能证明降噪总能提高质量，也不等于所有并发调度的形式化证明。CUDA memcheck覆盖本次执行的CUDA访问；D3D访问由其验证层与读回参考覆盖。

192×96、32spp、同一物理history，对独立seed73/1024spp参考：

|输出|全图线性RGB MSE|参考maxRGB≤2区域MSE|参考maxRGB>2区域MSE|
|---|---:|---:|---:|
|未降噪|0.00919809|0.00647021|0.115538|
|OIDN仅颜色|0.01345646|0.00166863|0.472977|
|OIDN颜色+albedo+normal|0.01861140|0.00157003|0.682929|

亮区mask统一由独立参考`maxRGB>2`定义，占像素2.501%；不是按各候选的误差挑选有利区域。guides版本亮区贡献总平方误差91.775%。可见平滑区域明显改善，但亮区损失使全图MSE上升；不能由这个小场景推出一般的“guides有害”。参考也有有限样本噪声，单种子结果不是普遍质量保证。显示图已经目视检查：低分辨率亮条边界和反射细节发生平滑。

![真实输出对比](../../sandbox/path_tracing/dxr-path-tracer/results/pt10-interop/denoise-comparison.png)

![特征图](../../sandbox/path_tracing/dxr-path-tracer/results/pt10-interop/guide-comparison.png)

当前CUDA event观测：guides第一次0.976032ms，重复0.486208ms，color-only第一次0.536896ms。区间包围消费者+审计，不含等待生产者；D3D验证层开启，未做充分预热/多轮统计，**不是最终性能结论，也不是公平的两模式速度比较**。32spp真实TraceRay=1,758,453；1024spp参考56,208,525。下一小节补完整GPU分段时间、质量/采样预算/分辨率对照和显存口径。

商业引擎通常按不同信号、材质与时域信息组织降噪，并结合自己的渲染任务调度；本课先用单张图与一个共享buffer暴露最基本的生产/消费约束。共同机制是输入语义、读写依赖和资源寿命；当前逐组CPU读回用于验收，没有宣称多帧高吞吐渲染架构。

## 8. 自测与接续

1. 一半样本命中(0,0,1)、另一半miss，normal guide应是什么？为什么不能再归一化？
2. 共享HANDLE导入成功后，为什么CUDA仍不能立即读取？UAV barrier与外部Fence分别解决什么问题？
3. 降噪图更平滑，为何线性HDR MSE仍可能变大？能否把它写回物理采样history继续平均？

按已授权的连续课程，下一节直接给答案，再接降噪显示和质量/性能评测，不等待“继续”。PT.10尚未整体完成，之后依次PT.9、PT.11、PT.12。
