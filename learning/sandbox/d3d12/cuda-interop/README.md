# E.1–E.3 CUDA / D3D12 共享主线

E.1–E.3已完成：CUDA实例表、mesh0动态顶点副本、双向External Fence及1/2/3槽固定工作量基准。无CPU中间显式等待；初始化与最后排空单列。E.3实测多缓冲缩短整批时间，但混合档Nsight捕获没有观察到跨API GPU区间重叠，保留采集警告。

| 文件 | 职责 |
|---|---|
| src/instance_data.h、instance_update.cu | 80B二进制契约、每实例CUDA线程 |
| src/external.h/.cpp | LUID匹配、External Memory/Fence、NT句柄所有权 |
| src/raster.h/.cpp、shaders/instances.hlsl | D3D12根SRV、静态VB/IB、离屏光栅与每帧快照 |
| src/validate.h/.cpp | 独立T*M参考、像素中心重心覆盖、过期帧负对照 |
| src/interop_test.cpp | 初始化、24帧异步交接、最终排空和验收 |
| verify_e1.ps1 | 构建、Fence日志重放、memcheck、预览转换 |
| src/vertex_update.h/.cu | E.2仅位置写入、48B stride与64B哨兵 |
| src/static_audit.h/.cpp | 原始GPU VB/IB/材质图像与CPU材质元数据快照 |
| verify_e2.ps1 | E.2正常/过期帧注入、memcheck与预览 |
| src/buffer_bench.cpp、workload.h/.cu | E.3槽位调度、CUDA事件/D3D时间戳/NVTX、固定标量负载 |
| verify_e3.ps1、profile_e3.ps1 | 独立正确性/轮换顺序无分析器基准、Systems CUDA+DX12捕获 |
| analyze_e3.py/.ps1、audit_course.py | 统一时间线、槽位协议重放、输出一致性、图表与整章证据审计 |

工作目录为仓库根目录：

```powershell
& learning/sandbox/d3d12/cuda-interop/verify_e1.ps1
& learning/sandbox/d3d12/cuda-interop/verify_e2.ps1
& learning/sandbox/d3d12/cuda-interop/verify_e3.ps1
& learning/sandbox/d3d12/cuda-interop/profile_e3.ps1
& learning/sandbox/d3d12/cuda-interop/analyze_e3.ps1
python learning/sandbox/d3d12/cuda-interop/audit_course.py
# 已构建后的直接运行：
& learning/sandbox/d3d12/cuda-interop/build/Release/interop_test.exe `
  learning/sandbox/d3d12/gltf-scene/results/c04/trs.gltf `
  learning/sandbox/d3d12/cuda-interop/shaders/instances.hlsl `
  learning/sandbox/d3d12/cuda-interop/results/e1
```

构建复用`../gltf-scene/CMakeLists.txt`的可选`E_INTEROP=ON`目标，VS2022/C++17/UTF-8、CUDA sm_120，产物在本目录build/Release。CUDA13.3对CMake产生的`--cudart shared`有弃用警告，目前构建与验证通过；不修改其他课运行库设置。

输入复用C.4的trs.gltf，不复制Assimp/上传后端。结果直接写入results/e1；summary.json为实际读回统计，fences.csv为提交日志，replay.txt为独立协议重放，memcheck.txt为工具输出，frame-0/23.png为实际光栅图。图像是颜色诊断量化，未应用PT.10完整显示变换。

边界：正确性224×256、性能1024×1024离屏，无Present/VSync/深度；四实例位于测试平面，按draw顺序覆盖。预录allocator/list服务有限批次验证/基准，不是无限帧调度器；初始化/结束CPU等待仍存在。Debug Layer不保证识别所有跨API数据竞争，因此必须做代号/内容读回。E.3合成标量/像素ALU负载不代表真实角色模拟或完整PBR性能，也未测输入到显示延迟。

讲义：[E.1 实例数据与双向交接](../../../笔记/d3d12/E.1-实例数据与双向交接.md)。

E.2运行参数在三个原参数后追加`e2`或`e2-stale`；结果归results/e2/e2与e2-stale。后者在第7帧故意使用旧形变参数，应检出顶点和图像不匹配；不是执行真实数据竞争。详见[E.2动态缓存讲义](../../../笔记/d3d12/E.2-动态顶点缓存与写入边界.md)。

E.3可执行文件`build/Release/buffer_bench.exe`参数依次为model、shader、output、slots(1/2/3)、workload(cuda-heavy/graphics-heavy/balanced)、mode(validate/perf/profile)。性能每进程2预热+5测量，48帧固定子步、无逐帧图像读回；脚本三轮轮换槽位顺序。结果归results/e3：environment/input-hashes记录环境，timing.csv记录CPU/GPU间隔，frames.csv记录原始D3D ticks，fences.csv记录批次槽位协议；nsys报告与sqlite为独立混合档捕获。

分析脚本在build/analysis-env使用matplotlib3.10.7，首次运行按需安装；不改系统包。GPU基准与分析命令顺序运行，避免并行占GPU污染结果。E.3报告见[多缓冲时间线讲义](../../../笔记/d3d12/E.3-多缓冲时间线与性能验收.md)。results/e3/chapter-audit.json记录最后整章要求与证据。
