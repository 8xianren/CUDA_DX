# PT.7 路径吞吐量参考实验

保留首课CPU球腔基准，并已完成真实glTF盒腔的DXR多反弹、RGB beta与NEE/MIS状态验证。俄罗斯轮盘赌与存活补偿也已完成并验证；PT.7限定盒腔范围完成，下一课PT.8。GPU设备/资源/提交复用C/D及PT.6后端。

|文件|职责|
|---|---|
|throughput_math.h|向量、局部半球采样、球面间解析求交和闭式参考；复用../pt06-mis/mis_math.h的PCG|
|path_loop.h|RGB路径状态、发光累加、吞吐量递推；两个故意错误分支供反例验证|
|throughput_test.cu|多seed/深度/解析测试，逐路径记录；纯CPU执行|
|verify.ps1|共享build.ps1初始化VS2022、nvcc -arch=sm_120构建和运行|

从仓库根运行（脚本可从其他工作目录调用）：

```powershell
& ./learning/sandbox/path_tracing/pt07-throughput/verify.ps1
```

依赖现有CUDA Toolkit/VS2022。构建工作目录固定为本课，exe在本课目录；没有CUDA kernel，不报告GPU性能或DXR验证结果。

所有结果直接写入本课`results/`：build.txt、run.txt、summary.csv（每深度/通道/方法均值、参考和seed均值标准误）、depths.csv（存活数与抵达时平均beta）、trace.csv（一条均匀采样路径的完整更新顺序）。无RR，所以各深度存活数均65536。SE反映8个seed均值的变化，不是像素方差或严格置信区间。

2026-10-21运行PASS：4194304段球面传播，最大几何残差2.66e-15、余弦路径解析误差1.67e-16。K8红通道正确解析.247480576，均匀采样.247298947349±SE .000657246230099；漏PDF错误.110559590680、错误发光顺序.148488345600，两个反例均成功检出。黑反射材质仍保留发光测试PASS。

[讲义：路径吞吐量与多反弹展开](../../../笔记/path_tracing/PT.7-路径吞吐量与多反弹展开.md)。以上为首课CPU基准；后续GPU实验见下。


## DXR多反弹与MIS状态（2026-10-21）

- `make_box.py`：六面闭合glTF资产，生成至results/gpu。
- `gpu_path.hlsl`：RayGen路径循环、RGB吞吐量、NEE/BSDF命中Power MIS；mode2故意重复计数。
- `gpu_path.h`：64B配置与128B逐顶点诊断记录（RR课程从112B扩展）。
- `gpu_path_reference.h`：独立double局部方程、实际方向解析求交、权重/PDF/累计验证。
- `gpu_path_test.cpp`：导入、共享GPU后端、8seed统计、K0/K1/rho0/Le0变体与错误反例。
- `verify_gpu.ps1`：VS2022/CMake/DXC构建、Python资产生成、Node Validator、GPU运行。

从仓库根运行（脚本内部路径不依赖调用工作目录）：

```powershell
& ./learning/sandbox/path_tracing/pt07-throughput/verify_gpu.ps1
```

依赖沿用PT.6/C.6（先安装gltf-scene/validation的npm依赖）。CMake构建在gltf-scene/build，exe在本课build/Release；结果写results/gpu：run.txt、seed_metrics.csv、path0.csv、depths.csv、box.gltf/bin、path.dxil和Validator报告。没有新渲染窗口或图像；每个RayGen是一条从盒心出发的独立路径样本。

RTX5070：890112顶点、1330943次TraceRay，CPU方程最大差2.56e-6、t最大差6.05e-7，Fence29/29、Debug0、Validator0/0。红通道MIS .2474783对参考.2474806；不加权重复计数.3931682。rho0仍发光、Le0全黑及K0/K1通过。边缘有2e-6尺度的盒子专用数值修正，不能当通用网格鲁棒偏移。没有性能计时。

PT.6与PT.7共用gltf-scene/src/ray_buffer_dispatch.{h,cpp}，PT.6两场景回归通过。[本课讲义](../../../笔记/path_tracing/PT.7-DXR多反弹与MIS状态.md)。本段为GPU接入课历史结果，RR完成情况见下。


## 俄罗斯轮盘赌（2026-10-21）

- 原`gpu_path.hlsl`新增独立RR随机流、开始深度/存活上下限、正确与漏补偿模式；默认关闭保留前课结果。
- `gpu_path_dispatch.cpp`：两种GPU验收共用Run与配置检查；仍复用C/D提交和资源层。
- `gpu_rr_test.cpp`：16seed开关/错误模式、配对均值SE、每深度存活与beta统计，概率1/上下限/零beta边界。
- 原`gpu_path_reference.h`扩展为检查实际RR随机数、生死、补偿与未访问尾槽。
- `verify_rr.ps1`：构建、DXC、复用glTF、Validator和RTX5070运行。

仓库根运行：

```powershell
& ./learning/sandbox/path_tracing/pt07-throughput/verify_rr.ps1
```

新增产物全在results/rr，资产复用results/gpu/box.gltf；exe为build/Release/gpu_rr_test.exe。summary.csv/seed_metrics.csv给均值SE和平均散射段/TraceRay次数，depths.csv区分全体平均beta与幸存者平均beta，decisions.csv记录前4条路径的s/u/生死。记录现为128B，必须重新编译宿主和shader，不能混用前课旧DXIL。

K16、每模式16seed×4096路径：关闭/正确/漏补偿的红均值.24983913/.25024420/.20726337；正确减关闭的配对差.00040507、SE .00043975。平均实际散射段16→2.54414，平均TraceRay30.3351→6.50003。含边界共1563459活顶点、2811451TraceRay，方程最大差3.81e-7、t差5.83e-7，Fence54/54、Debug0、Validator0/0。原verify_gpu.ps1回归PASS。没有GPU计时，有限K和盒棱边数值近似仍存在。

[讲义：俄罗斯轮盘赌与存活补偿](../../../笔记/path_tracing/PT.7-俄罗斯轮盘赌与存活补偿.md)。PT.7当前范围验收完成，下一课PT.8；一般材质/折射/通用网格偏移与交互性能不在当前结论内。
