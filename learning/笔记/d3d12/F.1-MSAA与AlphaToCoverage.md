# F.1 多采样覆盖、MSAA 与 Alpha-to-Coverage

本节目标：解释像素覆盖的离散近似，并亲手建立1×/4×颜色与深度资源、匹配PSO，将4×颜色直接Resolve到单采样交换链。[共享工程](../../sandbox/d3d12/aa-reconstruction/README.md)，[场景实现](../../sandbox/d3d12/aa-reconstruction/src/scene.cpp)，[验收入口](../../sandbox/d3d12/aa-reconstruction/src/main.cpp)。

## 1. 先有面积问题，再有采样方案

把像素想成摄影机感光面的一小块区域，而不是一个没有面积的数学点。对像素区域A，固定时间下理想的过滤颜色为 `C=∫A L(x,y)w(x,y)dxdy`，其中w已归一化。先只讨论两个常色表面的边缘，前景覆盖比例为a，背景为1−a，则积分退化成 `C=aCf+(1−a)Cb`。锯齿不是三角形“没有画直”，而是用一次中心判断代替覆盖面积：a只能取0或1。

如果在A内选择N个位置，使用 `a≈(1/N)Σ covered(sample_i)`，a就有更多离散取值。N=4时可能得到0、1/4、1/2、3/4、1；它仍是近似，不能把四个位置说成完整面积积分。几何逐渐移动时，覆盖变化的阶梯变细，但高频材质、镜面高光、动画时间采样仍可能闪烁。

MSAA维护每样本的覆盖和深度/模板状态；普通像素频率的PS结果可用于多个被覆盖样本。只有明确采用sample-frequency执行等机制时，才不能继续按“一像素一次PS”理解。因此4× MSAA不保证着色成本恰好4倍，也不等于路径追踪4条独立随机路径。光栅覆盖、材质着色与蒙特卡洛积分是不同的工作。

## 2. 能力查询不是根据显卡名字猜

```cpp
HRESULT ID3D12Device::CheckFeatureSupport(
    D3D12_FEATURE Feature, void* pFeatureSupportData,
    UINT FeatureSupportDataSize);

D3D12_FEATURE_DATA_MULTISAMPLE_QUALITY_LEVELS q{
    format, sampleCount, D3D12_MULTISAMPLE_QUALITY_LEVELS_FLAG_NONE, 0};
device->CheckFeatureSupport(D3D12_FEATURE_MULTISAMPLE_QUALITY_LEVELS,
                            &q, sizeof(q));
```

`Feature`选择要查询的结构；`pFeatureSupportData`同时包含输入和返回字段；`FeatureSupportDataSize`必须是该结构实际字节数。q的`Format`是资源视图使用的具体格式，`SampleCount`是1或4，`Flags`选择查询选项，返回的`NumQualityLevels==0`表示该组合不可用。不能只查询颜色、忘记深度和其它同时写入的MRT。本实现依次检查RGBA8/RGBA16F、RGBA32F运动信息、R32F线性深度、RG16F像素运动、R8响应遮罩、D32F。

本课固定使用`SampleDesc.Quality=0`，只要查询确认至少一个质量级别即可。质量级别索引不是画质评分。失败时抛出明确错误，不创建一个采样数不一致的管线继续黑屏。

## 3. 资源、视图和PSO必须共同描述同一次光栅化

资源的`D3D12_RESOURCE_DESC.SampleDesc.Count`决定实际样本存储。4×颜色设置`ALLOW_RENDER_TARGET`；深度资源使用`R32_TYPELESS`存储、`D32_FLOAT` DSV，并设置`ALLOW_DEPTH_STENCIL`。深度将来作为SRV读取时使用`R32_FLOAT`，不能建立TYPELESS SRV。

RTV/DSV的`ViewDimension`在1×时分别为`TEXTURE2D`，在4×时为`TEXTURE2DMS`。同时绑定的颜色和深度样本数必须相同；PSO的`SampleDesc.Count`也必须匹配。PSO还固定RTV格式、DSV格式、着色器、拓扑类型和混合状态。只把PSO改成4而不重建资源，不会神奇地为已有纹理增加样本。

共享场景把几何、MRT及材质意图放在Scene模块；GPU资源和状态跟踪放在gpu_resources；主程序只选择实验。它复用C/D的`UploadContext`，没有复制人物系统或路径积分器。F主线是独立光栅/重建实验室，H人物Demo目前并未自动换成这些模式。

## 4. Resolve：合并样本，不是任意尺寸缩放

```cpp
void ID3D12GraphicsCommandList::ResolveSubresource(
    ID3D12Resource* pDstResource, UINT DstSubresource,
    ID3D12Resource* pSrcResource, UINT SrcSubresource,
    DXGI_FORMAT Format);
```

`pDstResource`指向单采样Default资源，`DstSubresource`选择其子资源；`pSrcResource`指向多采样资源，`SrcSubresource`选择源；`Format`规定Resolve解释格式。本课都是一层、一张二维纹理，两个子资源索引均为0。源与目的尺寸一致，格式必须兼容。对普通颜色进行样本合成，不把它当作通用深度Resolve策略。

实际顺序为：场景颜色`RENDER_TARGET → RESOLVE_SOURCE`；交换链当前BackBuffer`PRESENT → RESOLVE_DEST`；调用Resolve；可选转换成`COPY_SOURCE`做读回；最后转`PRESENT`并Present。1×对照则是颜色`COPY_SOURCE`、BackBuffer`COPY_DEST`的等尺寸复制。Flip交换链本身始终是1 sample。

命令只被录制时，GPU尚未完成。源、目的、命令allocator都必须活到覆盖提交的Fence完成。本课`SubmitWait`逐批等待，便于验证；商业引擎通常使用多帧资源与延迟回收，但同样不能提前重置allocator或释放被GPU引用的资源。

F1使用RGBA8目标直接演示Resolve。它的显示图用于覆盖差异，不作为HDR色彩处理基准；F2以后的质量评测统一使用线性RGBA16F并在显示阶段进行色调映射和sRGB编码。

## 5. Alpha为什么能控制覆盖，却不能代表所有透明情况

本课“叶片”使用连续Alpha `saturate(sin(48u+5v)*2+0.5)`。普通裁剪执行`clip(alpha−0.5)`；A2C保留连续alpha，将PSO的`BlendState.AlphaToCoverageEnable`打开。硬件根据alpha产生覆盖掩码，与几何覆盖相交，控制哪些样本写入。

`IndependentBlendEnable=TRUE`使MRT分别使用自己的混合描述。本课半透明粒子的颜色采用SrcAlpha/InvSrcAlpha，其运动/遮罩按覆盖表面写入；这是单层教学近似，不解决多层透明运动和光学透射。A2C的量化覆盖也不是按深度排序的通用alpha混合。

对照商业引擎：植被可能使用A2C、随机透明、时间抖动裁剪及专门的遮罩历史策略；具体选择取决于渲染路径。这里把clip与A2C明确切开，学习的仍是同一套样本覆盖、深度与Resolve机制。

## 6. 本机动手与结果

从仓库根目录运行：

```powershell
& learning/sandbox/d3d12/aa-reconstruction/build.ps1
& learning/sandbox/d3d12/aa-reconstruction/build/Release/f_lessons.exe suite
```

2026-10-22，RTX5070/驱动610.88：640×360，同一场景1×→4×改变6,117个像素的红通道，4×clip→4×A2C又改变1,352个；三次真实Present、BackBuffer单采样、两次直接Resolve。差异只证明该场景覆盖行为不同，不自动等于所有区域误差下降。报告见[summary](../../sandbox/d3d12/aa-reconstruction/results/f1/summary.json)，图片由程序写本课`results/f1/`。完整suite最终D3D12 warning/error为0。

首次运行曾因未提供优化清除值出现性能提示；现在创建资源时使用与实际Clear一致的值，并完整重跑通过。没有屏蔽Debug信息来制造零错误。

自测与答案：①是否只改PSO Count就能开启4×？不能，资源和RTV/DSV也要匹配。②Resolve能把640×360变成1280×720吗？不能，这是后续缩放问题。③4× MSAA是否解决程序棋盘材质的全部闪烁？不能，它主要增加覆盖/深度样本，不保证四次独立材质采样。下一节把离屏颜色变成可组合的后处理输入。

依据：[多采样能力](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ns-d3d12-d3d12_feature_data_multisample_quality_levels)、[ResolveSubresource](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12graphicscommandlist-resolvesubresource)、[Blend描述](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ns-d3d12-d3d12_blend_desc)。
