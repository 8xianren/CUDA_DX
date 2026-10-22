# F.4 时域重建的输入契约：先证明“上一帧在哪里”

[F 主线程序](../../sandbox/d3d12/aa-reconstruction/README.md) · [上一节 FXAA](F.3-FXAA边缘方向搜索.md) · [下一节 TAA](F.5-历史重投影与拒绝.md)

目标是仅看一份数据声明，就能判断 motion 的方向、单位、是否含 jitter，知道哪些历史可以读取。本节核心为 `src/temporal_contract.h:18`、`:36`、`:57`、`:72`，GPU 实际输入由 `src/scene.cpp` 和 `shaders/scene.hlsl` 生成。CPU oracle 是 `audit_temporal.py`，不是用 CPU 图片替代 GPU 渲染。

## 1. 先区分图像位置和物体身份

假设角色从屏幕 x=40 走到 x=48。今天的 48 号像素要寻找昨天的 40 号像素，而不是继续读取昨天的 48。Motion Vector 就像逐像素的“上一帧地址便条”。便条给的是地址，不能保证地址上的旧内容仍是同一表面；后者由深度、遮挡和历史拒绝负责。

我们先选约定，再推公式：左手视空间 +z 向前；NDC x 向右、y 向上，D3D 深度位于 [0,1]；纹理 UV y 向下；CPU 使用 DirectXMath 的行向量矩阵语义，shader 声明与之匹配。Motion 默认用不含 jitter 的当前和上一帧位置相减。

对物体同一个局部点 `p`，前后帧分别经过自己的 Model、View、Projection：

```text
clip_current  = p × M_current × V_current × P_current
clip_previous = p × M_previous × V_previous × P_previous
uv(clip) = (0.5 × (clip.x/clip.w + 1), 0.5 × (1 − clip.y/clip.w))
motionUV = uv_previous − uv_current
```

相机平移要求上一帧 View，物体旋转要求上一帧 Model；只保存上一帧相机矩阵不能正确处理旋转物体或骨骼变形。前帧 `w<=0` 表示对应点在相机后方或无有效投影，应拒绝历史，不能用 epsilon 把它伪装成有效位置。

## 2. Jitter 从采样问题推出来

一个像素代表有限面积，我们每帧只取一个样本。始终取中心会重复同一个偏差；让样本在像素内移动，才有机会积累不同子像素覆盖信息。Halton 的 radical inverse 把整数的进制数字倒放到小数位置。例如 `5=101₂`，反序小数 `.101₂=5/8`。二维分别用 base 2 和 base 3，再减 0.5 得到以中心为原点的偏移。

`HaltonJitterPixels(frameIndex,period=8)` 中 frameIndex 从 0 开始，内部加 1；首个偏移为 `(0,−1/6)` 像素。除以内部尺寸得到 jitterUV。若 jitterUV 表示加到屏幕几何位置的偏移，则裁剪空间偏移为：

```text
clip.x +=  2 × jitterUV.x × clip.w
clip.y += −2 × jitterUV.y × clip.w
```

负号来自 NDC 与 UV 的 y 方向相反。不要把“向右移动投影几何”与“射线在像素内向右采样”说成同一个符号约定；射线生成式往往是相反的视点偏移，必须从最终屏幕位置重新验证。

当前采样坐标为 `uv_current_nojitter + jitter_current`，同一表面的历史坐标应是 `uv_previous_nojitter + jitter_previous`。消去无 jitter 的当前坐标：

```text
previousUV = currentUV + motionUV + previousJitterUV − currentJitterUV
```

若 motion 本身由两个含 jitter 的位置相减，补偿已经在 motion 里，不能再次加差值。这由 flag `MotionIncludesJitter` 明确声明。静止相机和物体的“不含 jitter MV”必须是零，但含 jitter MV 通常不为零。

这里还必须区分**内部历史格点**和**最终显示格点**。本课 `TaaCS` 保持历史定义在各帧自己的 jittered 格点，因此上述 `previousJitter-currentJitter` 正是内部历史对应关系。最终显示不能把带本帧 jitter 的图直接与固定格点 reference 比较。几何向 +j 移动后，内部图是 `Fj(u)=F(u−j)`，因此 `Fj(u+j)=F(u)`；追加的 `UnjitterCS` 以 `uv+jitterUV` 采样，得到固定格点输出。注意这里的加号是从图像平移推出来的，不是另猜一个“抵消偏移”的负号。

Unjitter 输出只用于显示/捕获，**不回写给 jittered history**；否则下一帧还按旧合同补 jitter 就会重复校正。商业 TAA 常在内部重建时直接生成固定输出格点，省去这次独立滤波；本课拆成两个 pass 是为了让两种坐标网格可以分别验收。它带来额外双线性软化与边缘 clamp 近似，最后成本必须计入重建 GPU 时间。

## 3. 实际纹理合同

|资源|格式/通道|语义和拥有者|
|---|---|---|
|currentColor t0|主场景 RGBA16_FLOAT；oracle RGBA32_FLOAT|线性 HDR；本帧 scene 生产、post 消费|
|historyColor t1|同色彩约定|上一帧 TaaCS 的 jittered 格点输出；不能与本帧 u0 重叠，不使用 Unjitter 输出|
|motionDepth t2|RGBA32_FLOAT|xy 为 current→previous UV；z 为当前线性 viewZ；w 为该表面的预期上一帧 viewZ|
|previousDepth t3|主场景 R32_FLOAT；oracle RGBA32_FLOAT 的 r|上一帧真正可见表面的线性 viewZ|
|reactiveMask t4|主场景 R8_UNORM；oracle RGBA32_FLOAT 的 r|0–1，越大越降低历史；透明粒子使用此信息|
|SDK velocity|独立 RG16_FLOAT|同方向，UV 乘以内部宽高转为内部像素；不偷偷复用其他 SDK 的单位|
|hardware depth|R32_TYPELESS 资源、D32_FLOAT DSV|D3D 非线性深度，SDK 若要求深度应使用其专门 SRV，不能拿线性深度冒充|

场景使用 `XMMatrixPerspectiveFovLH`，在这套透视矩阵下 `clip.w=view.z`，所以本课 shader 可以由 current/previous clip.w 写出线性视深度。这不是任意投影矩阵的普遍属性：若改成正交相机，必须另外传递实际 view.z，不能继续把恒为 1 的 clip.w 当深度。

为什么 motionDepth.w 不能等于 z？相机沿 z 前进时，同一个世界点在旧相机中可能深度 4，在新相机中深度 3。历史比较应拿旧深度 4 与旧深度纹理比；把当前 3 拿来比，会把真正匹配的历史全部拒绝。

透明物体没有天然唯一的深度与运动：一个混合像素包含多层表面。本课 reactive mask 降低透明历史权重，仍是单层教学近似。商业引擎会结合透明分层、响应掩码、速度膨胀或专门合成路径；仅增加一张 MV 纹理不能完整解决透明历史污染。

## 4. 常量与生命周期

`PostConstants` 恰好 64 字节，按 HLSL 16 字节寄存器打包：

|DWORD|字段|
|---|---|
|0–3|inputWidth、inputHeight、outputWidth、outputHeight|
|4–7|jitterUV.xy、previousJitterUV.xy|
|8–11|historyWeight、depthRelativeThreshold、fxaaThreshold、fxaaMinThreshold|
|12–15|flags、frameIndex、sharpenStrength、padding|

使用 `SetComputeRoot32BitConstants(rootIndex,16,&constants,0)` 上传 16 个 32 位值；`rootIndex` 是根参数索引，不是 b0 的 register 数字；最后一个参数是目标 DWORD 偏移。本课不把 C++ bool 放进这个结构，以免两种语言布局不同。常量只描述本次 dispatch，没有纹理所有权；纹理与 descriptor 必须活到 Fence 完成。

`HistoryValidity::Begin(frame)` 判定原因；只有本帧写出成功后 `Commit(frame)` 才建立下一帧资格。Camera Cut、显示 Resize、内部动态分辨率变化、FOV 改变、物体传送、曝光标度变化均需要重置。本课不做跨尺寸历史保留与 pre-exposure 补偿，因此选择清晰的失效边界。新出现的局部物体通常由逐像素深度拒绝解决，不能要求整幅图每次都清空。

## 5. 动手与已得到的 CPU 证据

```powershell
python learning/sandbox/d3d12/aa-reconstruction/audit_temporal.py --emit-fixtures
```

`results/f4/cpu-contract.json` 的 27 项检查通过；这份报告明确写 `CPU only`。其中静止 MV=(0,0)，相机向右移动 0.5、点深度 4、90° FOV、aspect=1 的 previous−current UV 为 `(0.0625,0)`；点从 `(1,0,4)` 绕 z 转到 `(0,1,4)` 的 MV 为 `(0.125,0.125)`。正负 jitter 的线性信号验证还证明：当前 `f(x−j)` 以 `x+j` 取样，在非边界处回到 `f(x)`。这些是有已知解析答案的例子，不从 GPU 输出反向拟合期望值。

GPU 的相同四类验证是静止、相机平移、旋转物体、遮挡显露。Motion 可视化入口 `MotionCS` 把像素速度映到颜色：中性值代表零运动，方向要与已知点数值一起判断，单看漂亮色轮不能验收符号。

2026-10-22 的 RTX 5070 GPU 验证累计检查 **101,954 个已知表面点**，CPU 独立投影与 GPU motion 最大 UV 误差 **1.20075×10⁻⁶**。第四组使用 time=1.2、previousTime=1.0，区别于第三组的 0.35/0.30，扩大移动以覆盖不同的显露场景；真正逐像素旧深度拒绝在 F.5/F.10 继续验收，不把 MV 符号正确单独当作拒绝正确。suite 的 D3D12 warning/error 为 0。原始记录见 [GPU 合同报告](../../sandbox/d3d12/aa-reconstruction/results/f4/gpu-summary.json) 与 [四组 motion.csv](../../sandbox/d3d12/aa-reconstruction/results/f4/motion.csv)。

最终 120 帧序列保留 8 相 jitter，但捕获与显示均经过独立 UnjitterCS，回到参考图所在的稳定输出格点；该 pass 的成本也纳入正式 GPU 计时。四种 TAA 模式在 frame 60 Camera Cut 都得到相同显示域 MAE **0.019448**，同时该帧历史接受数为 0，表明重置后消融开关不再改变本帧历史贡献。这里的相同误差只验证重置边界的一致性，不能证明重建质量已经达到商业实现。

**问：48→40 的历史查询向量是多少？** `−8` 内部像素，或 `−8/W` UV。

**问：camera cut 后只是清零 frameIndex 就够吗？** 不够，必须使 `HistoryValid` 为 false，GPU 首帧走不采样历史的分支；旧纹理仍可能保存任意数据。

**问：motion 单位从 UV 改为像素要改什么？** 生产端或消费端必须且只需做一次乘/除尺寸，x、y 分别使用对应宽高；动态分辨率下使用哪一套尺寸也必须固定。

参考：[Karis，High Quality Temporal Supersampling](https://www.realtimerendering.com/advances/s2014/index.html)、[Microsoft Root Signature Limits](https://learn.microsoft.com/en-us/windows/win32/direct3d12/root-signature-limits)。SDK 的具体输入映射在 F.7/F.8 单独核对，不能从本课合同推定它们都相同。
