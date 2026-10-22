# G.4 NeRF 的数据与表示：从已知相机图像反求一个连续场

[共享工程](../../sandbox/d3d12/neural-rendering/README.md) · [相机代码](../../sandbox/d3d12/neural-rendering/python/nerf/camera.py) · [可微积分](../../sandbox/d3d12/neural-rendering/python/nerf/rendering.py) · [训练入口](../../sandbox/d3d12/neural-rendering/python/nerf/train.py) · [G.5](G.5-NeRF采样与实时化路径.md)

## 1. 先定义要解决的问题

G.1 已经会在“知道每个位置的密度与颜色”时生成一张图。现在反过来：只有若干幅图像和拍摄相机，我们希望找到一组参数，使它从这些相机看过去时生成接近原图的结果。这是一个逆问题：正向过程由场生成图，逆向过程由图约束场。它一般没有唯一答案；训练视角拟合很好，并不能自动证明背面几何或新视角正确。

游戏开发中可把它类比为把一个关卡烘焙进某种资产。但传统 lightmap 存在已知网格的 UV 上，NeRF 直接把位置和观察方向映射为密度与辐射值，并不要求先有表面网格。网络参数是场景表示，优化这些参数是训练，给定位置查询是推理，沿射线查询并合成才是渲染。这四个动作必须分开理解。

原始 NeRF 使用位置与方向输入以及可微体渲染，从已知相机图像优化场。[原论文项目页](https://www.matthewtancik.com/nerf)。本课实现小型 PyTorch 教学基线；不是直接复刻原论文网络、数据集和完整训练配置。

## 2. 从像素约束推导射线

本课固定世界单位和相机约定：默认眼睛 `(0,0,-3)`，朝向原点，相机局部 `+X` 向右、`+Y` 向上、`+Z` 向前；图像行号向下。垂直视场 50°，主点 `(W/2,H/2)`，方形像素，因此 `fx=fy=H/(2 tan25°)`。near/far 是 0.1/10；场只存在于 `[-1,1]^3`。

问题是：像素中心 `(u,v)=(x+0.5,y+0.5)` 对应相机空间哪个方向？针孔投影满足

```text
u = cx + fx X/Z
v = cy - fy Y/Z
```

令局部方向的 Z=1，直接解得 `q=((u-cx)/fx, -(v-cy)/fy, 1)`。这不是凭记忆套一张投影矩阵，而是解相似三角形给出的约束。若相机世界基为 right/up/forward，那么 `d=normalize(qx right+qy up+qz forward)`，`r(t)=eye+t d`。单位化后 t 才是世界距离，G.1 的 sigma 就具有“每世界长度”的单位。

`camera.py:17` 的 `intrinsics` 给内参，`:22` 的 `basis` 构造基，`:33` 的 `rays` 返回 `[H*W,3]` 两个张量。origin 使用 `expand` 广播同一个 eye，不拥有每条射线的一份独立可写存储；本课只读它。方向由计算产生连续像素顺序：先整行，再下一行。

View 是换基的逆。正交相机基组成列矩阵 `B=[right up forward]`，点从局部到世界是 `p_world=eye+B p_camera`，所以 `p_camera=B^T(p_world-eye)`。相机文件可能给 camera-to-world，也可能给 world-to-camera，不能只看到“4×4”便直接送入 shader。

### OpenGL / COLMAP 为什么要显式转换

原始 NeRF 代码采用 OpenGL 相机局部 X 右、Y 上、Z 后，并存 camera-to-world。[上游坐标说明](https://github.com/bmild/nerf#already-have-poses)。保持同一物理相机时，`B_gl=[right up -forward]`、`q_gl=(qx,qy,-1)`，二者相乘仍是同一条世界射线。COLMAP 图像方向约定对应 X 右、Y 下、Z 前，本课用 `B_cv=[right -up forward]`、`q_cv=(qx,-qy,1)` 验证同样的世界方向。矩阵乘法的行/列向量约定还要独立检查；轴转换不等于矩阵转置。

本课 `contracts.py` 在左上、中心、右下像素分别核对两种转换，另外检查中心向前、左上符号和射线长度。这里讨论相机几何，与 D3D 的 NDC 深度 `[0,1]` 是不同层面。NeRF 沿世界射线积分不需要先把深度变成 NDC；输出给 D3D 时另由契约说明。

## 3. 场、位置编码与网络到底存什么

目标是 `F_theta(p,d) -> (sigma, rgb)`。密度 sigma 描述位置对光的消减率，与观察方向无关；RGB 可以随观察方向变化。NeRF 的颜色是学习得到的出射辐射表达，本课没有再插入一套实时光源求解器。因此换方向能改变颜色，不代表任意移动灯光都能正确重照明。

直接把 xyz 送入普通 MLP 容易先学低频变化。位置编码把每个分量展开为多个尺度的 sin/cos：

```text
gamma(p) = [p, sin(pi*2^0 p),...,sin(pi*2^(L-1) p),
               cos(pi*2^0 p),...,cos(pi*2^(L-1) p)]
L=4 -> 3+6L=27维
```

它是确定性的坐标特征变换，不是把世界分成 27 个体素，也不是压缩存储的格式。网络再从这些特征学习组合。`fields.py:27` 的 `TinyNeRF` 使用四层宽度 64 的 ReLU MLP，输出 13 个数：1 个密度参数、3 个 RGB logits、每个颜色通道 3 个方向系数。密度用 `softplus(raw-1)` 保证非负，颜色是 `sigmoid(base + A d)`。这里 A 是一个每位置学习的 3×3 系数矩阵；方向模型特意限制为线性基的 logits，便于 G.5 烘焙全部系数。它不是原始 NeRF 完整方向分支，也不是 G.6 高阶球谐。

网络内存主要是权重和中间激活。权重由 `nn.Module` 持有；`model.to('cuda')` 把参数和频率 buffer 放到 GPU；Adam 持有动量/二阶矩等优化器状态。一次训练射线 `[R,3]` 展开成采样点 `[R,S,3]`，本课 R=512、S=48；沿最后一维做编码后是 `[R,S,27]`，MLP 输出 `[R,S,13]`，解码成 sigma `[R,S]`、rgb `[R,S,3]`。

## 4. 为什么图像损失能反向到密度

固定相机射线后，对盒内区间等距分 S 段，训练时每段随机抖动位置，推理时取中点。由局部吸收约束得到

```text
optical_i = sigma_i delta_i
alpha_i   = 1-exp(-optical_i)
T_i       = exp(-sum_{j<i} optical_j)
w_i       = T_i alpha_i
C         = sum_i w_i rgb_i
A         = sum_i w_i
```

本课不是对每个采样点单独提供密度真值。解析场只在生成训练图像时被调用；训练循环拿到的是相机射线和 RGBA 图像，计算预测图像与目标图像的均方误差，再由链式法则把误差传回网络。密度既影响本点 alpha，也影响所有后点的透射率，因此它的梯度不是只改当前点的亮度。

`rendering.py:29` 用 `-torch.expm1(-optical)` 得 alpha，避免小 x 时 `1-exp(-x)` 的相消误差；对光学厚度做 cumsum，再首部补零并移位，得到 exclusive prefix。这里 `T_i` 包括 i 之前的吸收，不包括自身，否则会多衰减一次。整条路径没有把结果转 NumPy，也没有 `detach`，自动微分图能够连回 sigma 与颜色参数。

最终预乘 RGB 的取值不超过 alpha，背景合成是 `C+(1-A)*C_background`。depth 是 `sum(w*t)/A` 的条件期望，再乘射线方向在 camera forward 上的分量，转为正 camera-Z。它是统计量，不能当成不透明表面 ZBuffer。

## 5. 关键 PyTorch API、同步与失败路径

本课实际使用的调用形式：

```python
torch.nn.Linear(in_features, out_features, bias=True)
torch.optim.Adam(params, lr=0.002)
optimizer.zero_grad(set_to_none=True)
loss.backward()
optimizer.step()
torch.cuda.synchronize(device=None)
torch.cuda.reset_peak_memory_stats(device=None)
torch.cuda.max_memory_allocated(device=None)
torch.save(obj, path)
torch.load(path, map_location='cuda', weights_only=True)
```

`Linear` 持有 `[out_features,in_features]` 权重和可选 bias，对输入最后一维做仿射变换。Adam 的 `params` 是模型参数迭代器，`lr` 是更新步长；本课用默认动量系数，不声称它们是这个任务的最优配置。`zero_grad` 必须在本轮反向前清旧梯度；`backward` 累加梯度，不自动更新权重；`step` 用梯度更新权重。三者顺序错了会悄悄改变训练含义。

CUDA 运算通常异步入队。Python 函数返回不表示 GPU 已完成；计训练墙钟前后都调用 synchronize。稀疏打印 loss 会触发标量读取和同步，其代价包含在训练墙钟中。`max_memory_allocated` 是 PyTorch 张量分配峰值，不是整个驱动进程显存，也不包括所有库工作区；不要和 `nvidia-smi` 混用。

checkpoint 只保存 state_dict 与普通标量，不保存任意 Python 类。加载开启 `weights_only=True` 并检查 schema，`load_state_dict(strict=True)` 拒绝缺失/多余参数。本课要求可用 CUDA 且 capability `(12,0)`，否则明确失败；不静默切 CPU 后输出“GPU 验收通过”。首步梯度必须有限且非零；全训练集 MSE 必须低于固定阈值，未达标退出非零。

## 6. 动手、验收与边界

从仓库根目录执行：

```powershell
& learning/sandbox/d3d12/neural-rendering/python/nerf/setup.ps1
& learning/sandbox/d3d12/neural-rendering/.venv/Scripts/python.exe learning/sandbox/d3d12/neural-rendering/tests/nerf/contracts.py
& learning/sandbox/d3d12/neural-rendering/.venv/Scripts/python.exe learning/sandbox/d3d12/neural-rendering/python/nerf/train.py --steps 1800
```

本机软件和数值结果写入 [training.json](../../sandbox/d3d12/neural-rendering/results/g4/training.json)，损失曲线原始数据在 [loss.csv](../../sandbox/d3d12/neural-rendering/results/g4/loss.csv)，14 项 CPU 数值契约在 [contracts.json](../../sandbox/d3d12/neural-rendering/results/g4/contracts.json)。梯度中心差分误差为 `9.1392e-13`。完整实测训练数字见本节末尾记录。

训练用 12 张 32×32 的解析双雾团图像，RGBA 透明真值已知；合成场小、无纹理照片噪声、相机完全准确。它用于验证可微渲染和小场景过拟合，不是照片重建能力评测。我们还测未参与训练的一个相机，以免把训练误差当泛化结果。商业系统往往还需要相机标定、畸变处理、曝光/色彩校正、更强场表示以及空间加速结构；本课与它们共享射线几何、连续场查询、透射率积分和梯度优化这些机制。

自测答案：位置编码不改变物理位置，只改变网络输入特征；把 ray direction 不归一化却继续用固定世界步长，会改变 optical thickness；训练图像误差小不能证明恢复了唯一真实几何；颜色误差通过后方样本的 T 同样能对前方密度产生梯度。

## 7. 2026-10-22 本机实测

Python 3.13.7、PyTorch 2.14.1+cu130、RTX 5070、实际 capability `(12,0)`，官方 wheel 架构列表包含 `sm_120`。系统 CUDA Toolkit 13.3 与 wheel 自带 CUDA 13.0 runtime 不是同一版本概念；本实验未编译自定义 torch extension，实际使用 wheel 所带算子。

|项目|实测|
|---|---:|
|训练图像|12 × 32 × 32，RGBA|
|迭代 / 每步射线 / 每射线样本|1800 / 512 / 48|
|首个随机 batch RGBA MSE|0.0434043|
|首步参数梯度 L2|0.0495951|
|最终全部训练图像 RGBA MSE|0.00000977137|
|最终全部训练图像 RGB MSE|0.00000824565|
|未参与训练的相机 RGB MSE / PSNR|0.0000129416 / 48.8801 dB|
|训练墙钟，排除数据生成|5.05408 秒|
|训练 PyTorch allocated 峰值|108,442,624 字节|
|可训练参数 / checkpoint|15,117 / 65,124 字节|
|CPU 相机/梯度/积分契约|14 项通过|

固定 seed 为 20261022。首步 batch 与最终全图不是完全相同的统计集合，所以这里只用首步确认明显收敛和固定过拟合验收；最终质量以全训练图像和独立相机为准。5 秒量级来自极小合成数据和小网络，不能外推真实照片场景的训练时间。checkpoint SHA256、全部源码哈希、每100步损失记录已保存，可定位测量到底对应哪份实现。
