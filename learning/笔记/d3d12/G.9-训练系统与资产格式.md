# G.9：训练怎样产生可渲染参数，资产怎样可靠进入我们的渲染器

[课程工程](../../sandbox/d3d12/neural-rendering/README.md) · [严格 PLY 转换](../../sandbox/d3d12/neural-rendering/python/assets/convert_ply.py) · [参考资产下载](../../sandbox/d3d12/neural-rendering/python/assets/fetch_reference.py) · [格式测试](../../sandbox/d3d12/neural-rendering/tests/assets/test_import.py)

本节把“能画高斯”与“从照片得到高斯”接起来，并完成真实参考训练资产的导入。G.6–G.8 的 CUDA 程序只实现前向渲染；本节没有把它冒充完整可微训练框架。我们阅读 Graphdeco 官方训练系统，实际导入由参考方法训练的 741,883 个高斯；该 3DGS 场景不是本机训练的。G.4 的小型 NeRF 则确实在本机完成了 1,800 次优化与前向/反向验证。

## 1. 四个环节分别拥有什么

先用游戏资产管线类比。DCC 工具里制作角色、导出 glTF、引擎导入内部资产、运行时渲染是不同环节。这里同样应分开：

|环节|输入|输出与责任|
|---|---|---|
|训练|多视角照片、相机标定、初始表示|更新 NeRF 权重或高斯参数，保存优化器和进度|
|导出|训练参数|PLY/权重文件；不一定包含优化器状态|
|导入|带明确模式的外部资产|校验、解码、转换为内部格式|
|渲染|运行时参数与当前相机|线性预乘 RGBA、定义清楚的代表深度|

“场景表示”是存储什么，“训练”是如何调整它，“渲染”是如何从它生成像素。NeRF 用网络表达场，高斯用显式参数表达场；它们都可以接受图像损失优化，不代表两者都必须在每帧运行神经网络。

## 2. 从像素误差推导梯度为什么能回到位置与形状

设训练照片为 I，相机已知，渲染结果为 C(θ)，θ 包括位置、尺度、旋转、opacity、SH。一个简单目标是让 `L=Σ||C(θ)−I||²` 下降。梯度 `∂L/∂θ` 表示在当前参数附近，朝哪个方向微调会改变损失；它不是对场景几何真实性的保证。多视角、初始化和正则化影响能否得到一致重建。

为看清链条，先固定一个像素当前的可见高斯顺序，不考虑 clamp/截断边界。前到后合成为 `C=ΣTi αi ci + Tfinal·background`。把第 k 项之后的合成单独记成 `Cbehind`，它以“刚穿过第 k 项”为起点、初始透射率为 1，则：

```text
C = Cbefore + Tk [αk ck + (1−αk) Cbehind]
∂C/∂ck = Tk αk I3
∂C/∂αk = Tk (ck−Cbehind)
```

这解释了一个常见误解：增加某高斯 opacity 不一定让像素更亮，它会增加自己的贡献，同时减少后方贡献；导数里必须有后方颜色的负项。

进一步，`α=o·exp(−0.5 dᵀQd)`，其中 d=p−m、Q=Σ2D⁻¹：

```text
∂α/∂o = exp(−0.5 dᵀQd)
∂α/∂m = α Qd
∂m/∂μworld = J W
```

因此链式法则把“像素误差”通过 Alpha、屏幕中心、投影 Jacobian 传回世界位置。形状也通过 `Σ2D=J W R S² Rᵀ Wᵀ Jᵀ` 影响权重。这里的公式是对前向算式的推导；本课 G.6–G.8 并没有据此另写 CUDA backward。

排序、裁剪、增删高斯是离散操作，不是全局光滑函数。常用可微光栅器在当前活动集合与顺序下传播连续部分的梯度，边界变化和截断会带来近似；不能将“可微渲染”理解为所有控制流都具备处处连续的精确导数。

训练时常用无约束参数 l、a：`s=exp(l)`、`opacity=sigmoid(a)`，因此链上还要乘 `∂s/∂l=s` 与 `∂opacity/∂a=opacity(1−opacity)`。如果把 PLY 中的 l 当成实际尺度，前向与反向的解释就都错了。

## 3. 官方训练循环与 Adam 状态

已阅读 [Graphdeco 官方 train.py](https://github.com/graphdeco-inria/gaussian-splatting/blob/main/train.py)。其核心步骤是选择训练相机、前向渲染、计算图像损失、调用 backward，然后在无梯度区域执行统计/增删点与优化器更新；当前源码还有可选的深度、曝光等路径。官方图像目标包含 L1 与结构相似度相关项。本课的合成 RGBA NeRF 损失较简单，不应宣称复刻全部官方训练设置。

Adam 为每个可训练标量保留一阶与二阶历史。忽略可选 weight decay，记当前梯度为 g，步骤为：

```text
m ← β1 m + (1−β1) g
v ← β2 v + (1−β2) g²
mhat = m/(1−β1^t), vhat = v/(1−β2^t)
θ ← θ − learningRate * mhat/(sqrt(vhat)+epsilon)
```

m 平滑方向，v 平滑梯度尺度；偏差修正抵消初始零历史的影响。不能仅删除参数向量中的一行而保留旧 optimizer 状态：那会让一个高斯使用另一个高斯的动量。增添元素也需要为新元素定义历史状态。PyTorch 提供 [`torch.optim.Adam`](https://docs.pytorch.org/docs/stable/generated/torch.optim.Adam.html) 及参数组/状态管理，当前官方高斯模型还对各类属性设置不同学习率。

只估算 3 阶 SH 的 59 个 float 参数：参数、梯度、两个 Adam 历史各一份，需要 `59×4×4=944 bytes/高斯`，尚未计入屏幕中间量、排序引用、框架缓存、曝光或 mixed precision 的额外状态。741,883 个高斯仅这四份标量数组就约 700 MB。运行时的 244 bytes/高斯和训练显存绝不是同一个口径。

PLY 通常足够恢复渲染参数，但不足以逐步无缝续训：checkpoint 还需要优化器状态、步数、调度与密度控制统计。本课导出的 GSBIN 同样是运行时资产，不是完整训练 checkpoint。

## 4. Densification：为什么不只依赖梯度移动原有高斯

固定数量的高斯可能无法同时描述薄边缘和大片平坦区域。Densification（增加表达元素）与 prune（删除低价值元素）改变表示容量，作用类似网格细分/简化的自适应思想，但控制信号来自训练统计，操作对象是高斯。

从 [官方 gaussian_model.py](https://github.com/graphdeco-inria/gaussian-splatting/blob/main/scene/gaussian_model.py) 可以确认几个关键事实：高屏幕位置梯度的小高斯走 clone；较大者走 split，并缩小新尺度、移除原元素；低 opacity 或超大元素可被 prune；opacity reset 把实际 opacity 上限降至 0.01，并同步重置对应优化器历史。新增/删除行时，参数和 Adam 状态一起扩展/裁剪。

进一步理解这些操作，而不是只背函数名：

- **Clone** 增加局部自由度。复制不代表立即得到更正确图像，也不保证总 Alpha 守恒；后续优化需要重新调整位置、颜色与遮挡。
- **Split** 用多个更小元素替代过大的元素，改善一个宽斑点无法描述细节的问题。子位置通常围绕原分布采样；它不是把一个三角形精确分成面积守恒的两个三角形。
- **Prune** 控制资源预算，移除贡献很低或不合适的表示。训练中“删点”会改变场景参数与 optimizer；G.6 的“剔除离屏高斯”只影响本帧工作列表，两者不可混称。
- **Opacity reset** 为后续优化重新开放遮挡关系。它不是把所有点设成完全透明，也不是整个网络/所有属性重新初始化；为什么有帮助，应结合随后损失与可见性观察，不能把一次重置本身当成保证收敛的证明。

屏幕位置梯度大，说明当前表示对某处误差的局部变化敏感，不等价于“这里一定存在真实物体表面”。密度控制是经验性的优化策略，需要阈值、频率、场景尺度与停止时机配合。[原始 3DGS 论文](https://arxiv.org/abs/2308.04079) 将显式高斯、交替优化/密度控制、可见性感知渲染作为相互配合的组成部分。

## 5. PLY 属性逐字段解码，不把容器名称当模式

PLY 只是描述属性和元素的容器。“这个文件扩展名是 .ply”并不能证明它是 Graphdeco 高斯。普通网格、彩色点云、压缩 splat 的属性和数值域都可能不同。

本课 `read_ply`（`convert_ply.py:19`）仅接受 binary_little_endian 1.0、一个 vertex element、float32 标量属性和允许的注释。属性按名字解释，顺序可变；缺失、未知、重复属性及额外尾部数据均报错。支持 0–3 阶 SH，rest 必须恰好有 `3*((degree+1)²−1)` 个且编号连续。

|PLY 字段|训练参数含义|内部转换|
|---|---|---|
|x,y,z|世界均值|原值保留|
|nx,ny,nz|该模式中的法线占位|要求存在且有限，不作为光照法线使用|
|scale_0..2|log 标准差|float64 exp，写回 float32 后再验有限、正值|
|rot_0..3|未必单位长度的 wxyz|检查非零，再归一化|
|opacity|logit|分正负支的稳定 sigmoid|
|f_dc_0..2|SH 的 RGB 常数系数|写入第 0 基函数 RGB|
|f_rest_0..44（degree 3）|RGB 各自连续 15 系数|reshape 为 `[N,3,15]` 后转为 `[N,15,3]`|

例如 `f_rest_0=R1,f_rest_15=G1,f_rest_30=B1`，它们共同组成内部 `sh[1,RGB]`，不能把前三个 rest 数值误当作 RGB。此操作是内存布局转换；并没有压缩 SH，也没有更改其数学基函数。

sigmoid 对正 a 使用 `1/(1+exp(-a))`，对负 a 使用 `exp(a)/(1+exp(a))`，避免无谓溢出。scale 即使 float64 exp 有限，也可能转 float32 时上溢成 inf 或下溢成 0，所以第二次检查必要。极端不合法参数应拒绝，不应自动夹成“看起来还能画”的值掩盖格式问题。

## 6. GSBIN001：字节偏移必须显式约定

写入格式由 `struct.pack("<8s4I",...)` 与 NumPy 的小端 dtype 定义。头部固定 24 bytes：

|偏移|大小|含义|
|---|---:|---|
|0|8|ASCII magic `GSBIN001`|
|8|4|uint32 高斯数量|
|12|4|uint32 stride，当前必须为 244|
|16|4|uint32 SH degree，0..3|
|20|4|uint32 保留字段，当前为 0|

每条记录固定 244 bytes：

|记录内偏移|大小|内容|
|---|---:|---|
|0|12|mean[3] float32|
|12|12|scale[3] float32，已 exp|
|24|16|rotation[4] float32，单位 wxyz|
|40|4|opacity float32，已 sigmoid|
|44|192|sh[16][3] float32，未使用高阶补零|
|236|4|stable id uint32|
|240|4|本记录 SH degree uint32|

整文件长度必须等于 `24+count*244`。这是 wire 格式，不是“让任意平台直接把某个 struct fwrite”。当前 Windows C++ 运行时用 `static_assert(sizeof(gs::Gaussian)==244)` 检查 ABI，数据按固定小端读取；未来改变字段、压缩方式或端序必须新版本，不能沿用同一个 magic 静默解释。

## 7. 资产下载完整性与训练来源是两个问题

`fetch_reference.py` 固定仓库 revision `6aaba1b1dd0439c0db464842f8a6600a37e0eae9`，并固定 PLY 的 LFS SHA256：

```text
9f5c643fa18cb5ed6a11441f073133ed1034e3b0656bce5b7b5db3db49161366
```

脚本先核对固定版本的 LFS 元数据，再流式下载到 `.partial`，完整读取并核验 SHA256 后才用 replace 更新目标。网络断开只留下 partial，不会把半个文件当成有效资产；已有且 hash 正确的文件直接复用。hash 保证内容与锁定资产一致，不证明训练方法、画质或许可来源。

训练来源来自 [数据集作者的固定版本说明](https://huggingface.co/datasets/pjramg/gaussian_splatting/blob/6aaba1b1dd0439c0db464842f8a6600a37e0eae9/README.md)：作者声明其集合用官方 3DGS 方法制作，提供 iteration_7000/30000 结果。本课使用该声明并保留来源，不把第三方镜像称为 Inria 官方发布服务，也不声称已独立重跑其训练轨迹。`provenance.json` 明确 `trained_locally:false`。

数据卡记录的许可标签是 apache-2.0；这只是该镜像的元数据，并不会改写 [Graphdeco 软件自身 LICENSE](https://github.com/graphdeco-inria/gaussian-splatting/blob/main/LICENSE.md) 或原始照片数据集的条款。本学习仓库提交导入代码、hash、来源和数值报告，大型 PLY/GSBIN 留在本机 downloads；不将镜像标签推广成所有上游内容的统一许可。

## 8. 本机真实导入与 21 项独立测试

从仓库根执行（Python 需要 NumPy）：

```powershell
python learning/sandbox/d3d12/neural-rendering/python/assets/fetch_reference.py
python learning/sandbox/d3d12/neural-rendering/python/assets/convert_ply.py
python learning/sandbox/d3d12/neural-rendering/tests/assets/test_import.py
```

[import.json](../../sandbox/d3d12/neural-rendering/results/g9/import.json) 记录 741,883 个 3 阶高斯，PLY 183,988,515 bytes，GSBIN 181,019,476 bytes，读取+转换+逐字段核验约 1.216 秒。位置逐元素相等，SH 转置后逐元素相等，单位四元数、sigmoid opacity、正尺度及其相对转换误差均通过。

原始四元数长度约 0.414–1.908，真实资产直接证明“文件里旋转一定已经单位化”是错误假设。实际尺度约 9.567e-7–1.235，opacity 约 0.00312–0.999998。显示时若对位置做中心/尺度归一化，应同步均匀缩放高斯尺度，并明确这是显示变换，不得改写导入后原始值验收的结论。

[import-tests.json](../../sandbox/d3d12/neural-rendering/results/g9/import-tests.json) 的 21 项测试包括已知 degree 0/3 字节布局、SH 通道转置、属性乱序、缺失/未知/重复属性、非法 SH 数、NaN/inf、零四元数、数据截断/多余尾部、float32 scale 上下溢，以及下载 hash/固定 revision/中断不覆盖旧文件。它们用独立小样本和无网络 mock 验证失败路径；真实下载与 741,883 个元素导入另有 provenance/import 报告，两个证据不能互相替代。

## 9. 相机、照片颜色与生产边界

同一 PLY 配错相机也能“出图”，却可能只看到一团远景点。相机资产必须区分 camera-to-world 和 world-to-camera；相机位置 C 与相机旋转 Rc2w 给出 `RworldToCamera=Rc2wᵀ`、`t=−RworldToCamera*C`。相机轴的 Y 翻转要同时用于旋转与平移，并在投影中只处理一次。

已检查 [官方 camera_to_JSON](https://github.com/graphdeco-inria/gaussian-splatting/blob/main/utils/camera_utils.py)：JSON 保存 position、rotation、图像尺寸与 fx/fy，不能只根据键名把 rotation 当成本课 worldToCamera。缩放图像时应同步缩放焦距/主点，并保持像素中心约定一致。COLMAP 的 +Y 向下与本课相机 +Y 向上需显式转换。

照片训练的 SH 颜色是在训练数据颜色管线下拟合的外观。没有线性化与曝光标定证据时，不能称它为物理辐射亮度，不能期待改一盏灯就像 PBR 材质一样重光照。G.10 对参考资产采用明确的外观颜色解码适配，并声明它不等同于重新训练一个线性物理场。

本机 NeRF 的训练证据见 [G4 training.json](../../sandbox/d3d12/neural-rendering/results/g4/training.json)：12 张 32×32 合成视图，1,800 steps，首步梯度非零，最终训练 RGBA MSE 约 9.77e-6；这是教学合成场的真实优化，不是该真实照片 3DGS 的训练记录。

## 10. 成对相机预览：另一套资产另存，不混配两个重建

为验证原始相机契约，另外取得同一个固定 revision 中成对的 PLY 与 `cameras.json`。此镜像是 `camenduru/gaussian-splatting`，revision 为 `c63df2ffae19c1d288f81c1d5faf53ff6661be84`，其 iteration_7000 资产有 **667,872** 个高斯，与前面 pjramg 的 **741,883** 个资产不同。相似场景名称不能证明两份重建处于同一坐标系；没有将其中一份的相机配到另一份模型上。

相关代码为 [reference_camera.py](../../sandbox/d3d12/neural-rendering/python/assets/reference_camera.py)。从仓库根复现：

```powershell
python learning/sandbox/d3d12/neural-rendering/python/assets/reference_camera.py
& learning/sandbox/d3d12/neural-rendering/tests/assets/reference_build.ps1
python learning/sandbox/d3d12/neural-rendering/python/assets/reference_preview.py
```

这条路径保留原始场景坐标，不进行分位包围盒归一化；相机转换是 `W2C_gs=diag(1,-1,1,1)*inverse(C2W_json)`。左乘 Y 翻转同时变换旋转行和平移分量。本机用独立矩阵逆和转置公式交叉核对，最大误差 `1.221245327e-15`；三个已知相机点在转换前后的双精度投影误差为 `5.684341886e-14` 像素。真正打包成运行时 float32 后，投影最大误差约 `8.972942737e-6` 像素，不能拿双精度检查结果冒充 GPU float32 精度。

输出为 640×360，fx 按 `640/1959` 缩放、fy 按 `360/1090` 缩放，主点在图像中心。源图比例和目标比例略有差异，因此这是明确的横纵重采样，不应悄悄宣称保持完全相同的方形像素焦距。

[完整报告](../../sandbox/d3d12/neural-rendering/results/g9/reference-preview/report.json) 记录 517,029 个可见高斯、2,079,055 个 tile 引用，Renderer 持久分配 287,667,136 bytes，scratch 25,327,359 bytes。一次预热后的一次预览 wall 时间约 3.8765 ms，其中 splat CUDA event 约 2.0613 ms；这是预览计时，不是重复性能基准，也不能与 G.7 十次均值混在一起排序。

本机 `results/g9/reference-preview/camera0.png` 已实际渲染并目视确认可辨认火车，颜色直接按上游拟合的 RGB 外观值截断显示，不额外编码 gamma。画面对比度偏低，当前教学投影/截断/像素中心等近似也不保证逐像素复现官方渲染；没有配对官方参考图进行 PSNR 验收，故不声称达到论文画质。报告同时保存 PLY/相机/运行时资产/输出 hash 和源码 hash，避免把一个“能看到东西”的截图代替完整验收。

可以具体指出两处实现差异：[官方前向实现](https://github.com/graphdeco-inria/diff-gaussian-rasterization/blob/main/cuda_rasterizer/forward.cu) 在协方差投影前会限制离轴 `x/z,y/z` 的范围以稳定 Jacobian，其近相机过滤也与本预览的 near=0.05 不同；我们的 G.6 保留直接推导出的局部 Jacobian，并以半径上限拒绝极大斑点。这些选择可能影响近处/离轴高斯的覆盖与合成，尚未单独做控制变量画质实验。因此不能只凭截图偏灰，就断言原因是训练质量差或相机错误。

自测答案：运行时 PLY/GSBIN 不足以逐步恢复 Adam 训练历史；clone/prune 与本帧视锥剔除分属资产优化和渲染调度；exp/sigmoid 是训练参数解码，SH transpose 是数据布局转换；内容 hash 验证与训练来源声明证明的是不同事情。
