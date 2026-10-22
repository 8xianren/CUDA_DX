# G.1–G.10：体渲染、NeRF 与三维高斯实验室

[D3D12程序索引](../README.md) · [课程总纲](../../../学习计划.md) · [进度](../../../进度.md)

本课复用 C/D 的设备与资源层、E 的 LUID/External Fence、F 的纹理工具，新增独立的体渲染、NeRF、3DGS 模块。G 窗口与 H 人物路径追踪应用分开；本课不宣称已经给 H 加入神经场景或达到商业引擎质量。

2026-10-22 本机 RTX 5070 / sm_120、CUDA 13.3 验收。G.3/G.8 的 Nsight Compute 因 `ERR_NVGPUCTRPERM` 无法读取硬件计数器；学习者明确批准本轮跳过此项，保留真实计时、误差和失败记录。其他验收继续执行。

## 课程与文件职责

|课节|实现与验证|讲义|
|---|---|---|
|G.1|`src/volume/volume_cpu.cpp`、逐射线权重与步长收敛|[发射吸收方程](../../../笔记/d3d12/G.1-发射吸收体渲染方程.md)|
|G.2|`src/volume/volume.cu`、`src/interop/`、CPU/GPU与resize|[三维纹理与共享输出](../../../笔记/d3d12/G.2-CUDA三维纹理体渲染与共享输出.md)|
|G.3|`tests/volume/`、六组步长/跳空统计|[质量与性能](../../../笔记/d3d12/G.3-体渲染步长跳空与性能实测.md)|
|G.4|`python/nerf/camera.py,fields.py,rendering.py,train.py`|[NeRF数据与表示](../../../笔记/d3d12/G.4-NeRF的数据与表示.md)|
|G.5|`python/nerf/benchmark.py`、真实训练网络的网格烘焙|[NeRF实时化路径](../../../笔记/d3d12/G.5-NeRF采样与实时化路径.md)|
|G.6|`src/gaussian/projection_math.cuh`、CPU投影参考|[高斯投影推导](../../../笔记/d3d12/G.6-高斯数据与投影推导.md)|
|G.7|`src/gaussian/gaussian.cu` 的 CUB scan、duplicate、stable radix sort|[分桶与排序](../../../笔记/d3d12/G.7-分桶前缀和与稳定排序.md)|
|G.8|同一 CUDA 模块的 tile splat、`tests/gaussian/`|[Tile光栅](../../../笔记/d3d12/G.8-Tile光栅与共享内存.md)|
|G.9|`python/assets/`、严格 PLY/版本化 GSBIN、下载与坏输入测试|[训练与资产](../../../笔记/d3d12/G.9-训练系统与资产格式.md)|
|G.10|`src/app/`、`shaders/passes.hlsl`、共享纹理/网格遮挡/四视图|[集成与同步](../../../笔记/d3d12/G.10-表示集成与跨API同步.md)|

`RadiancePass` 只借用每帧设备缓冲；体数据对象拥有 CUDA array/texture；高斯模块拥有投影/排序临时区；图形层拥有 PSO/描述符；应用拥有窗口、共享纹理与双向交接的两条 Fence。输入仅负责选择视图与尺寸，不进入积分器。[具体契约](ARCHITECTURE.md)。

## 构建和复现

以下 PowerShell 命令的**工作目录均为本目录** `learning/sandbox/d3d12/neural-rendering`。要求 VS2022 C++、CUDA Toolkit 13.3、DXC；根构建固定 `CMAKE_CUDA_ARCHITECTURES=120`。

```powershell
./build.ps1
# 安装固定版本官方CUDA版PyTorch到本课.venv；可传 -Python 指定Python3.13
./python/nerf/setup.ps1
# 真实训练、两种推理比较、640x360和320x240固定相机输出
./python/nerf/run.ps1
# 严格下载/转换公开参考训练资产；数据留在downloads，不提交仓库
python ./python/assets/fetch_reference.py
python ./python/assets/convert_ply.py
python ./tests/assets/test_import.py
# 配对相机的真实火车预览（另一套固定资产，原坐标，无bbox归一化）
python ./python/assets/reference_camera.py
./tests/assets/reference_build.ps1
python ./python/assets/reference_preview.py
# 独立CUDA验证，不依赖窗口
./tests/volume/verify-volume.ps1 -SkipProfiler
./tests/gaussian/verify.ps1 -Build -Sanitizer
# 四种视图、真实共享texture、双Fence、resize、数值对照
./build/Release/g_demo.exe --root .
./build/Release/g_demo.exe --root . --asset ./downloads/reference/train-7000.gsbin
# 无调试层，重复采样；CUDA event含host launch gaps，并非纯kernel active time
./build/Release/g_demo.exe --root . --performance
# 同一窗口按1网格、2体渲染、3高斯、4缓存NeRF；R切换已导出的两种尺寸
./build/Release/g_demo.exe --root . --interactive
```

若只复习体/高斯，可先运行 `g_demo.exe --root . --without-nerf`；这不是完整 G.10 验收命令。缓存 NeRF 要先执行 `run.ps1`。窗口用 R 重建真实交换链、共享 texture、CUDA 映射和描述符；不支持任意拖动尺寸，因为 NeRF 文件明确绑定固定相机，不静默拉伸成另一台相机。

`build/` 保存 EXE、库、DXIL；`results/g1`–`g10` 按节保存报告。JSON/CSV、工具日志、源码及 SVG 进入仓库；浮点图、检查点、下载资产、PNG/PPM 和性能工具二进制报告在本地生成。完整性汇总见 [验收报告](results/verification/summary.json)。

## 实测应怎样读

G.1 的权重/收敛、G.2 的 CPU/GPU 差、G.4 的训练误差、G.5 的烘焙误差、G.8 的 splat 参考差、G.10 的合成差是不同问题，不能混成一个“画质分数”。NeRF 的 app CUDA event 只覆盖缓存上传和资源转换，真正网络/网格推理成本在 G.5 报告；没有把缓存拷贝时间当成 NeRF 实时帧率。

体与 NeRF 共用发射吸收合成的机制；高斯采用中心深度排序与二维椭圆近似。网格深度为正 camera-Z，体积分使用射线距离，桥接显式换算。高斯以中心深度裁切是近似；本课不宣称能处理所有相互穿插的透明体。

真实 Train 资产由公开集合提供，来源声明使用 GraphDeco 方法训练；本机完成下载、字段校验、转换和渲染，没有在本机重新训练其 7000 次迭代。原始下载 URL、revision、SHA256、数量和字段统计保存在 [来源记录](results/g9/provenance.json) 与 [导入记录](results/g9/import.json)。

另有完整 667,872 高斯与其配对 camera0 的 [真实相机预览](tests/assets/reference_README.md)。它和 741,883 高斯的主导入资产分别保留；不能给其中一个场景套用另一个下载文件的哈希、数量或相机。
