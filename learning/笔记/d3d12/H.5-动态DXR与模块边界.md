# H.5：渲染器消费场景快照

2026-10-21。[共享工程](../../sandbox/d3d12/dynamic-character/README.md)、[架构契约](../../sandbox/d3d12/dynamic-character/ARCHITECTURE.md)。主要代码 `src/render/frame.h`、`src/render/dxr/renderer.cpp`、`src/app/extract_frame.h`。

## 为什么不能只更新顶点

把BLAS想成地图的空间索引：CUDA改变了顶点位置，但旧索引仍把三角形放在旧包围盒里，光线查询可能漏掉新位置。因而先蒙皮，再更新动态BLAS，再构建对应实例的TLAS，最后才追踪。角色整体位移属于实例变换，肢体形变属于BLAS输入几何，两层不可互相代替。

## 模块接口与数据所有权

```cpp
DxrRenderer(const Rig&, CpuScene, const RenderSettings&,
            const std::filesystem::path& shaders,
            const std::filesystem::path& energy);
RenderImage Render(const RenderFrame&, bool rebuild=false);
```

Rig借用且必须活得比renderer久；CpuScene按值传入后归后端所有；settings指定内部宽高、验证层、窗口、读回。shaders是编译后的DXIL目录，energy是PT材质能量表。PImpl让公共接口不泄漏D3D12/CUDA类型。RenderFrame包含相机、角色整体矩阵、骨骼world/palette、scene/light版本、spp、反弹数和历史控制，没有按键或Idle/Jump枚举。

当前Render同步完成一帧才返回，因此局部palette上传源在返回前有效；未来异步多帧时必须复制到后端帧槽并按Fence退役，不能保留上层vector的悬空引用。RenderImage只在验收启用CPU读回；交互显示直接使用GPU结果。版本号是更新契约，不是由渲染器猜测游戏状态。

## CUDA—D3D12交接

共用E章ExternalBuffer/ExternalFence，按LUID选择同一GPU。共享顶点缓存含静态与人物区间，初始化复制一次，CUDA随后只写人物区间。两条Fence单写者：ready由CUDA发信号，consumed由D3D发信号。第f帧CUDA等consumed=f，写顶点后signal ready=f+1；D3D等ready=f+1，读取与渲染完成后signal consumed=f+1。互操作Fence负责跨API执行依赖，D3D barrier负责其资源访问状态，两者不能互相替代。

底层调用为 `cudaWaitExternalSemaphoresAsync(const cudaExternalSemaphore_t*, const cudaExternalSemaphoreWaitParams*, unsigned int, cudaStream_t)`，参数依次是信号量数组、同长度等待值数组、数量、排队流。signal对应同样的数组结构但参数类型是SignalParams。它们排入流而非CPU等到完成；检查cudaError_t，最终同步还能暴露异步错误。Win32共享句柄、CUDA映射及COM资源由各自RAII封装回收，必须先退役GPU使用。详见[NVIDIA互操作API](https://docs.nvidia.com/cuda/cuda-runtime-api/cuda_runtime_api/group__CUDART__EXTRES__INTEROP.html)。

## BLAS更新与灯光

初建动态BLAS带ALLOW_UPDATE，后续在同一结果缓冲加PERFORM_UPDATE；静态装饰BLAS保持。scratch取初建/更新需求的较大者，不能假定初建空间一定足够。更新后插UAV barrier，再构建TLAS、发射光线。输入拓扑保持，不能随意在update里增加顶点数。[Microsoft build flags](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ne-d3d12-d3d12_raytracing_acceleration_structure_build_flags)。

灯光在程序中创建：y=9的18×8矩形，两发光三角形，RGB辐射值(8,7.5,6.5)，环境黑。面积光具有形状和能量，不需要下载“光源模型”。地面和一块金属测试面程序生成，树石来自Kenney；按最终节点变换后的实际高度规范化尺寸。人物材质明确重新设为不透明单面蓝/橙色，与原文件双面设置不同。

## 动手、实测、范围

先 `build.ps1`，再 `verify_h5.ps1`。三个姿势下BLAS更新/完整重建图像最大差0；光源强度翻倍后的线性辐射差0，全部灯关闭输出0；静态累积继续、曝光不重置。12帧、Fence15/15、Debug0。

当前复用PT积分器的几何法线着色，不支持平滑法线/法线贴图/切线、透明和完整双面材质。CUDA法线数据已验证，但尚未用于这条PT着色路径。单帧同步、每帧TLAS构建和部分资源分配是正确性基线，未声称完成商业渲染器的多帧并行或设备丢失恢复。

自测答案：只改TLAS不能反映手臂弯曲；只改VB不能保证旧BLAS命中正确；renderer无需知道角色的状态枚举。下一节处理动态帧不能直接累加的问题。
