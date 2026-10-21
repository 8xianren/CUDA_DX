# PT.8：glTF材质与GPU混合采样

2026-10-21。专项代码：[pt08-materials](../../sandbox/path_tracing/pt08-materials/README.md)；共享材质层：[dxr-path-tracer](../../sandbox/path_tracing/dxr-path-tracer/README.md)；结果：[results/pbr](../../sandbox/path_tracing/pt08-materials/results/pbr/)。

本节完成真实DXR材质读取和GGX/余弦混合采样，检验改变采样概率是否改变均值。同时发现并保留基线漫反射/镜面耦合的能量反例。**GPU采样实现通过，不代表整个材质模型物理正确，PT.8仍进行中。**

## 上节答案与本节问题

D描述微表面实际面积，D(m)m.z才是本课法线采样PDF。丢弃null样本再沿用原PDF会改变目标。单次微反射的F0=1白炉结果可以小于1；alpha1正视解析值为1-ln2，不能把模型损失和积分错误混为一谈。

现在一块塑料表面既有镜面高光，也有体内散射形成的漫反射。一个像素可能覆盖金属和非金属区域，glTF还提供metallic参数。需要区分三层：材质由哪些反射分量组成；选择哪种方向分布进行采样；生成方向后用什么概率补偿。

## 先定义材质，不先决定随机分支

令B为线性RGB基础色，m为metallic，r为roughness，alpha=r²。令S=D*G/(4cos_o cos_i)表示不含Fresnel的GGX因子，Fd=Schlick(.04,wo·h)，Fm=Schlick(B,wo·h)。

按glTF材质混合图，先定义：

f_dielectric=(1-Fd)B/pi+Fd*S；
f_metal=Fm*S；
f=(1-m)f_dielectric+m f_metal。

展开可得：

f_diffuse=(1-m)(1-Fd)B/pi；
f_specular=[(1-m)Fd+m Fm]S。

因为Schlick对F0线性，可定义F0mix=(1-m)*.04+m*B，使镜面项化为Schlick(F0mix,wo·h)*S。**漫反射项仍使用Fd，而不是F0mix对应的F。**

注意[glTF附录B](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#appendix-b-brdf-implementation)同时包含材质混合图和实用示例。其简化代码把混合后的F也用于漫反射；对0<m<1，它与上面的显式线性混合图不是严格相同的代数表达。本课采用显式材质混合图，并完整记录这一选择，不把两种表达式说成恒等式。此基线Fresnel耦合本身也不是严格能量守恒的层状散射模型，后面的白炉会验证而非假定它正确。

metallic是材质参数，改变它会改变积分目标；采样概率ps是数值策略，正确实现中改变ps只能改变方差和成本。金属通常没有此模型的漫反射项，B成为法向镜面反射颜色；非金属B是漫反射颜色，表面F0固定.04。中间metallic可描述像素覆盖或纹理过滤后的混合，不应直接解释为“金属有一半概率变成塑料”。

## 从全概率公式推导混合PDF

目标为I=∫f(wo,wi)Li(wi)cos_i dωi。令g(wi)=f Li cos_i。

先以ps选择GGX方向生成器，其条件密度为p_G；以1-ps选择余弦生成器，其条件密度为p_C=cos_i/pi。无论wi实际由哪个分支产生，边缘密度为：

p_mix(wi)=ps*p_G(wi)+(1-ps)*p_C(wi)。

因此单样本估计器是g(wi)/p_mix(wi)。验证其期望：

E[X]=ps∫p_G g/p_mix dω+(1-ps)∫p_C g/p_mix dω
    =∫[ps p_G+(1-ps)p_C]g/p_mix dω=∫g dω=I。

GGX的null事件仍计入总样本分母，其贡献是零；p_G在有效宏观半球上的积分可以小于1。它不影响上述对非零贡献方向的证明。

代码在pbr.hlsli中用同一PbrEval计算完整f和混合PDF，无论方向来自GGX还是余弦，都执行weight=f*cos_i/pdf_mix。本节对有漫反射的材质比较ps=.5与.8；纯金属或B全零时ps=1。后者避免对零漫反射分量分配不必要预算。ps并不等于metallic。

## 为什么“总BRDF除以选中分支PDF”会重复计算

若GGX分支使用g/(ps*p_G)，余弦分支使用g/((1-ps)*p_C)，且两种分布都覆盖积分的有效方向，则：

E[Xwrong]=ps∫p_G*g/(ps*p_G)+(1-ps)∫p_C*g/((1-ps)*p_C)=I+I。

分母中虽然包含了选择分支的概率，仍然重复估计整个积分。这与PT.6两种直接光估计器不加权直接相加的错误有相同结构。

另一种正确做法是分量估计：选GGX时只估计f_specular，选余弦时只估计f_diffuse，再分别除以分支概率和条件PDF。它与本课“完整f / 混合PDF”的估计器不同，但同样可以无偏。不能泛化成“选中分支PDF永远不能用”；问题在于分子是否仍然用了完整BRDF。

## delta与连续分量共存

roughness²<=1e-4沿用上一节明确的delta近似。此时镜面分量不再具有有限连续PDF。

选中镜面：返回反射方向、离散mass=ps、weight=Fspec/ps、连续pdf=0、event=3。不能把余弦PDF的有限数值加进这个离散概率质量。

选中漫反射：Eval的连续镜面部分为零，返回f_diffuse；连续PDF=(1-ps)p_C，按该密度更新权重。纯金属delta时ps=1，全部样本只走镜面。后续灯命中MIS必须使用事件类型区分离散/连续，不能只看数值pdf是否很小。

PbrSample事件1为合法null，2为连续方向，3为delta；事件0表示异常或本fixture出现预期外几何命中。测试中连续或delta样本都发真实第二条射线，必须Miss，才符合白炉Li=1；null样本只发主射线。

## 从glTF到shader的数值链

本节生成10块并排的独立平面，每块使用不同材质，最后一块绑定2×2基础色、金属粗糙度、发光纹理，并有非白顶点色。三种观察角为0/60/80°。调整相机起点抵消斜率，使每种角度都命中相同网格中心，隔离几何与材质变化。

基础色：B=baseColorFactor.rgb*vertexColor.rgb*DecodeSRGB(baseColorTexture.rgb)。

金属度：m=metallicFactor*metallicRoughnessTexture.b。

粗糙度：r=roughnessFactor*metallicRoughnessTexture.g，随后alpha=r²。

发光：Le=emissiveFactor.rgb*DecodeSRGB(emissiveTexture.rgb)。

MR纹理为线性数据，不能sRGB解码，红通道不是本槽的金属度或粗糙度。本节纹理故意为R/G/B填不同码值以暴露通道错误。缺失MR或发光纹理时采样值默认1；无发光由emissiveFactor=0表达。基础色缺失槽复用共享上传层的白纹理。

基础色和发光通过SRGB SRV在硬件采样时解码；factor与顶点色已经是线性数值，不再解码。当前只用mip0，SampleLevel显式传0；不声称拥有ray footprint或正确的跨mip过滤。固定Assimp版本已把V翻转，shader在采样边界恢复uv.y=1-uv.y。

发光读取单独验收。白炉统计只统计反射权重，不把Le加进去，否则“输出超过1”可能只是自发光，无法判断反射模型是否增加能量。本节还没有把这个材质层接到完整逐跳发光/NEE/MIS循环。

## 身份、几何、payload与材质布局

ClosestHit仅返回16B Payload：uint instancePlus、uint primitive、float2 bary。instancePlus=0表示Miss，否则减1索引对象表。RayGen利用身份和重心坐标读取几何/材质。这样后续路径仍能顺序TraceRay，不在ClosestHit里递归，流水线最大嵌套深度保持1。

对象表为80B world矩阵与material/node/mesh索引；网格表16B记录firstVertex/firstIndex/indexCount/pad。PrimitiveIndex是当前BLAS的三角形编号；每BLAS只有一个geometry，因此三角形索引地址为4*(firstIndex+3*primitive)，读出三个局部顶点索引后，加firstVertex再乘48B顶点步长。

Vertex布局仍是position偏移0、normal偏移12、UV偏移24、color偏移32，共48B。当前共享surface读取器使用实际变换后三角形边的叉积作为几何法线，尚未使用插值法线或法线贴图；本节全部平面world恒等，未声称完成任意变换网格的新增验收。

材质表PbrMaterialRecord为64B：

|偏移|字段|
|---:|---|
|0|float4 base factor|
|16|float4 emission factor，w保留|
|32|float metallic|
|36|float roughness|
|40、44|uint baseTexture、mrTexture|
|48|uint emissionTexture|
|52、56、60|uint baseSampler、mrSampler、emissionSampler|

每个材质三个sampler允许各纹理槽采用自己的过滤/寻址约定。该布局不是glTF文件布局，而是渲染器上传到GPU的协议。StructuredBuffer按64B步长读取。CPU static_assert检查尺寸和metallic偏移。

每路径输出128B Record：baseMetal、pointRough、normalPs、outgoingPdf、weightMass、emissionU0、random12Uv各float4，最后uint4 tags存事件/采样分支/材质ID/TraceRay次数。640×64线程一批40960路径，一次读回5242880B。它是审计记录而不是生产帧缓冲格式。

## 关键接口与所有权

共享材质工厂：

```cpp
MaterialBindings PreparePbrBindings(
    UploadContext& context,
    const CpuScene& cpu,
    const GpuScene& gpu);
```

context提供设备；cpu提供材质语义；gpu提供配套纹理descriptor和网格范围。返回对象拥有两张Upload表与shader-visible sampler heap，不借用CpuScene数组内存；实际纹理仍由GpuScene拥有。工厂只创建/写资源，不录制Dispatch、不提交或等待。

它明确拒绝MASK/BLEND、doubleSided、UV非0、normal/AO纹理、越界或非有限参数；当前GPU能力没有实现这些语义。测试实际验证MASK和normal map拒绝路径。AO在真实路径追踪中也不能不加分析地乘到全部光照，本课暂不接入。

后端抽出统一接口：

```cpp
std::vector<uint8_t> DispatchMaterialBuffer(
    UploadContext& context,
    const MaterialBindings& bindings,
    const GpuScene& gpu,
    const InstanceFrame& frame,
    const void* config, size_t configBytes,
    UINT width, UINT height, size_t outputBytes,
    const std::filesystem::path& dxil);
```

bindings提供网格/材质Upload表与sampler heap，必须与gpu和shader结构布局匹配；frame提供TLAS和对象表。config/configBytes为t6的自定义配置；width/height决定Dispatch线程网格；outputBytes为u0结果大小；dxil选择shader。返回vector拥有CPU字节副本。

根参数0..6分别绑定t0 TLAS、t1对象、t2顶点、t3索引、t4网格、t5材质、t6配置；参数7绑定u0结果；参数8/9是纹理SRV表与sampler表。Texture2D不能用根buffer SRV的GPU地址替代，必须通过descriptor table访问。非一致材质索引使用NonUniformResourceIndex。

两个heap分别为CBV/SRV/UAV和Sampler类型，由SetDescriptorHeaps绑定。配置为Upload Heap；输出为Default/UAV，读回为Readback/COPY_DEST。Dispatch后将输出UAV→COPY_SOURCE，CopyBufferRegion，同队列SubmitWait完成后Map。Map不会代替Fence等待。

调用者保留GpuScene、BLAS、TLAS和bindings到所有调用完成；函数内配置、SBT、管线和读回资源也保留到Fence。失败抛异常并退出验收进程，没有设备丢失恢复或异步退役。本节继续使用固定尺度1/1024法线起点偏移，不能直接当成任意场景的误差界。

D.3旧SampleHitMaterials成为这个通用函数的薄封装，MakeTextureSamplerDesc也抽出供两条线路共享，避免复制一套上传/绑定/调度实现。变更后重新构建并完成D.3的12组采样回归，以及D.4程序化场景/源CPU销毁/非法sampler回归。

## GPU验证和已发现的能量问题

2026-10-21 RTX5070：10材质×4象限×3角度×2采样概率，每组8seed×1024样本，共1966080路径、3648139次TraceRay。所有主命中材质身份、UV、几何点、MR通道、基础色/发光解码、分支、方向、混合PDF、权重和第二射线Miss均通过。

逐路径权重最大归一化差1.04485e-6；基础色与解析sRGB参考最大绝对差.000339887；命中位置差9.53674e-7。Fresnel/GGX审计使用已独立核对过的实际GPU材质值，避免把硬件sRGB解码近似误差误归因于BRDF。白炉参考也使用这些已审计的材质值，方向积分则独立于随机采样器。

Fence49/49，Debug/GPU Validation警告错误0，Khronos Validator错误/警告0。统计均值在6SE+.0001内。错误“总f/选中分支PDF”的均值与2倍积分按8SE+.0002检验；尖锐高光下该错误估计器方差很高，单行有限样本不一定肉眼接近两倍，必须同时看SE。

例如tile5、象限0、正视、metallic=.5、B=(.5,.3,.1)、roughness=.5：参考红值.487269684，ps=.5时GPU均值.488886950、SE .000937242；ps=.8时.490577402、SE .001621345。错误选中PDF均值分别为.982749158与.983019672，目标2倍参考为.974539368。

白色非金属tile0，roughness=.25的独立积分：

|观察角|白炉红值|
|---|---:|
|0°|.999751741830|
|60°|1.02610625360|
|80°|1.26865688666|

80°时象限0、ps=.5的GPU均值1.271053738、SE .006987375，与CPU一致。换成ps=.8仍吻合同一目标。因此问题不在随机分支概率或漏除PDF，而在基线反射函数本身。

原因是微镜Fresnel控制镜面反射与宏观Lambert项的这套简化耦合，没有保证对整个入射半球积分后，漫反射剩余能量恰好与粗糙镜面实际反射能量互补。上一节单独验证GGX不产生额外能量，不能推出加上漫反射以后仍守恒。

summary.txt明确写出MODEL_ENERGY_FAILURE。不能用clamp最终颜色、降低曝光或调整采样概率把它遮掉；这些操作不能修正反射模型。本节交付的是可复现反例和已验证的采样/材质接口，**尚未完成PT.8完整能量验收**。下一小节将从方向反射能量出发，建立互易、能量一致的漫反射耦合，再复测同一白炉。

![GPU统计图](../../sandbox/path_tracing/pt08-materials/results/pbr/pbr-mixture.png)

## 命令与动手

从仓库根目录：

```powershell
.\learning\sandbox\path_tracing\pt08-materials\verify_pbr.ps1
python .\learning\sandbox\path_tracing\pt08-materials\plot_pbr.py
```

脚本按自身路径定位。宿主CMake VS2022构建，shader DXC lib_6_3/HV2021，执行真实DXR，无CUDA kernel。直接运行参数为glTF、DXIL、输出目录：从pt08-materials目录执行`./build/Release/pbr_test.exe ./results/pbr/pbr.gltf ./results/pbr/pbr.dxil ./results/pbr`。

results/pbr包含生成glTF/bin/PNG、DXIL、summary.csv、samples.csv、summary.txt、构建/运行/验证/回归日志，以及统计PNG/SVG。绘图沿用上节隔离matplotlib；验收程序不依赖绘图库。

动手看summary.csv的同angle/tile/quadrant、不同mode：目标不变，方差不同；再看samples.csv中tile6纯金属镜面的mass=1/pdf=0与tile7镜面非金属的离散/连续分流。tile9四象限验证MR纹理的G/B通道和顶点色乘法。

## 自测与下一节

1. metallic=.5是否要求采样GGX的概率也等于.5？不要求。前者定义材质，后者定义数值采样策略。
2. 选中了GGX，为什么仍要计算余弦PDF？因为本课用完整BRDF除以边缘混合密度，该方向也可能由另一策略产生。
3. GPU和CPU结果一致是否证明物理正确？只证明两者实现/估计了相同模型；白炉1.26866证明这个基线模型仍需修正。

引擎通常把这些能力放进统一材质和着色系统，并可能使用不同的散射近似、预积分表、可见法线采样和多次散射补偿。本课保留可审计的NDF与明确的基线错误，不把固定几何法线/mip0/逐批Fence等待包装成生产方案。后续继续完成能量耦合与完整主线集成。
