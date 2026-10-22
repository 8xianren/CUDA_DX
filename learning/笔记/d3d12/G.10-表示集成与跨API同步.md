# G.10 表示集成与 CUDA/D3D12 跨 API 同步

本节目标：让网格、体渲染、3D Gaussian Splatting 和已经导出的 NeRF 图像进入同一个 D3D12 窗口，明确相机、颜色、深度、资源所有权与队列同步。它把 G.1–G.9 连接成可运行的渲染实验室，同时保留每种表示的独立实现。

共享工程：[neural-rendering](../../sandbox/d3d12/neural-rendering/README.md)。主要代码是 [main.cpp](../../sandbox/d3d12/neural-rendering/src/app/main.cpp)、[passes.h](../../sandbox/d3d12/neural-rendering/src/app/passes.h)、[passes.cpp](../../sandbox/d3d12/neural-rendering/src/app/passes.cpp)、[shared_texture.cpp](../../sandbox/d3d12/neural-rendering/src/interop/shared_texture.cpp)、[bridge.cu](../../sandbox/d3d12/neural-rendering/src/app/bridge.cu)、[passes.hlsl](../../sandbox/d3d12/neural-rendering/shaders/passes.hlsl)。

源码定位：`shared_texture.cpp:5` 创建/导入共享纹理，`:40` 拷入共享 array；`bridge.cu:4` 推导 mesh Z 到射线距离，`:30` 转回 view Z；`passes.cpp:49` 适配体渲染，`:61` 适配高斯，`:70` 载入 NeRF 缓存；`graphics.cpp:31` 输出网格 MRT，`:49` 合成；`window.cpp:24` 执行 resize。

## 1. 先建立模块边界

这次整合不把相机数学、网络训练、场资源、窗口和角色控制写成一个不断增长的文件。核心职责如下：

|模块|拥有的资源|借用的输入/输出|负责什么|
|---|---|---|---|
|`volume::Volume`|三维密度 array、texture object、occupancy grid|输出 float4、mesh ray distance|射线体积分|
|`gs::Renderer`|高斯参数、投影/扫描/排序/分桶工作区|相机、输出、mesh view Z|3DGS 前向渲染|
|`NerfPass`|已读入 CPU 的缓存颜色/深度|调用方 CUDA stream 和输出指针|把已完成推理的固定相机图像送入显示链|
|`DeviceFrame`|当前尺寸的 CUDA 线性缓冲|stream|帧输出与深度桥接存储|
|`SharedTexture`|D3D texture、CUDA external memory、映射 mip array|线性缓冲、stream|共享资源视图与二维复制|
|`Graphics`|Root Signature、PSO、descriptor heaps|网格/颜色/深度纹理|D3D12 网格、合成和最终显示|
|`Window`|HWND、swap chain、back buffers|D3D queue|消息、Present、两尺寸切换|
|主循环|帧号、ready/done Fence、调度顺序|上述各模块|执行依赖与验收|

`RadiancePass` 的公共输出是线性预乘 RGBA，宽高来自当前帧。它不拥有 D3D12 PSO；图形模块也不直接访问神经网络权重或高斯排序临时区。

本工程复用 C/D 的 `UploadContext`、F 的纹理/描述符/读回辅助、E 的设备 LUID 匹配和外部 Fence；G 新增共享二维纹理与各表示的适配层。它没有重新复制 H 的玩家输入、角色控制和动画系统，也没有把 G 的新表示接入 H 的完整动态人物路径追踪应用。后续集成 H 时，可以保留这些模块边界，再接入统一相机、帧资源和渲染调度。

## 2. 为什么相同尺寸的图像仍可能无法合成

“都是 `640×360 float4`”只说明存储形状一致，尚不足以正确合成。还必须回答：

1. 两张图使用同一个相机位置、基向量、视场角和像素中心吗？
2. RGB 是线性值还是 sRGB 编码值？是否已经乘过 Alpha？
3. 深度是 NDC、view Z、射线距离，还是某种期望深度？
4. 写入是否真的完成？资源当前能否由 D3D12 SRV 读取？

本课固定相机 eye=`(0,0,-3)`，`+X` 向右、`+Y` 向上、`+Z` 向前，垂直 FOV 为 50°，像素中心为 `(x+.5,y+.5)`，图像原点在左上。验证先用 `640×360`，再改为 `320×240`。后者不仅分辨率改变，宽高比也改变，因此不能只把旧图拉伸到新窗口。

网格包含两张真实三角形矩形：背景平面世界 `z=1.5`，即 view Z=`4.5`；前景窄板世界 `z=-.65`，即 view Z=`2.35`，范围为 `x∈[-.18,.18]`、`y∈[-.8,.8]`。它不是只在合成阶段画一条遮挡色带，而是先经过 D3D12 顶点/像素管线和深度测试，输出网格颜色与线性 view Z。

## 3. 从几何关系推导 view Z 与射线距离

令像素在距离相机 1 的观察平面上的坐标为 `(sx,sy,1)`：

\[
s_x=(2(x+.5)/W-1)(W/H)\tan25^\circ,
\quad s_y=(1-2(y+.5)/H)\tan25^\circ.
\]

归一化射线方向是

\[
\mathbf d=\frac{(s_x,s_y,1)}{\sqrt{s_x^2+s_y^2+1}},
\quad d_z=\frac1{\sqrt{s_x^2+s_y^2+1}}.
\]

从相机沿射线行进世界距离 `t` 后，相机空间 Z 为 `z=t*d_z`，因此

\[
t=\frac z{d_z}=z\sqrt{s_x^2+s_y^2+1},
\qquad z=t\,d_z.
\]

中心像素附近两者接近；屏幕边缘斜射线的路程更长。若把 view Z 原样当作 ray distance 传给体积分器，边缘会过早截断，看起来像雾与网格边缘分离或遮挡形状变小。

本课 D3D12 同时写两个 MRT：线性 RGBA 网格颜色，以及 `R32_FLOAT` 的线性 view Z；另有 `D32_FLOAT` DSV 负责常规深度测试。传给 CUDA 的不是 DSV 中的非线性 NDC depth，因此无需再用近远平面反解投影深度。`bridge.cu` 负责上述 Z/t 转换，把接口约定显式放在桥接层。

### 同为 view Z 也不一定有相同语义

体渲染核心给出的代表深度是“累计 Alpha 首次达到 0.5 的位置”；适配层将其 ray distance 转成 view Z。3DGS 和 NeRF 可以使用按权重归一化的期望 view Z。这些都能用于调试、统计或某些后处理，但不是精确的不透明表面。

网格遮挡发生在积分/光栅内部：体渲染把积分远端截到网格 ray distance；高斯按其深度与 mesh Z 比较；NeRF 的缓存输出在离线推理时按同一固定网格截断。不能用最终的一张期望深度图，直接给整个半透明表示做一次硬切并假装恢复了正确积分。

## 4. 线性颜色、预乘 Alpha 与参考训练外观

体积分器输出 `C=sum(T_i*alpha_i*c_i)`、`A=1-T_final`。RGB 已含各段权重，称为预乘 Alpha。网格是当前射线后面的不透明背景，合成公式为

\[
C_{final}=C_{representation}+(1-A_{representation})C_{mesh}.
\]

不再乘一次 A。先乘 A 再混合会让低覆盖率区域过暗。`passes.hlsl` 使用 `Texture2D.Load` 按同一个像素取两张离屏图，避免额外的缩放/过滤混入验收。

所有离屏合成在**线性 RGB** 中完成；最后写 `R8G8B8A8_UNORM` 交换链时才执行 sRGB OETF。这里的 UNORM 存储本身不会自动替 shader 做颜色编码，因此需要明确的一次转换；也不能在 CPU 预览、shader 和 `_SRGB` view 中重复编码。

G.9 导入的参考高斯资产通常拟合的是经过照片编码的外观值。本课对该资产完成高斯外观合成后，先解除预乘，解码 sRGB，再乘回 Alpha，以满足本窗口的线性输出契约：

```text
straightEncoded = encodedPremultiplied / alpha
straightLinear  = sRGBDecode(straightEncoded)
linearPremultiplied = straightLinear * alpha
```

Alpha 很小时避免除零。这是明确的显示适配，不等于重新训练了物理辐射场。由于非线性解码与透明叠加不交换次序，它也不声称完全复现上游查看器的所有色彩/合成约定。

## 5. 外部内存：同一块资源怎样获得两个 API 的视图

共享不是把一个 D3D12 COM 指针传给 CUDA 后直接解引用。这里有三层对象：

```text
D3D12 committed texture（真正的资源与底层分配）
  └─ Win32 NT HANDLE（导入用的操作系统句柄，导入后由应用关闭）
      └─ cudaExternalMemory_t（CUDA对该分配的导入引用）
          └─ cudaMipmappedArray_t（按格式/尺寸映射的纹理视图）
              └─ cudaArray_t mip0（借用的第0级，不能独立释放）
```

创建前先比较 D3D12 adapter LUID 与 `cudaDeviceProp.luid`，并检查单节点掩码。机器有核显与独显时，不能凭“D3D 设备 0”和“CUDA 设备 0”推定它们是同一块 GPU。

### D3D12 资源创建参数

`CreateCommittedResource` 的本课参数逐项为：

|参数|本课选择与原因|
|---|---|
|`pHeapProperties`|`D3D12_HEAP_TYPE_DEFAULT`；资源由 GPU 使用，节点掩码为 1|
|`HeapFlags`|`D3D12_HEAP_FLAG_SHARED`，允许导出共享句柄|
|`pDesc.Dimension`|`TEXTURE2D`|
|`Width/Height`|当前帧尺寸|
|`DepthOrArraySize/MipLevels/SampleDesc.Count`|都为 1，单层、单 mip、单采样|
|`Format`|颜色 `R32G32B32A32_FLOAT`，网格 Z `R32_FLOAT`|
|`Flags`|`ALLOW_RENDER_TARGET`，网格 Z 要由 D3D MRT 写入，CUDA 映射也据此声明用途|
|`InitialResourceState`|`COMMON`，方便定义跨 API 交接边界|
|`pOptimizedClearValue`|格式一致的优化清除值；它不等于创建时已执行清除|
|`riidResource/ppvResource`|请求 `ID3D12Resource` 并由 `ComPtr` 持有|

随后通过 `GetResourceAllocationInfo(0,1,&desc).SizeInBytes` 得到实际分配大小，不能简单写成 `W*H*bytesPerPixel`；D3D12 的资源分配可能包含对齐。

```cpp
HRESULT CreateSharedHandle(ID3D12DeviceChild* object,
    const SECURITY_ATTRIBUTES* attributes, DWORD access,
    LPCWSTR name, HANDLE* handle);
```

这里 `object` 是刚创建的 texture；`attributes=nullptr` 使用默认安全描述符且不继承句柄；`access=GENERIC_ALL`；`name=nullptr` 不创建命名共享对象；最后一个参数接收 NT HANDLE。返回 `HRESULT` 必须检查。[Microsoft CreateSharedHandle 文档](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12device-createsharedhandle)

### CUDA 导入与映射参数

以下函数的实际声明可在本机 CUDA 13.3 的 `cuda_runtime_api.h` 查到：

```cpp
cudaError_t cudaImportExternalMemory(cudaExternalMemory_t* out,
    const cudaExternalMemoryHandleDesc* desc);
cudaError_t cudaExternalMemoryGetMappedMipmappedArray(cudaMipmappedArray_t* out,
    cudaExternalMemory_t memory, const cudaExternalMemoryMipmappedArrayDesc* desc);
cudaError_t cudaGetMipmappedArrayLevel(cudaArray_t* out,
    cudaMipmappedArray_const_t mipmap, unsigned level);
```

导入描述符设置 `type=cudaExternalMemoryHandleTypeD3D12Resource`，`handle.win32.handle` 为 NT HANDLE，`size` 为前述实际 allocation size，`flags=cudaExternalMemoryDedicated`。本课创建的是 committed resource，底层分配专属于该资源，必须按这个关系声明。导入结果通过 `out` 返回。

Win32 NT HANDLE 的所有权仍属于应用：本课在导入成功或失败后都执行 `CloseHandle`。CUDA 导入对象与 D3D COM 引用随后保持底层资源存活，关闭这个临时句柄不等于销毁纹理。

映射描述符设置 `offset=0`，格式为 `cudaCreateChannelDesc<float4>()` 或 `float`，`extent=(W,H,0)` 表示二维 array，`numLevels=1`；底层资源允许作为 render target，所以 `flags=cudaArrayColorAttachment`。映射成功后取 `level=0` 的 array。不要改成 `extent.depth=1` 后又在文档中继续称其为完全相同的二维资源声明。

`cudaArray_t` 不是线性指针。本课的核心 renderer 输出到连续 CUDA 缓冲，然后通过以下 API 拷入/读出共享 array：

```cpp
cudaError_t cudaMemcpy2DToArrayAsync(cudaArray_t dst,
    size_t wOffset, size_t hOffset, const void* src, size_t srcPitch,
    size_t widthBytes, size_t heightRows, cudaMemcpyKind kind, cudaStream_t stream);
```

目标 array 是共享纹理的 mip 0；两个偏移为 0；源指针是调用方线性输出；`srcPitch=widthBytes=W*16`（RGBA）或 `W*4`（Z）；高度是 H 行；类型为 `cudaMemcpyDeviceToDevice`；stream 与前后的外部 Fence 操作一致。反向的 `cudaMemcpy2DFromArrayAsync` 用于把 D3D 写好的网格 Z 读入 CUDA 线性缓冲。

这是 GPU 内复制，没有图像经过 CPU，但它仍是一次复制、仍占用时间和带宽。若未来将 renderer 改成直接 surface 写共享 array，要修改明确的输出接口，而不能把当前代码宣传成“零复制”。[CUDA External Resource Interoperability](https://docs.nvidia.com/cuda/cuda-runtime-api/group__CUDART__EXTRES__INTEROP.html)

## 6. 为什么内存共享以后仍需要 Fence

两个 API 看到同一块内存，并不意味着 CUDA 已经写完。CPU 按顺序调用两个异步 API，也不自动建立它们之间的 GPU 执行依赖。

本课使用两条单生产者时间线：

|Fence|唯一 Signal 方|等待方|值 f 的含义|
|---|---|---|---|
|`ready`|D3D12 queue|CUDA stream|第 f 帧网格 Z 与共享资源交接已完成|
|`done`|CUDA stream|D3D12 queue|第 f 帧 CUDA 渲染及输出复制已完成|

第 f 帧的顺序是：

```text
D3D12: Mesh → sharedZ转COMMON → Signal ready=f
CUDA : Wait ready=f → 读meshZ → Z转ray distance → RenderPass
       → 输出复制到sharedColor → Signal done=f
D3D12: Wait done=f → sharedColor转SRV → 合成 → Present
```

ready 与 done 分别从 1、2、3…递增，resize 时继续使用全局帧号，不把还活着的 Fence 计数重置为 0。

### 为何强调“单生产者”

Fence 等待的是“完成值达到或超过目标”，它不是按名字识别一个任务。如果两个生产者可以独立推进同一条 Fence，较快一方先写到更大值，可能让另一方尚未完成的较小值看起来已经满足。精心设计的一条时间线也能建立正确协议，但本课用两条独立的单生产者时间线，让每个值的含义可直接证明。

本实现为了易于验收，每帧仍有 CPU 等待；D3D `SubmitWait` 还负责安全复用命令分配器和描述符。因此它不是多帧并行吞吐架构。保留显式外部 Fence 的价值是把跨 API 的真实依赖写在正确的位置，而不是以当前 CPU 等待“碰巧足够慢”为依据。

### Fence 导入与异步等待的全部关键参数

D3D12 创建 `D3D12_FENCE_FLAG_SHARED` Fence，初始值为 0，通过 `CreateSharedHandle` 导出。CUDA 导入描述符选择 `cudaExternalSemaphoreHandleTypeD3D12Fence`，`handle.win32.handle` 为该 HANDLE，其他未用字段清零。导入成功后应用关闭临时 HANDLE。

```cpp
cudaError_t cudaImportExternalSemaphore(cudaExternalSemaphore_t* out,
    const cudaExternalSemaphoreHandleDesc* desc);
cudaError_t cudaWaitExternalSemaphoresAsync(const cudaExternalSemaphore_t* semaphores,
    const cudaExternalSemaphoreWaitParams* params, unsigned count, cudaStream_t stream);
cudaError_t cudaSignalExternalSemaphoresAsync(const cudaExternalSemaphore_t* semaphores,
    const cudaExternalSemaphoreSignalParams* params, unsigned count, cudaStream_t stream);
```

`out` 返回 CUDA semaphore 句柄；等待/信号的数组各只含一个句柄，`count=1`；对应参数结构的 `params.fence.value=f`，未使用字段为 0；stream 为当前非阻塞 stream。Wait 只约束该 stream 后续工作，不阻塞全部 CUDA stream，也不意味着 CPU 在这里等待。

D3D12 的 `queue->Signal(ready,f)` 在前面的队列工作之后更新值；`queue->Wait(done,f)` 把等待排进 GPU queue，API 可立即返回。CPU 若需要等待，则使用 `SetEventOnCompletion` 配合系统事件，本课复用 C/D 的 `SubmitWait`。[Microsoft CommandQueue::Wait 文档](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12commandqueue-wait)

## 7. Resource State、所有权与 resize

状态转换和 Fence 解决不同问题。D3D resource state 说明下一次 D3D 访问的用途，例如 RT、SRV、COPY_SOURCE；Fence 说明跨队列之前的访问何时真正完成。仅把资源转为 `COMMON` 不会等待 CUDA，只有 Wait 也不能代替后续合法的 D3D 状态转换。

共享 Z 的主要状态为 `RENDER_TARGET → COMMON → CUDA读取`；共享颜色为 `COMMON → CUDA写入 → PIXEL_SHADER_RESOURCE`。验证读回会临时进入 `COPY_SOURCE`，下一帧再通过状态账本转换到需要的状态。账本记录“已录制命令执行到这里时的状态”，不是 GPU 此刻进度查询。

resize 顺序是：排空 CUDA stream 与 D3D queue，释放旧帧线性缓冲、CUDA mip 映射、external memory 与 D3D 纹理；等待并释放 back buffer 引用后调用 `ResizeBuffers`；再按新尺寸创建共享纹理/缓冲并重新写 RTV/SRV/DSV。描述符不是资源所有者，旧描述符不会因为旧纹理销毁而自动更新。

销毁共享纹理时先 `cudaFreeMipmappedArray`，再 `cudaDestroyExternalMemory`，最后释放 D3D COM 资源。mip 0 的 array 是借用视图，不独立调用 `cudaFreeArray`。外部 semaphore 也必须在所有在途 Wait/Signal 完成后销毁。

创建、映射和复制的每个 CUDA/HRESULT 错误都会转成异常并最终给出非零退出码；部分构造成功后的异常路径会释放已建立的映射和引用。正常交接和 resize 的前提仍是队列正确完成，设备移除或超时不能按“下一帧继续试试看”处理。

## 8. NeRF 在这里到底执行了哪一段

G.4 已实际在 RTX 5070 上训练一个 15,117 参数的 PyTorch 小网络：1,800 步，12 个 32×32 训练视角，训练耗时约 5.054 秒；G.5 已执行直接 MLP 与烘焙网格两条推理路径，并导出固定相机的颜色/深度。

G.10 的 `NerfPass` 读取这些**已经完成推理的**文件，检查尺寸与颜色有限性，通过 `cudaMemcpyAsync` 从宿主数组拷入自己拥有的 CUDA 线性缓冲，再走共享纹理路径。它没有直接把 PyTorch allocator 的 tensor 当作 D3D12 texture，也没有在每个显示帧重新执行网络。

因此 app 的 `nerf_cached` 计时是缓存图像的 staging 时间，不能叫作 NeRF 推理时间，更不能对其取倒数后宣传“NeRF FPS”。文件加载、完整推理、网络训练、显示传输是四种不同成本。

缓存只覆盖当前两个分辨率、固定相机和固定遮挡板；改相机或网格后必须重新推理/导出。原始输出的定义和 SHA256 位于 [nerf_camera.json](../../sandbox/d3d12/neural-rendering/results/g5/nerf_camera.json)，G.5 的 [benchmark.json](../../sandbox/d3d12/neural-rendering/results/g5/benchmark.json) 才是推理对照依据。

## 9. 实测与比较范围

本节实测数据由两类运行产生：开启 D3D Debug Layer/GPU Validation 的正确性运行，以及关闭这些验证的性能运行。两者不能混用时间；首次资源分配、shader/driver 初始化和首次缓存读取也不应直接充当稳定帧耗时。

以下结果来自本课保存的 JSON/CSV；所有表示使用同一窗口相机约定，但体积球、教学高斯场、NeRF 合成场和真实训练资产并不是同一套几何真值。因此质量指标各自相对本课参考计算，不能从表里推导“某一种表示天然比另一种更准确”。

### 9.1 两尺寸、四模式与独立遮挡验证

硬件为 RTX 5070、驱动 610.88，C++/CUDA 核心使用 Toolkit 13.3、`sm_120`；PyTorch 网络部分是 `2.14.1+cu130`，其自带 CUDA 运行环境与 C++ Toolkit 不是同一个版本号。

|检查|4,096 个教学高斯场|741,883 个参考资产高斯|
|---|---:|---:|
|完整窗口帧数|8|8|
|尺寸 / 每尺寸模式|640×360 与 320×240，各 4 模式|同左|
|CPU 合成 oracle 最大差|5.96046e-8|4.76837e-7|
|D3D 网格线性 Z 最大差|0|0|
|独立 CPU Z→ray distance 最大差|9.53674e-7|9.53674e-7|
|CPU/GPU 全幅体积遮挡最大差|1.72138e-4|1.72138e-4|
|体积独立遮挡 oracle 数量|2|2|
|D3D Debug/GPU Validation 报告数|0|0|
|结束时 ready / done 完成值|8 / 8|8 / 8|

合成 oracle 根据读回的两张颜色图在 CPU 独立计算预乘公式，但它只能验证合成，不能证明输入图像本身正确。因此另有两个独立检查：用解析网格范围重建每像素 view Z 与 ray distance；再把这份 CPU ray distance 送入 CPU 体积分器，与真正经过 D3D→CUDA 共享深度、GPU 采样、CUDA→D3D 共享颜色的结果逐像素比较。

后一个检查避免了“GPU 给出错误遮挡图，CPU 又直接把它当真值”的循环验证。CPU 和硬件三线性过滤存在有限精度差，阈值为 `5e-4`，实测低于阈值。合成阈值为 `2e-6`，ray-distance 阈值为 `3e-6`。

对应证据：[教学场 summary](../../sandbox/d3d12/neural-rendering/results/g10/validation/summary.json)、[参考资产 summary](../../sandbox/d3d12/neural-rendering/results/g10/reference-asset/summary.json)。参考资产按发布者说明来自 GraphDeco 方法训练的第 7,000 次迭代；本机做的是下载完整性核验、格式转换、属性检查和显示，没有重新训练该资产，也没有把发布者的训练结果冒充本机训练成果。

### 9.2 性能：计时覆盖哪一段

关闭 D3D Debug/GPU Validation 后，每个“尺寸×模式”运行 12 次，前 2 次作为预热，后 10 次给出中位数与范围，共 96 帧。CUDA event 放在 `RenderPass` 调用前后，**包含宿主发起 kernel 之间的空隙，不包含 D3D 网格绘制、最终显示和 Present**；输出拷入共享 array 也在结束事件之后。

|模式|640×360 中位数 ms|该组 min–max ms|320×240 中位数 ms|该组 min–max ms|
|---|---:|---:|---:|---:|
|mesh 模式的 CUDA 透明清除|0.010400|0.006336–0.038912|0.007040|0.006048–0.063456|
|volume 积分及代表深度转换|0.100848|0.091168–0.113088|0.085536|0.081824–0.109728|
|4,096 个教学高斯的 pass|0.935664|0.405792–1.050210|0.619552|0.493952–0.913888|
|NeRF 缓存图像 staging|0.524640|0.411840–0.624992|0.182944|0.162624–0.240384|

mesh 行测到的是给 CUDA 表示输出清成透明的成本，**不是 D3D 网格渲染耗时**；NeRF 行测到的是颜色/深度宿主缓存上传，**不是网络推理耗时**。不能把表格数字直接取倒数当成整体窗口 FPS。这里显示和每帧等待的调度也不代表可并行引擎的最终吞吐。

参考训练资产的 74 万高斯没有混入上述 4,096 个教学高斯的性能统计；它的本轮运行开启验证，只用于检查完整资产能否进入相同窗口、同一同步与合成链，不把其中首次帧耗时当稳定性能结论。原始记录和明确的限制见 [performance/report.json](../../sandbox/d3d12/neural-rendering/results/g10/performance/report.json) 与 [frames.csv](../../sandbox/d3d12/neural-rendering/results/g10/performance/frames.csv)。

### 9.3 数据规模、训练/加载、显存与可编辑性

|表示|本课规模及表示数据|准备 / 训练 / 加载实测|质量依据与编辑方式|
|---|---|---|---|
|网格|两矩形、4 个三角形，顶点由 shader 生成；表示缓冲为 0 不代表整个渲染器零显存|不需要训练；此表没有单独测 D3D 网格管线时间|解析矩形深度 oracle；可直接修改几何/颜色|
|体积|128³ float + 16³ byte occupancy，8,392,704 字节有效载荷|本次性能运行的构造/生成/上传约 9.5472 ms；无训练|G.1 步长收敛，G.2 CPU/GPU，G.10 遮挡 oracle；可以直接编辑密度/传递函数，但需更新 GPU 资源与 occupancy|
|教学 3DGS|4,096 条×244 字节，999,424 字节输入参数|本次性能运行的生成/加载与上传约 0.4566 ms；无训练|G.6–G.8 投影/排序/CPU 图像参考；直接修改位置、尺度、旋转、不透明度和 SH|
|参考训练 3DGS|741,883 条；原 PLY 183,988,515 字节，运行文件 181,019,476 字节（含 24 字节头）|G.9 解析/转换/核验约 1.2158 s；本次带验证 app 的文件加载、显示归一化与上传约 497.31 ms；本机未训练|属性逐项核验及窗口合成正确性；没有相同训练相机下的上游图像质量基准，不宣称原始 PSNR 复现|
|NeRF 小网络|15,117 参数，参数有效载荷 60,468 字节，checkpoint 65,124 字节|实际训练约 5.0541 s；留出视角 RGB PSNR 48.8801 dB|修改网络通常需要再训练；当前是小型合成场基线|
|NeRF 烘焙网格|64³×13 个 float，13,631,488 字节|额外烘焙约 0.1347 s；未声称训练更快|相对直接 MLP 的 RGB MSE 2.93897e-7；网格可查询，但不是原网络参数的无损压缩|
|NeRF 窗口缓存|640×360 RGBA+深度共 4,608,000 字节；320×240 共 1,536,000 字节|已完成推理的固定相机文件；窗口只上传缓存|改相机/遮挡后须重新导出，不能像实时几何那样任意移动视点|

准备时间都是所列范围的单次实际结果，不能与 10 次稳态中位数混成一个同口径排行。G.5 在固定 `128×96`、64 样本/射线下，真正的直接 MLP 推理中位数为 `9.415984 ms`，烘焙网格为 `5.363168 ms`，约 `1.756×`；对应 PyTorch peak allocated 分别为 `138,498,048` 和 `64,049,152` 字节。该指标包含进程中驻留的相关张量，不是两个场表示单独占用量，也不能外推成 G.10 的 640×360 时间。

G.10 另外记录分层内存，不把“表示大小”冒充“总显存”：

|资源范围|640×360|320×240 / 当前末帧|
|---|---:|---:|
|两张导出共享纹理的实际 D3D allocation|4,915,200 字节|1,638,400 字节|
|RGBA、代表深度、meshZ、meshRay 线性缓冲有效载荷|6,451,200 字节|2,150,400 字节|
|教学 GS renderer 持久分配|按容量保留，末帧报告 2,711,040 字节|同左|
|教学 GS renderer 临时工作区|末帧报告 641,791 字节|同左|
|参考 GS renderer 持久分配|按容量保留，末帧报告 297,127,212 字节|同左|
|参考 GS renderer 临时工作区|末帧报告 16,758,527 字节|同左|

这些值仍未囊括所有 D3D 离屏图、back buffers、descriptor heaps、驱动和 CUDA 上下文；未测进程总峰值的地方就保留该限制。末帧高斯统计对应 `320×240`，教学场 4,096 个可见高斯产生 29,845 条 tile 引用；参考资产 740,014 个可见高斯产生 953,709 条引用。临时分配可能沿用之前较大尺寸申请的容量，因此不能只用末帧实际元素数反推分配字节。

体积、显式高斯与神经参数提供了不同的编辑入口和容量/计算交换。本课的数据只用于把这些交换成本具体化；它不是同一高质量商业场景的三路线公平竞赛。本轮硬件计数器分析按用户授权略过，event 时间不用于宣称某个硬件单元已被确定为瓶颈。

## 10. 动手与自测答案

从仓库根目录构建：

```powershell
& learning/sandbox/d3d12/neural-rendering/build.ps1
```

如果 G.5 输出已经生成，运行默认验收与交互窗口：

```powershell
& learning/sandbox/d3d12/neural-rendering/build/Release/g_demo.exe `
  --root learning/sandbox/d3d12/neural-rendering
& learning/sandbox/d3d12/neural-rendering/build/Release/g_demo.exe `
  --root learning/sandbox/d3d12/neural-rendering --interactive
```

按 `1/2/3/4` 切换网格、体积、高斯、NeRF 缓存；按 `R` 切换两套尺寸并重建资源。没有缓存输出时可以显式用 `--without-nerf` 验证其他路径，但这不算完整四模式验收；本轮最终记录使用完整四模式。

1. **共享内存为何还需要同步？** 因为内存可见性与生产者执行完成是独立问题；必须等待生产者对应的 Fence 值。
2. **颜色相同，Alpha 边缘为何偏暗？** 常见原因是预乘颜色又乘了一次 Alpha，或在线性/编码空间间重复转换。
3. **为什么不能用体积的期望深度给整团雾做硬遮挡？** 因为一个像素的体积贡献分布在整段射线上，单个代表深度丢失了前后分布。
4. **窗口 1 ms 的 NeRF 缓存传输是否意味着网络可 1000 FPS？** 不意味着。那一段没有执行网络推理，还排除了其他显示成本。
5. **本课已经把神经表示集成进 H 的完整引擎了吗？** 没有。当前是独立的 G 实验室与共享底层辅助代码，完整 H 集成仍需另行实施和验收。

商业引擎通常进一步使用每帧资源环、多队列调度、异步流式加载、动态图景与统一材质/光照体系。本课完整展示跨 API 契约和可验证的最小整合，不把单帧同步调度、固定相机缓存或教学高斯覆盖规则当作生产引擎方案。
