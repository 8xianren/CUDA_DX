# E.1：CUDA实例数据与双向交接

2026-10-21，代码见[共享主线](../../sandbox/d3d12/cuda-interop/README.md)，[结果](../../sandbox/d3d12/cuda-interop/results/e1/summary.json)。本课不是CUDA重画网格：glTF顶点/索引继续属于D3D12，CUDA只生成实例世界矩阵和颜色。

## 从问题推导资源边界

同一块网格可以出现在多个位置：局部顶点p不变，第i个对象使用世界矩阵M_i，使p_world=M_i p。这与引擎的实例数据表相同。若移动对象时重写所有顶点，会重复做本来只需每实例一次的数据更新。本课把静态VB/IB和动态实例表分开。

约定列向量、行优先矩阵内存。先保留基准世界变换M，再施加世界平移T(d)：M_f=T(d)M。设M末行为(0,0,0,1)，展开矩阵乘积可得：平移只给M的第0行第3列加dx，第1行第3列加dy；不是随意挑选数组下标。故CUDA改world[3]/world[7]，CPU参考实际计算T*M，两个实现独立验证。每帧都从base重算，避免+=积累误差和状态依赖。

SharedInstance为world[16]+color[4]，80字节；world偏移0，color偏移64。4实例逻辑范围320字节。HLSL使用row_major float4x4并以mul(matrix,columnVector)消费；内存行优先与数学列向量是两个独立约定。RGB用于显示，color.w用frame+1保存代号；它是审计字段，不是透明度。本课不启用混合。kernel每线程独占一实例，count边界保护，无跨线程归约或原子操作。

## 共享与同步是两套契约

共享内存解决“两个API如何指向同一分配”；Fence解决“谁此刻可以读写”。CUDA指针、D3D GPU虚拟地址和Windows HANDLE是不同名字，不能相互强转。

首先比较ID3D12Device::GetAdapterLuid与cudaDeviceProp.luid；CUDA设备0和DXGI枚举0没有必然对应关系。本课拒绝多节点设备，并检查luidDeviceNodeMask=1。实测RTX5070、sm_120匹配。

D3D12创建DEFAULT committed buffer：heap flag SHARED，初始COMMON。CreateSharedHandle产生NT句柄；导入描述为D3D12Resource、size=GetResourceAllocationInfo.SizeInBytes、flags=cudaExternalMemoryDedicated。实测逻辑320B但分配65536B。导入的是分配，映射的是offset=0,size=320的有效数据范围，不能把两者混用，也不允许kernel访问padding。

核心原型（省略调用约定宏；已核对本机13.3头文件）：

```cpp
cudaError_t cudaImportExternalMemory(
    cudaExternalMemory_t* extMem_out,
    const cudaExternalMemoryHandleDesc* memHandleDesc);
cudaError_t cudaExternalMemoryGetMappedBuffer(
    void** devPtr, cudaExternalMemory_t extMem,
    const cudaExternalMemoryBufferDesc* bufferDesc);
cudaError_t cudaImportExternalSemaphore(
    cudaExternalSemaphore_t* extSem_out,
    const cudaExternalSemaphoreHandleDesc* semHandleDesc);
```

第一个API输出CUDA外部内存对象，输入句柄描述；第二个输出设备指针、输入已导入对象及offset/size/flags映射描述；第三个输出CUDA同步对象，输入D3D12Fence类型及其NT句柄。所有描述先清零，未使用字段与flags保持0。每个返回值必须检查，导入成功但映射失败时销毁已导入对象。

CUDA不接管这里的NT句柄；导入返回后由RAII CloseHandle。释放顺序为先完成GPU工作，再cudaFree映射指针、cudaDestroyExternalMemory，最后释放D3D资源。Fence先销毁CUDA导入对象，再释放COM Fence。释放不是同步机制。

## 从读写冲突推导两条时间线

定义C_f为CUDA生成第f帧，G_f为D3D12读取第f帧。单缓冲必须满足：C_f→G_f（读之前写完），G_f→C_(f+1)（覆盖之前读完）。因此依赖链是C0→G0→C1→G1；它正确但不能使这两段重叠。

两条Fence各自只有一个写者：ready由CUDA signal，consumed由D3D队列signal。f从0开始，完成第f帧设置f+1，初值0意味着尚无帧。调度为：

```text
CUDA: 等consumed>=f（f=0跳过） → kernel(f) → signal ready=f+1
D3D:  等ready>=f+1 → 读SRV/绘制/快照 → signal consumed=f+1
```

必须先把对应signal操作提交，再提交另一API的wait；不要求signal已在GPU完成。我们的CPU按f顺序提交，上一帧D3D signal先入队，本帧CUDA wait随后入队；本帧CUDA signal先入队，本帧D3D wait随后入队。不把CPU ID3D12Fence::Signal当GPU完成通知。

```cpp
cudaError_t cudaWaitExternalSemaphoresAsync(
    const cudaExternalSemaphore_t* extSemArray,
    const cudaExternalSemaphoreWaitParams* paramsArray,
    unsigned int numExtSems, cudaStream_t stream);
cudaError_t cudaSignalExternalSemaphoresAsync(
    const cudaExternalSemaphore_t* extSemArray,
    const cudaExternalSemaphoreSignalParams* paramsArray,
    unsigned int numExtSems, cudaStream_t stream);
HRESULT ID3D12CommandQueue::Wait(ID3D12Fence* pFence, UINT64 Value);
HRESULT ID3D12CommandQueue::Signal(ID3D12Fence* pFence, UINT64 Value);
```

CUDA前两项是同步对象数组与一一对应参数数组；numExtSems=1，params.fence.value指定阈值/新值，stream是同一nonblocking CUDA流。wait之后的kernel受它约束，signal排在kernel之后。D3D参数是共享Fence对象与64位值；Queue::Wait把等待排入GPU队列，CPU立即继续。Queue::Signal排在draw之后。与SetEventOnCompletion+WaitForSingleObject的CPU阻塞完全不同。

COMMON→NON_PIXEL_SHADER_RESOURCE→COPY_SOURCE→COMMON由D3D命令列表记录。vertex shader读实例SRV，故NON_PIXEL；COPY_SOURCE仅为了本课诊断快照。Barrier管理D3D访问状态，外部Fence管理两API执行先后；二者不能互相替代。COMMON是本课统一交接点，并不表示“GPU已空闲”。

## 真实绘制和资源寿命

根签名b0是256B对齐的相机CBV，t0是根SRV，b1是单个uint对象编号。SetGraphicsRootShaderResourceView(1,address)的1是根参数序号；address来自共享D3D资源。它不是描述符堆偏移；根SRV不携带显式结构stride，shader类型定义80B布局。DrawIndexedInstanced(indexCount,1,firstIndex,firstVertex,0)复用同一VB/IB，用每draw的objectIndex选择矩阵/颜色。

为了先隔离同步正确性，本课预录24个独立allocator/list，各保留自己的读回资源；24帧全提交之后只做最后排空。不能在GPU执行期间reset allocator；命令列表、资源、根签名、PSO、RTV必须一直存活。共享离屏目标只由同一DIRECT队列访问，依次清屏/画/拷贝/恢复，故目标不需24份。

初始化有D3D上传等待和CUDA基准上传等待；结束有D3D Fence排空与CUDA异步错误检查。只有循环里的中间CPU等待为0，不声称整个程序没有CPU等待，也不声称runtime调用耗时为0。E.3将测时间与重叠。当前24份资源是有界验证批次，不是生产无限帧调度器。

失败处理：提交前异常正常回收；提交开始后若发生失败，在资源作用域内捕获并明确退出进程，避免先栈展开释放GPU仍引用的数据，或等待永不发生的signal。生产引擎应有设备丢失/重建路径，本课不模拟完整恢复。

## 本机验收与边界

24帧×4实例；1920个float字段最大误差0；1376256个像素检查、67602个覆盖像素、0不匹配、0边缘排除。CPU参考用像素中心和重心坐标独立判断三角形覆盖，按提交顺序选择最后命中；窄边界容差仅处理光栅量化/top-left差异，本次没有触发。

ready=24、consumed=24；fences.csv独立重放24条链通过；23次错误上一帧参考全部拒绝。Debug warning/error=0。compute-sanitizer memcheck：0错误、0字节泄漏。这证明本例的布局、数据代号和同步结果，不能证明所有跨API数据竞争都会被Debug Layer捕获。

显示使用实际glTF平面网格和无深度诊断，保存frame-0/23.png。没有窗口Present/VSync。没有改动原始glTF网格、IB或材质；本课只取实例RGB并不重新讲PBR。商业引擎通常将实例更新接入GPU Scene/渲染图并复用帧资源；本课把所有权和时间线显式展开，相同底层约束是“消费者完成前不能覆盖”。

## 自测与答案

1. 共享HANDLE是否意味着CUDA写完？不是，它只开放资源身份；完成顺序由Fence表达。
2. 为什么只等ready还不够？D3D可能仍读旧帧，CUDA覆盖会产生跨帧竞争；反向consumed约束必须存在。
3. CPU零中间等待是否意味着CUDA/图形并行？不是，单缓冲依赖链仍串行；E.3增加独立槽位后才有重叠机会，是否重叠须实测。

下一节E.2保持静态VB/IB/材质，增加有明确写入范围与stride的动态顶点缓存；不把所有资产都导入CUDA。

资料：[NVIDIA外部资源互操作](https://docs.nvidia.com/cuda/cuda-programming-guide/04-special-topics/graphics-interop.html#direct3d-interoperability)、[Microsoft Queue::Wait](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12commandqueue-wait)。API原型另核对本机CUDA13.3 include/cuda_runtime_api.h的3304、3359、3597、3693、3769行。
