# G.5 NeRF 采样与实时化路径：先把成本拆开，再验证一种真正的加速

[共享工程](../../sandbox/d3d12/neural-rendering/README.md) · [G.4](G.4-NeRF的数据与表示.md) · [场表示](../../sandbox/d3d12/neural-rendering/python/nerf/fields.py) · [评测导出](../../sandbox/d3d12/neural-rendering/python/nerf/benchmark.py)

## 1. 问题从工作量开始

给一张 W×H 图，每条射线 S 个样本，朴素 NeRF 要求大约 `W*H*S` 次场查询。每次查询不只是一个纹理读取，而是位置编码、若干 MLP 层、密度与颜色解码。渲染还包括射线/盒求交、采样位置生成、透射率 scan、权重归约，以及图形 API 交接。只说“GPU 加速了 NeRF”没有定位任何一项成本。

游戏开发类比：场查询像一个非常贵的材质，采样策略像决定在哪些位置调用材质；把材质烘焙为纹理是第三件事。减少调用次数、减少每次调用成本、缓存静态结果可以组合，但代价与误差来源不同。

本课完成一个可重复的**训练后推理加速**：从 G.4 已训练 MLP 查询一张 64³ 系数网格，推理时三线性采样网格代替 MLP。训练仍用同一套 MLP，因此训练时间不会凭空缩短；额外烘焙时间和新增表示体积都计入报告。不是 Instant-NGP 实现，也不把一个缓存方案冒充完整神经渲染系统。

## 2. 从误差约束理解采样策略

G.4 等距采样把相同预算花在空处和表面附近。由 `w_i=T_i(1-exp(-sigma_i delta_i))` 可以看出：无密度区域 alpha 小，已被前方挡住处 T 小，都很难贡献最终颜色。因此可把计算集中到预期贡献大的位置，但必须处理估计偏差。

**分层采样（stratified sampling）**：每个等长区间随机取一点。每段仍有代表，抖动将固定网格条纹变成可平均的噪声；它不自动减少样本数。本课训练启用这一项，推理取中点以便固定结果。

**重要性采样与 coarse/fine**：先由粗网络计算权重，把权重加一个防止零概率的 epsilon 后归一化为 PDF，对其累积为 CDF；取均匀随机数 u，通过逆 CDF 找到区间并在其中插值。新样本与旧样本合并排序，细网络重新查询并合成。PDF 是“想在哪儿多取样”的概率，密度 sigma 是场的物理参数，两者不能混称。粗网络多花一次查询，收益来自让细网络少浪费预算；本课没有跑原始 coarse/fine 双网络，因此不为它填入伪造速度数字。

**Occupancy grid（占用网格）**：空间小格保存可能有意义的密度/alpha 上界估计，用来跳过空格。它不是场本身，通常与神经编码独立；训练中应持续更新，否则一开始未学到的物体可能被永久跳过。保守更新会多算，过度激进阈值会漏几何。Instant-NGP 采用多尺度 occupancy 结构减少空位置查询，具体更新和阈值见原论文附录。[Instant-NGP 论文](https://nvlabs.github.io/instant-ngp/assets/mueller2022instant.pdf)。本课这一概念与 G.3 的显式体数据跳空相连，但不声称已经实现 NGP 的 occupancy 管线。

## 3. 从规则网格推导本课烘焙表示

需要缓存的不是一张相机图片，而是一个仍然能对新射线求值的场。G.4 网络给每个位置输出 13 个系数：`sigma`、`RGB base logits`、`RGB × direction.xyz`。只把已计算的固定方向 RGB 存入网格会丢失换视角所需信息；因此本课全部保存 13 通道，方向项在运行时再求值。

假设世界范围 `[-1,1]` 的每轴取 N 个端点均匀节点，节点 i 的坐标 `x_i=-1+2i/(N-1)`。对任意 x，连续网格坐标 `g=(x+1)(N-1)/2`，取 `i=floor(g)` 与比例 `f=g-i`；沿三轴对附近 8 个节点乘 `(1-f)` 或 f 加权，得到三线性插值。插值是在系数空间完成，随后颜色经过 sigmoid。一般 `sigmoid(interpolate(logits)) != interpolate(sigmoid(logits))`，所以必须明确本课到底烘焙哪一层。

`fields.py:70` 的 `from_model` 只调用训练好的 `model.coefficients`，完全不调用解析教师。网格内存是 `[1,13,Z,Y,X]`，X 方向连续，通道在更高维；不是交错 `[Z,Y,X,13]` 直接交给算子。64³×13×4 字节约 13 MiB，比这颗小 MLP 权重更大。加速可能来自用容量换查询计算；这种交换并非必然适合大场景。

```python
torch.nn.functional.grid_sample(
    input, grid, mode='bilinear', padding_mode='zeros', align_corners=True)
```

在三维输入时 `input` 是 `[N,C,D,H,W]`；`grid` 是 `[N,Dout,Hout,Wout,3]`，最后维固定 `(x,y,z)`，坐标归一化到 `[-1,1]`。虽然 mode 名称仍是 `'bilinear'`，5D 输入实际是三线性插值。`align_corners=True` 表示 -1/1 对应边缘节点中心，和前面 N-1 的推导匹配。`padding_mode='zeros'` 定义越界行为，本课还显式将盒外密度设零。网格由 `BakedField` 持有，调用者不能在异步 CUDA 工作尚未完成时销毁或改写它。[PyTorch grid_sample 文档](https://docs.pytorch.org/docs/2.14/generated/torch.nn.functional.grid_sample.html)。

插值误差来自离散空间分辨率，训练误差来自场对图像的拟合，采样误差来自射线积分步数。报告分别比较 `MLP vs 解析参考`、`烘焙 vs 解析参考` 和 `烘焙 vs MLP`，不能用一个 PSNR 隐藏三类误差。

## 4. Instant-NGP、混合精度与批处理放在正确层次

多分辨率哈希编码把位置映射到多个分辨率网格，每层插值附近节点上的可训练小向量，再拼接给一个小网络。粗层覆盖全局结构，细层表达局部细节；用哈希表限制细层内存时不同顶点可能碰撞，学习过程与多层特征共同消解歧义。它不同于本课“先训练 MLP，再烘焙输出系数”；NGP 的编码参数本身参与训练。[NVIDIA 官方实现](https://github.com/NVlabs/instant-ngp)。

tiny-cuda-nn 可融合编码和 MLP 的多个操作，减少中间激活的全局读写与 kernel launch；批量查询也让矩阵乘更有机会形成高吞吐工作负载。本课 PyTorch逐算子实现强调可读性，未使用自定义 fused MLP，因此不能以本课数字推断成熟系统极限。

混合精度不是“所有量都改 half”。MLP GEMM 常适合 FP16/BF16，密度指数、累积透射率和损失可能仍需 FP32；FP16 梯度还可能要 GradScaler 防止下溢。`torch.autocast(device_type='cuda', dtype=...)` 只对支持的运算选择计算精度；模型存储、梯度、归约和优化器状态必须分别确认。本课基准刻意保持 FP32，关闭 TF32，避免把采样/表示更换和精度变化混入一次对照。[PyTorch AMP 说明](https://docs.pytorch.org/docs/2.14/amp.html)。

## 5. 公平计时与显存口径

`benchmark.py:17` 的 `measure` 每项先暖机 3 次，再运行 12 次，记录 CUDA Events 中位数、最小/最大值和 CPU 墙钟。调用形式为 `torch.cuda.Event(enable_timing=True)`，`start.record()` 在当前流插入时间戳，`end.synchronize()` 等该事件完成，`start.elapsed_time(end)` 返回毫秒。没有同步直接量 Python 函数返回，测到的大多只是提交时间。

PyTorch 的很多短 kernel 由 CPU 连续提交，两个 event 之间的时间可能包含 host launch gap，因此这个数字是实际执行路径间隔，不声称是所有 GPU 活跃 kernel 持续时间的总和。正式测试时与本课程其他 GPU agent 错开，避免训练和 3DGS profiler 互相抢卡。

同一相机、128×96、64 样本、同一合成器，只更换场查询。另对 2048 条射线拆分测 `sample_rays`、MLP query、baked query、composite。PyTorch 的 `peak_allocated_bytes` 口径包含该进程常驻的两个表示及临时张量；报告还单独给 MLP 参数字节数和网格字节数。训练时间重复列入两条路径，额外 bake 单列；这条路径不声称训练加速。

结果在 [benchmark.json](../../sandbox/d3d12/neural-rendering/results/g5/benchmark.json)。完整实测数字见本节末尾记录。

## 6. 导出与 D3D12 的资源边界

从仓库根目录执行：

```powershell
& learning/sandbox/d3d12/neural-rendering/python/nerf/run.ps1
# 已有checkpoint时重新基准/导出：
& learning/sandbox/d3d12/neural-rendering/python/nerf/run.ps1 -SkipTraining
```

输出默认 640×360，另产生 320×240 resize 套件。文件 `nerf_color.f32` 是紧密行优先 little-endian float32 RGBA，左上原点、线性、预乘 alpha、未合背景且未 tone map；`nerf_depth.f32` 是正 camera-Z 条件期望，无有效密度处为 far=10。相机参数、字节数和 SHA256 写入 [nerf_camera.json](../../sandbox/d3d12/neural-rendering/results/g5/nerf_camera.json)。原始浮点、checkpoint、PNG 留本机，数值 JSON/CSV 与可复现源代码提交仓库。

`nerf_color_occluded.f32` 与 G.10 的前景矩形和背景平面求交后，将每像素积分上限截断到真正网格交点。这才能表示“体的一部分在网格前，一部分在后”。用一张期望深度来整像素丢弃 NeRF 会把半透明体当成硬表面，是错误的遮挡模型。D3D12 消费截断后的 C/A，再计算 `C+(1-A)*Cmesh`。

PyTorch先计算GPU张量，`.cpu()`复制完成后由主机持有独立字节。G.10实际消费者读入这些文件，先用`cudaMemcpyAsync`把主机数据传入其自行持有的线性device buffer，再用`cudaMemcpy2DToArrayAsync`复制到CUDA导入的D3D12共享纹理；共享纹理通过G.10的external fence和D3D12状态管理交给图形队列。这里确实使用CUDA/D3D12 external memory，但共享的是G.10明确创建和管理的纹理，**并非PyTorch tensor**，Python allocator的生命周期从未交给D3D12。本路径包含离线GPU→CPU导出和运行时CPU→GPU上传，也不应描述为零拷贝NeRF推理。

自测答案：烘焙速度快不意味着训练变快；网格加密主要减少空间插值误差，不会修复错误相机或差的训练解；减少采样次数与降低MLP查询成本可以叠加，但应先逐项测；颜色既随方向变化又需要烘焙时，应缓存能恢复方向变化的系数，而不是只存一张视图。

## 7. 2026-10-22 同场景实测

RTX 5070、PyTorch 2.14.1+cu130、FP32，固定 128×96、64 样本；每路径 3 次暖机、12 次计时。

|项目|直接位置编码 MLP|64³×13 通道烘焙网格|
|---|---:|---:|
|训练墙钟|5.05408 秒|同一份训练：5.05408 秒|
|额外烘焙墙钟|0|0.134732 秒|
|推理 GPU event 中位数|9.41598 ms|5.36317 ms|
|推理 CPU 墙钟中位数|9.52255 ms|5.38030 ms|
|表示数据字节|60,468|13,631,488|
|推理过程 PyTorch allocated 峰值|138,498,048|64,049,152|
|相对192步解析参考 RGB MSE|9.01835e-6|8.23991e-6|
|相对解析参考 RGB PSNR|50.4487 dB|50.8408 dB|

该条件下推理加速 **1.75568×**，用显式场容量换取更便宜的查询；两条路径在同一进程内测，峰值包含常驻的两个表示，不能当成各自独立部署的总显存。烘焙对直接 MLP 的 RGB MSE 是 `2.93897e-7`，PSNR 65.3181 dB，RGBA 最大绝对差 0.0137155；被测网格节点处系数解码误差 `7.15256e-7`。烘焙对解析参考略好是这一次插值带来的平滑效果，并不证明烘焙必然提升质量。

对 2048 条射线 × 64 步的成本拆分：采样 0.419520 ms、MLP 查询 1.003456 ms、烘焙查询 0.126032 ms、合成 0.177312 ms。查询明显变便宜后，采样与 Python/PyTorch 调度成本占比上升；因此端到端只加速1.76倍，而不是照搬查询阶段约8倍的比例。这正是“优化局部不能直接替代整体评测”的例子。

640×360 的普通与网格截断两张图一起计算耗时 0.205160 秒，随后才做 CPU 文件复制；它是离线双输出墙钟，不是 G.10 窗口的每帧渲染时间。320×240 resize 也已真实导出。对两套实际文件执行 [42 项 CPU 导出验收](../../sandbox/d3d12/neural-rendering/results/g5/export-validation.json)：尺寸、SHA256、文件字节数、finite、alpha范围、预乘约束、矩形外逐位一致、矩形内确实截断，以及截断后有效期望深度不超过网格 camera-Z 2.35，全部通过。`nerf_depth_occluded.f32` 与遮挡颜色来自同一次截断积分，G.10 应成对读取。
