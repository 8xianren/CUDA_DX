# G.2 CUDA 三维纹理体渲染与共享输出

本节目标：把 G.1 的积分器变成 GPU 的逐像素并行程序，理解 CUDA array、纹理对象、CPU 参考、输出缓冲和 D3D12 共享纹理之间的边界。

工程入口：[neural-rendering](../../sandbox/d3d12/neural-rendering/README.md)。核心文件是 [volume.h](../../sandbox/d3d12/neural-rendering/src/volume/volume.h)、[volume.cu](../../sandbox/d3d12/neural-rendering/src/volume/volume.cu)、[volume_cpu.cpp](../../sandbox/d3d12/neural-rendering/src/volume/volume_cpu.cpp)。源码定位：`VolumeRayMarch` 在 `volume.cu:16`；资源构造在第 75 行；公共 `Render` 在第 111 行；`volume_cpu.cpp:17` 是手写三线性参考。窗口、共享资源与 resize 由 G.10 的同一套集成程序验收，体积分器不拥有窗口。

## 1. 先分清两个维度的并行

每条射线内部，前一段的 `T` 会影响后一段，因此直接的前向积分是有顺序依赖的。不同像素的射线互不修改彼此状态，可以并行。

本课映射为：一个线程持有一个像素的 `C/T/t`，顺序走完这条射线；一个 block 是 `16×8` 个像素。类似屏幕空间 compute shader：线程组大小只是调度划分，不代表一个 block 对应体数据中的一个三维块。

```cpp
int x = blockIdx.x * blockDim.x + threadIdx.x;
int y = blockIdx.y * blockDim.y + threadIdx.y;
if (x >= width || y >= height) return;
```

最后一个 block 常覆盖部分屏幕外像素，因此边界判断是正确性要求。G.2 特意使用 `97×61`，两条边都不能被 block 尺寸整除。

## 2. 先定数据布局，再选择资源类型

宿主侧 `Field` 包含 `resolution=N` 和 `N³` 个 float。线性索引为

\[
\text{index}=((zN)+y)N+x.
\]

`x` 相邻时内存连续，每个体素保存一个非负密度值。体素中心的位置是 `(-1+2*(x+.5)/N, ...)`。这说明我们存储的是单元中心采样，不能把它误当盒边界端点采样，否则插值坐标会偏半个体素。

CUDA array 是适合纹理/表面访问的 CUDA 资源类型。它不是普通 `cudaMalloc` 返回的线性 `float*`，不能由用户自行推导物理偏移并解引用；内部排布由 CUDA 管理。纹理对象则是一个不透明句柄，把资源与采样规则关联起来。

可以类比 D3D12 的“资源 + SRV + sampler”，但 API 组织并非逐一完全相同。本课也没有声称 CUDA array 的内部排布与某个 D3D12 tiled texture 必然相同。

### 创建和上传的真实 API

本机 CUDA 13.3 的 `cuda_runtime_api.h` 第 5395、5635、9297 行分别给出以下声明：

```cpp
cudaError_t cudaMalloc3DArray(cudaArray_t* array,
    const cudaChannelFormatDesc* desc, cudaExtent extent, unsigned flags = 0);
cudaError_t cudaMemcpy3D(const cudaMemcpy3DParms* p);
cudaError_t cudaCreateTextureObject(cudaTextureObject_t* out,
    const cudaResourceDesc* resource, const cudaTextureDesc* sampler,
    const cudaResourceViewDesc* optionalView);
```

`cudaMalloc3DArray` 的 `array` 是输出句柄地址；`desc=cudaCreateChannelDesc<float>()` 表示一个 32 位浮点通道；`extent=(N,N,N)` 描述三维尺寸；此处 `flags=0`，因为只需要纹理读取，不需要 surface 写入或 sparse array。

`cudaMemcpy3DParms` 先全部清零，然后设置：

|字段|本课值|原因|
|---|---|---|
|`srcPtr.ptr`|宿主密度数组首地址|源是线性 CPU 内存|
|`srcPtr.pitch`|`N*sizeof(float)`|一行跨度以字节计|
|`srcPtr.xsize/ysize`|`N*sizeof(float)` / `N`|宿主行的逻辑字节宽度与高度|
|`dstArray`|刚分配的三维 array|目标是 array，`dstPtr` 不使用|
|`extent`|`(N,N,N)`|涉及 array 的复制宽度按 array 元素计|
|`kind`|`cudaMemcpyHostToDevice`|明确传输方向|
|`srcPos/dstPos`|全零|从源和目标起点复制|

不要把 `extent.width`、`pitch` 和后续二维纹理复制的 byte width 混为一个单位。混用通常造成越界、图像剪切或错行。

`cudaCreateTextureObject` 的资源描述符设置 `resType=cudaResourceTypeArray`，并指定该 array；采样描述符设置归一化坐标、`cudaFilterModeLinear`、`cudaReadModeElementType`、三个轴 `cudaAddressModeClamp`；可选 view 指针为空，使用资源原本的浮点格式。

官方入口：[CUDA Texture Object API](https://docs.nvidia.com/cuda/cuda-runtime-api/group__CUDART__TEXTURE__OBJECT.html)、[CUDA Memory API](https://docs.nvidia.com/cuda/cuda-runtime-api/group__CUDART__MEMORY.html)。网页当前版本可能高于本机，因此签名和实际构建仍以本机 13.3 头文件为准。

## 3. 从世界坐标推导三线性采样

盒范围是 `[-1,1]`，因此世界坐标转归一化纹理坐标：

\[
u=(x+1)/2,\quad v=(y+1)/2,\quad w=(z+1)/2.
\]

纹理单元将每轴坐标对应到体素中心网格。CPU 的等价浮点参考坐标是

\[
q_x=uN-\tfrac12,\qquad i_x=\lfloor q_x\rfloor,\quad f_x=q_x-i_x.
\]

每轴取低/高两个邻点，三轴组合共有八个邻点；权重是三个一维权重的乘积。例如 `(i_x+1,i_y,i_z+1)` 的权重为 `f_x*(1-f_y)*f_z`。边界邻点索引按 clamp 规则限制到 `[0,N-1]`。

GPU 核心调用：

```cpp
float sigma = tex3D<float>(texture, u, v, w);
```

该调用输入纹理对象和三个坐标，返回插值后的 float，不是密度数组地址。硬件线性过滤的插值权重有有限精度；CPU 使用普通 float 算术进行八邻点加权，因此不应预设逐位相同。我们用明确误差阈值比较，并在 G.3 的跳空比较中单独要求 GPU 两条采样路径一致。

## 4. 相机射线、积分和 transfer function

像素中心为 `(x+.5,y+.5)`。垂直视场角的半角正切记作 `h`，宽高比为 `a`。在距离相机 1 的成像平面上：

\[
s_x=(2(x+.5)/W-1)ah,\qquad
s_y=(1-2(y+.5)/H)h.
\]

用相机三个世界基向量换基：`d=normalize(forward+sx*right+sy*up)`。像素行向下导致 y 前面的符号翻转。`Camera` 要求这些基向量由调用者提供为正交单位基；不是把任意 D3D View 矩阵列直接照抄进来。

射线与盒求交后，线程逐段读取密度、计算 `alpha=-expm1(-sigma*dt)`，从近到远累加。**Transfer function（传递函数）** 是把体数据的标量/属性变成显示颜色和光学属性的映射。本课密度直接决定消光，颜色由位置映射为 RGB。医学体绘制常把 CT 标量经过传递函数同时映射成颜色与密度；不能把这种后处理标定和物理测量量混为一谈。

当 `T<termination` 时停止。这里是 `0.001`，意味着后续所有非负颜色贡献的总权重至多剩约千分之一；完整误差界还依赖颜色范围，HDR 的高亮源不能沿用同一个绝对亮度误差判断。阈值为 0 时关闭提前终止。

## 5. API、所有权与同步契约

```cpp
void Volume::Render(float4* rgbaDevice,
    const Camera& camera, const RenderOptions& options,
    cudaStream_t stream = nullptr,
    float* depthDevice = nullptr,
    const float* meshRayDistance = nullptr,
    PixelStats* statsDevice = nullptr) const;
```

`Volume` 独占三维 array、texture object 和 occupancy grid。CPU `Field` 在构造时完成上传后可销毁；构造函数使用局部智能指针，后续 CUDA 创建失败时会释放前面已成功创建的资源。对象禁止浅拷贝，避免多个对象重复销毁同一句柄。

`rgbaDevice` 是调用方拥有的 `W*H` 个连续 float4，每像素线性预乘 RGBA。`depthDevice` 可空；非空时写入累计 Alpha 首次达到 0.5 的世界射线距离，无达到点为正无穷。它只是观察体积位置的代表深度，不能把雾当成这个位置的一张不透明面。

`meshRayDistance` 可空；非空时输入每像素最近不透明网格的世界射线距离，积分远端取 `min(boxExit,meshDistance)`。如果输入是 D3D 的 NDC depth、逆深度或 camera-space Z，需要调用方先转换，不能直接传入。G.10 对网格的 view Z 除以相机射线方向的 view Z 分量，得到这里需要的世界距离。

`statsDevice` 可空，非空时每像素写采样次数、跳空步数、盒命中标志和提前终止标志。它不会影响其他像素，不需要原子加法；宿主在 kernel 完成后统一求和。

`stream` 决定入队顺序。`Render` 启动 kernel 后检查 `cudaGetLastError()`，但不执行 `cudaDeviceSynchronize()`。因此返回只表示启动阶段没有立即失败；读取输出、释放缓冲、销毁 `Volume` 之前，调用方必须等待相应 stream/event/fence，并检查异步错误。验收程序用 `cudaDeviceSynchronize` 和同步读回获得清晰故障位置；集成窗口使用外部 Fence，不把整个 GPU 每帧强制清空。

销毁顺序是先 texture object，再 array，最后 occupancy allocation。错误路径抛出包含 CUDA 错误文本的 `runtime_error`；测试入口捕获它并返回非零退出码，不静默继续展示旧帧。

## 6. CUDA 输出怎样进入 D3D12

模块化边界如下：

```text
Volume拥有三维密度资源
    ↓ Render（调用方stream）
调用方拥有的线性float4输出
    ↓ CUDA device-to-device copy
D3D12共享二维纹理的CUDA array映射
    ↓ CUDA signal外部Fence；D3D12 queue wait
全屏三角形采样SRV并合成背景
```

共享纹理不能因为“共享”二字就强行当作线性 `float4*`。本课通过 CUDA 映射得到 array 后，执行 `cudaMemcpy2DToArrayAsync`；这是 GPU 内部的复制，没有经过 CPU 图像读回，但仍有复制成本。共享资源由 G.10 的集成层创建、导入、维护状态与生命周期，体渲染器只接收明确的输出缓冲。

窗口 resize 时，先等 CUDA 和 D3D12 对旧纹理的使用结束，再释放其 CUDA 映射/导入句柄并重建 D3D12 texture、SRV 和输出尺寸。仅改 `width/height`、沿用旧资源会导致越界或描述符指向失效对象。G.2 的核心验证不把这一集成验收伪装成自己独立完成；最终共享纹理、窗口切换与 resize 的实测记录在 G.10。

## 7. 动手、误差和 Sanitizer

从仓库根目录运行：

```powershell
& learning/sandbox/d3d12/neural-rendering/tests/volume/verify-volume.ps1 -SkipProfiler
```

`-SkipProfiler` 对应 2026-10-22 用户授权本轮跳过硬件计数器分析；它不会跳过 G.2 的正确性与 Sanitizer。完整结果在 [core_validation.json](../../sandbox/d3d12/neural-rendering/results/g2/core_validation.json)。

|检查|本机结果|
|---|---|
|GPU / 架构|RTX 5070 / `sm_120`|
|三维场|128³ float，世界盒 `[-1,1]^3`|
|小图 CPU/GPU|97×61，步长 1/128|
|RGBA RMSE|2.9041756574e-6|
|最大绝对差|5.36441802979e-5，要求 `<5e-4`|
|重复 GPU 渲染|最大差 0|
|跳空开关|最大差 0|
|抖动 + 跳空开关|最大差 0|
|前方网格遮挡|最大 Alpha 0|
|后方网格|与无遮挡结果一致|
|相机在盒内 / 背向盒|CPU/GPU 对照通过 / 全透明|
|33³ 非整除网格|跳空开关一致|
|负密度、错误数据长度、零步长|3 项均明确拒绝|

Sanitizer 运行命令由验证脚本保存，分别使用 `--tool memcheck --leak-check full` 和 `--tool synccheck`。实测 [memcheck 日志](../../sandbox/d3d12/neural-rendering/results/g2/sanitizer_memcheck.log) 为 `0 errors`、`0 bytes leaked`；[synccheck 日志](../../sandbox/d3d12/neural-rendering/results/g2/sanitizer_synccheck.log) 为 `0 errors`。

Memcheck 检查本次执行中的越界、未对齐访问和泄漏；Synccheck 检查同步原语使用。本 kernel 没有 block 共享写入或 barrier，因此同步检查结果不能被夸大成“所有未来异步集成必定正确”。G.10 的跨 API 队列同步仍需单独验证。[官方 Compute Sanitizer 文档](https://docs.nvidia.com/compute-sanitizer/ComputeSanitizer/index.html)

## 8. 自测与答案

1. **GPU 与 CPU 相差 5e-5 是否必然是数据竞争？** 不是。这里是硬件纹理插值与 CPU 浮点插值的有限精度差异；先检查重复性、误差界、坐标和数据布局，再归因。
2. **为什么共享纹理还要一次 device-to-device copy？** 当前 render 核心的公共输出是线性缓冲，而共享纹理被映射为 array。可以再设计 surface 输出变体，但那是另一个明确的接口与性能选择。
3. **`Render` 返回后能马上销毁场吗？** 不能。启动是异步的，必须保证最后一个使用该纹理对象的 GPU 工作已经完成。

引擎中会进一步使用帧资源环、异步 compute、动态分辨率和更丰富的体积表示。本课保留相同的资源/同步机制，但先把场、积分器、互操作与显示分为独立职责，方便下一节可靠地测量采样成本。
