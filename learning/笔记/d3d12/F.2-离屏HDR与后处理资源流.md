# F.2 离屏HDR与全屏后处理资源流

目标：把场景颜色保存为可复用输入，证明恒等/灰度/曝光pass正确，再完成Resize。[工程](../../sandbox/d3d12/aa-reconstruction/README.md)、[资源模块](../../sandbox/d3d12/aa-reconstruction/src/gpu_resources.cpp)、[后处理模块](../../sandbox/d3d12/aa-reconstruction/src/post_chain.cpp)、[全屏shader](../../sandbox/d3d12/aa-reconstruction/shaders/display.hlsl)。

## 1. 为什么需要另一张颜色纹理

游戏引擎先画世界，再做曝光、抗锯齿、超分、UI，这些步骤并不都在几何PS里执行。若世界颜色直接写交换链，后续步骤会受限于显示尺寸和显示格式；若一边采样颜色、一边覆盖同一子资源，像素间不存在规定的先后次序，读到“新颜色还是旧颜色”也就没有正确契约。

先定义一个函数`B=P(A)`：A只读、B只写。下一个pass需要继续处理时写`A=Q(B)`，这就是ping-pong，两份物理资源交替承担逻辑角色。它与CPU指针换名不同，真正保证了每个dispatch/draw内部无非法反馈。

线性HDR输入采用RGBA16_FLOAT，每通道16位浮点，范围不限制在0..1；其意义是保存线性光量，不是因为“16位”就自动成为线性空间。纹理格式、颜色含义和显示传递函数必须分别约定。本课场景亮部可大于1，最终显示才使用Reinhard与sRGB；灰度和曝光操作在线性HDR中进行。

## 2. 资源创建与所有权

```cpp
HRESULT ID3D12Device::CreateCommittedResource(
  const D3D12_HEAP_PROPERTIES* pHeapProperties,
  D3D12_HEAP_FLAGS HeapFlags,
  const D3D12_RESOURCE_DESC* pDesc,
  D3D12_RESOURCE_STATES InitialResourceState,
  const D3D12_CLEAR_VALUE* pOptimizedClearValue,
  REFIID riidResource, void** ppvResource);
```

`pHeapProperties`选择DEFAULT/UPLOAD/READBACK等内存用途；`HeapFlags`是heap约束，本课NONE；`pDesc`描述维度、宽高、mip、格式、样本数和允许的用途；`InitialResourceState`是初始访问状态；`pOptimizedClearValue`是常用的清除值提示；`riidResource`请求资源接口；`ppvResource`接收引用计数对象。HRESULT失败时不得继续建立视图。本课通过ComPtr拥有资源，提交后用Fence确定可以释放的时机。

场景颜色允许RTV，后处理输出也允许UAV，因此可以接受全屏PS或计算着色器写入。RTV/SRV/UAV是访问描述符，不是像素数据的副本。建立SRV不会把纹理复制到另一块显存；也不会自动执行资源状态转换。

本课分配一个CPU-only RTV heap和shader-visible CBV/SRV/UAV heap。一个shader-visible descriptor被GPU引用期间不能被CPU改写成另一个纹理：描述符地址不变，而内容已经被换掉，会产生跨命令读错资源。PostChain为同一提交内的每次pass分配独立槽，只有上一帧Fence完成后`BeginFrame`才回收这些槽。

## 3. 全屏三角形的坐标推导

希望覆盖NDC盒子`[-1,1]²`，不需要额外VB。令三个UV为(0,0)、(2,0)、(0,2)，经过`clip.xy=uv*(2,-2)+(-1,1)`得到(-1,1)、(3,1)、(-1,-3)。这个大三角形包住视口；裁剪器与scissor限制实际写入区域。UV在屏幕内插值到0..1。

`SV_VertexID`提供0、1、2，shader按位构造三个UV；`DrawInstanced(3,1,0,0)`四个参数依次是每实例顶点数、实例数、起始顶点、起始实例。不存在“创建全屏三角形资源”的必需API，也不应把顶点ID当像素ID。

全屏PS用`inputColor.SampleLevel(linearClamp,uv,0)`读取，显式mip0；输入与输出同尺寸时像素中心对应源纹理中心。本课恒等模式输出RGB不变，alpha固定1；因此验收只宣称RGB恒等。灰度系数(0.2126,0.7152,0.0722)用于线性Rec.709/sRGB原色的亮度近似。曝光EV满足 `scale=2^EV`，所以加1档应使线性颜色乘2，而不是向8位显示值加常量。

## 4. 状态与执行顺序

```text
场景：color → RENDER_TARGET → Clear/Draw
后处理：color → PIXEL_SHADER_RESOURCE
         ping → RENDER_TARGET → Draw全屏三角形
第二步：ping → PIXEL_SHADER_RESOURCE
         pong → RENDER_TARGET → 灰度/曝光
显示：结果 → PIXEL_SHADER_RESOURCE
       backbuffer PRESENT → RENDER_TARGET → 编码/UI → PRESENT
```

`ResourceBarrier(NumBarriers,pBarriers)`的数量是数组元素数；每个TRANSITION条目包含资源、子资源、前状态、后状态。该API录制依赖，不能代替CPU等待Fence。只读的pixel/nonpixel访问可用组合状态；写RTV/UAV/CopyDest不能因为“下一步可能会读”就与读状态随意合并。

计算超分会覆盖命令列表的root signature、descriptor heap和PSO。后续全屏绘制必须重新绑定，而不能假定SDK调用前的状态被保留。资源对象由宿主持有；SDK借用指针不改变这个释放责任。

读回时不能直接Map DEFAULT纹理。本课用`GetCopyableFootprints`查询Footprint.Offset、RowPitch和总字节数，再复制到READBACK buffer。行pitch可能大于紧密行宽，逐行解码并转换成float4。Map的读取范围覆盖复制内容，Unmap的写范围为0；Fence完成前不能Map并读取结果。RGBA16F解码只恢复存储数值，不再执行sRGB变换。

## 5. Resize是资源生命周期事件

先等待所有引用旧尺寸资源的工作；释放旧BackBuffer引用；调用`ResizeBuffers`；重新获取新BackBuffer。重新创建离屏color/ping/pong，更新RTV/SRV、viewport和scissor。描述符索引不变不代表资源尺寸自动更新。F4以后还需废弃旧历史，因为相同UV/像素索引的解释已改变。

本课交换链是双缓冲，但验证循环每次等待GPU；这不等于已经实现多帧CPU/GPU重叠。商业Render Graph通常自动推导barrier、复用临时内存和管理帧槽，本课手动表达同样的读写依赖，便于检查。

## 6. 实测与练习答案

运行`f_lessons.exe suite`，输出写`results/f2/`。2026-10-22，640×360和512×288两种尺寸：恒等RGB最大误差0，曝光EV=1最大误差0，灰度最大绝对误差0.000717725（输出RGBA16F量化，阈值0.002）；两个真实Present、最终Debug warning/error为0。[原始报告](../../sandbox/d3d12/aa-reconstruction/results/f2/summary.json)。

练习：把输出资源误设为输入资源。答案：宿主应在录制前拒绝，本课`Display/Dispatch`有显式反馈检查；不能期待同一纹理同一子资源同时以SRV和RTV写入。把EV改为−1，线性颜色应减半；若显示值恰好也全部减半，检查是否漏了非线性色调映射/sRGB处理。Resize后沿用旧history为何错？因为采样格与对应关系失效，下一节将把它做成可执行的有效性契约。

依据：[CreateCommittedResource](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12device-createcommittedresource)、[资源Barrier](https://learn.microsoft.com/en-us/windows/win32/direct3d12/using-resource-barriers-to-synchronize-resource-states-in-direct3d-12)。
