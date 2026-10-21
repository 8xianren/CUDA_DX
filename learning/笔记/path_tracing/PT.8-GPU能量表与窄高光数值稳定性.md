# PT.8 GPU能量表与窄高光数值稳定性

2026-10-21。[代码与命令](../../sandbox/path_tracing/pt08-materials/README.md)，[共享材质实现](../../sandbox/path_tracing/dxr-path-tracer/README.md)，[上一节推导](PT.8-漫反射与镜面能量耦合.md)。本节完成连续粗糙度查表、GPU材质接入和限定白炉验收；PT.8仍待完整多反弹/MIS主线整合与图像验收。

## 上节答案

1. 单侧B(1-Eo)/pi的半球积分等于B(1-Eo)，但交换wo/wi后因子变成1-Ei，因而不保证互易。
2. 双侧乘积额外引入半球平均剩余量1-Eavg；除以它才能把漫反射积分恢复为B(1-Eo)。
3. 查表比真实E少.002时，白色非金属输出1+E-Etable=1.002；增加路径样本不会消除这个模型近似偏差。

## 要把哪个积分变成GPU数据

各向同性、F0=.04、alpha=r²的GGX单次反射方向反照率为

\[
E(r,c_o)=\int f_s(r,\omega_o,\omega_i)c_i\,d\omega_i.
\]

需要两个自变量：粗糙度r和观察方向余弦co。基础色、metallic不进入这张非金属镜面表；它们仍在BRDF组合中使用。表的模型契约包括Smith高度相关G和Schlick，不能只因文件尺寸相同就把别的BRDF能量表拿来使用。

上节五条曲线不足以支持粗糙度纹理。直接加密入射方向积分也有问题：r接近.01时alpha接近1e-4，镜面峰十分窄，粗网格可能漏掉峰值并产生虚假的低能量。需要将积分采样集中到实际贡献区域。

游戏开发类比：可以把方向表看作离线烘焙数据。运行时每次命中只查小表；离线必须正确捕获窄高光，不能把“烘焙很快、表很平滑”当成积分准确的证据。

## 为离线积分选择可见微面分布

前课NDF采样使用p_h=D(h)h_z，它考虑从宏观法线方向看到的投影。斜视时会采到背向观察者的微面。现在固定wo，改按该方向能看到的投影面积采样，称为VNDF（visible normal distribution function，可见法线分布）。

微面面积密度是D(h)，朝wo的投影因子是max(wo·h,0)。前课Smith投影面积关系给出该分布积分为co/G1(wo)，故归一化后：

\[
p_h(h|\omega_o)=\frac{D(h)G_1(\omega_o)\max(\omega_o\cdot h,0)}{c_o}.
\]

反射方向映射的Jacobian是4|wo·h|，因此

\[
p_i(\omega_i)=\frac{D(h)G_1(\omega_o)}{4c_o}.
\]

将它代入镜面能量积分的估计权重：

\[
\frac{f_s c_i}{p_i}
=\frac{FDG}{4c_o}\frac{4c_o}{DG_1}
=F\frac{G}{G_1}.
\]

对高度相关Smith：

\[
G=\frac1{1+\Lambda_o+\Lambda_i},\quad
G_1=\frac1{1+\Lambda_o},\quad
\frac{G}{G_1}=\frac{1+\Lambda_o}{1+\Lambda_o+\Lambda_i}\le1.
\]

因此每个有效样本的权重在[0,1]内；被反射到宏观下半球的样本贡献0，但仍计入全部样本数。VNDF排除了背向wo的微面，不保证所有反射方向都在宏观表面上方。

用这个估计器烘焙E并不要求改变路径追踪器的采样分布。当前GPU路径仍是NDF/余弦混合，离线表的采样策略与运行时路径的采样策略属于两个不同积分任务。

实现采用Heitz的GGX可见法线参数化；论文给出从椭球投影到半球投影的几何推导：[Heitz 2018](https://jcgt.org/published/0007/04/01/paper.pdf)。

## 几何参数化的具体步骤

`vndf_energy.h:19`是CPU double积分，固定wo=(sqrt(1-co²),0,co)。先用A=diag(alpha,alpha,1)把观察方向映射到单位半球：Vh=normalize(A*wo)。选择T1=+Y，T2=(-Vh.z,0,Vh.x)，与Vh构成正交基。

均匀圆盘点(p.x,p.y)在固定横坐标x下，纵向范围是[-sqrt(1-x²),sqrt(1-x²)]。可见上半球投影的对应范围是[-Vh.z*sqrt(1-x²),sqrt(1-x²)]。因此用

\[
s=(1+V_h.z)/2,\quad y=(1-s)\sqrt{1-x^2}+s p.y
\]

映射纵坐标。它在每个截面上的缩放都是s，二维Jacobian也是常量s，所以保持投影区域上的均匀面积分布。随后令z=sqrt(max(0,1-x²-y²))，得到Nh=xT1+yT2+zVh，再用法线变换normalize(A*Nh)回到GGX分布。这里不是把普通方向任意乘roughness：前后分别是在处理观察方向与几何法线的变换。

离线点使用Hammersley结构：u=(i+.5)/N，v为i的32位反转值加半单位后除2³²；圆盘半径sqrt(u)、方位2pi*v。第二套参考对反转前的整数做固定XOR扰动，并增加点数。它是确定性的低差异积分，不是IID随机样本，不能套普通样本标准误差声称严格置信界。

`Integral(alpha,co,points)`返回全部点权重均值。为处理co=0构表端点，先代数化简：设Ro=sqrt(co²+alpha²(1-co²))、Ri同理，则

\[
G/G_1=(c_o+R_o)/(R_o+c_oR_i/c_i).
\]

co=0时该式极限为1，不需要先产生infinity再相除。调用者给alpha>0、co∈[0,1]、非空点集；delta分支不进入此表生成器。

## 二维表布局与插值

共享CPU逻辑格式见`dxr-path-tracer/energy_lut.h:13`，GPU查询见`energy_lut.hlsli:11`。

| 数据 | float索引/数量 |
|---|---|
| 头 | 0..3，值为129、257、1e-4、33157 |
| E表 | 从4开始，129行×257列，行主序 |
| 每行平均E | 从33157开始，129个 |
| 总大小 | 33286个float，133144字节 |

HLSL声明StructuredBuffer<float>，元素步长4字节；它不是Texture2D，没有sRGB、纹理过滤或mipmap语义。每行步长257个float=1028字节，不要求行按16字节补齐。共享CPU vector本身不能直接上传，只上传其连续data存储。

粗糙度轴通过alpha取对数分布：

\[
\alpha_i=10^{-4}(10^4)^{i/128},\quad r_i=\sqrt{\alpha_i}.
\]

方向轴使用更密集的掠射节点：

\[
c_j=(j/256)^4.
\]

查询时x=128*log2(alpha/1e-4)/log2(1e4)，据此确定两行及权重tr；方向先用c的四次方根定位区间，再以真实余弦计算tc=(c-cj)/(cj+1-cj)。在两行内分别按tc插值，然后按tr混合。

Eavg由**已经量化成float的节点函数**精确分段积分后写成float；Load再次计算并检查一致性。粗糙度插值时也用同一tr插值Eavg。由于积分是线性的，行间线性组合的平均就等于两行平均的同权重组合。注意：E和Eavg仍有float舍入，故数值白炉不是严格实数恒等式。

alpha<=1e-4继续走解析delta E=.04+.96(1-c)^5、Eavg=3/35，不在delta与连续峰之间盲目做二维表插值。阈值属于已经声明的应用近似。

生成时每格比较4096与16384点，差超过1e-4时增加到65536点，最终差必须≤3e-4；另用512个非节点r/c和262144点扰动参考检验插值，并与20个原Gauss方向积分交叉检查。有限检查是数值证据，不是覆盖所有实数参数的严格误差上界。

## 上传、绑定、同步和失败路径

`pbr_energy::Load(const std::filesystem::path&)`按固定字节数读入Table，验证头、所有数值有限且位于[0,1]、平均<1且匹配节点积分。缺失/截断文件、格式不匹配、非法值或平均不一致都抛异常。当前文件是Windows实验用float32二进制，不是通用跨平台资产格式；更换模型必须重建表。

宿主调用既有helper：

```cpp
ComPtr<ID3D12Resource> InstanceUpload(
    UploadContext& c, const void* bytes, size_t size);
```

c提供D3D12设备；bytes指向CPU连续数据；size为133144。helper创建UPLOAD/GENERIC_READ buffer，Map的{0,0}表示CPU不读旧内容，memcpy后用写入范围Unmap。返回ComPtr由MaterialBindings::energy持有；提交期间不得改写/释放它。CPU vector与GPU资源分别拥有自己的存储。

共享根签名新增参数数组索引10，映射t7、space0；t0..t6、u0以及两张descriptor table的旧索引保持原契约。实际API：

```cpp
void ID3D12GraphicsCommandList::SetComputeRootShaderResourceView(
    UINT RootParameterIndex,
    D3D12_GPU_VIRTUAL_ADDRESS BufferLocation);
```

本课第一个参数是10，第二个是energy buffer的GPU虚拟地址。**根参数索引10与HLSL寄存器t7不是同一个编号系统**；映射由根签名Descriptor={7,0}建立。该函数无HRESULT返回，错误需由正确的资源/根签名契约和Debug Layer诊断，不能把CPU指针传进去。支持StructuredBuffer的根SRV，不需要给能量表额外分配descriptor heap槽。[API文档](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12graphicscommandlist-setcomputerootshaderresourceview)、[根描述符支持范围](https://learn.microsoft.com/en-us/windows/win32/direct3d12/using-descriptors-directly-in-the-root-signature)。

没有能量表的旧shader不会访问t7；调度器为旧路径绑定一个仍有效的备用buffer地址。修正shader以PBR_ENERGY_BALANCED编译，调用者必须提供匹配的energy资源，不能把备用绑定当作有效能量表。

DispatchMaterialBuffer仍按同队列Dispatch→UAV转COPY_SOURCE→复制Readback→SubmitWait→Map读回执行。ComPtr保持到Fence完成以后；能量表在多个dispatch之间只读复用。本次选择UPLOAD直读是小型验收的简化，长期静态表在独显上通常可以上传到DEFAULT资源，采用同样SRV查询机制；不能据此把UPLOAD常驻当成生产带宽优化。

## 窄高光下不能丢掉已经采到的微面法线

原采样器先生成h，反射得到wi=2(wo·h)h-wo，再在Eval中normalize(wo+wi)重新算h。在精确算术下两者相同，但当wo与wi几乎相反时，加法的有效数字大量丢失。

实际失败点：r≈.0105199、co≈6.348e-8，wi≈(-.999999881,-1.067e-7,.000444097)。此时wo.x+wi.x是两个接近±1的float之和；微小绝对误差会显著改变归一化半角和窄GGX峰值。

修正：`pbr.hlsli:14`将已知h作为PbrEvalHalf参数；`PbrDraw:36`保留生成法线到halfVector，直接传给BRDF/PDF计算。余弦分支仍由两方向构造h；delta分支继续独立。它没有改变NDF或PDF数学定义，也没有将粗糙度强制提高。

探针把原h读回，CPU验证它符合相同随机数生成的NDF法线、符合反射映射，再用double重算PDF和权重。重新构造h的旧写法作为GPU负对照保留，最大|p_reconstructed-p_preserved|/(1+p_preserved)=2413.77。这个量是PDF误差指标，不能说成图像亮度增加2413倍。

修正后宽参数扫描的权重归一化误差≤4.17281e-7。一般Eval在两个独立方向几乎反平行时仍会受输入float精度限制，本次修复的是采样路径不必要地丢弃已知h的问题；不能声称所有可能方向的任意精度计算已解决。

## 本机验收与复现

仓库根目录运行，脚本自行定位课程与共享工程：

```powershell
.\learning\sandbox\path_tracing\pt08-materials\verify_energy_gpu.ps1
python .\learning\sandbox\path_tracing\pt08-materials\plot_energy_gpu.py
```

宿主用VS2022/CMake Release，shader用DXC lib_6_3/HV2021；离线构表纯CPU，路径实际在RTX5070执行DXR，没有CUDA kernel。可执行文件都在本课build/Release。

从本课目录单独执行：

```powershell
.\build\Release\energy_lut_build.exe .\results\energy-gpu
.\build\Release\pbr_test.exe .\results\energy-gpu\pbr.gltf .\results\energy-gpu\pbr.dxil .\results\energy-gpu .\results\energy-gpu\energy-lut.bin
```

构表参数为结果目录；GPU程序参数依次为glTF、DXIL、结果目录、能量表。省略最后一个参数只用于旧基线shader，两者必须配套。结果直接写results/energy-gpu，包含二进制表、glTF/纹理、DXIL、offgrid/summary/samples CSV、日志、PNG/SVG；旧模型在negative-baseline子目录。共享D.3/D.4回归也由脚本运行并记录日志。

2026-10-21结果：

| 项目 | 实测 |
|---|---:|
| LUT | 129×257，133144字节；7285格加密 |
| 最大细化变化 | .000108143699457 |
| 512表外点最大误差 | .000285060336933 |
| 20个独立方向积分最大差 | 1.74125330887e-6 |
| GPU查询/BRDF探针 | 40960；其中40320个co>0执行采样 |
| GPU查表与CPU最大差 | 1.8275917868e-7 |
| 探针BRDF归一化差 | 4.81346626305e-5 |
| 探针采样权重归一化差 | 4.17281044123e-7 |
| 探针互易性归一化差 | 2.78493880614e-5 |
| 正确模型白炉路径/TraceRay | 1966080 / 3648139 |
| 逐路径权重归一化差 | 7.18172771035e-7 |
| 已测白色材质最大独立积分 | 1.0000696488 |
| Fence/Debug/Validator | 50/50；0；0错误0警告 |

r=.25、80°、ps=.5、第一象限的GPU红均值.999999765928，SE=.00429494186654，目标1.0000696488。ps=.8均值1.0002336318，SE=.0127393978446。图里合并四象限，误差条为3SE；测试门槛为各组6SE+.0001。GPU采样误差、表近似偏差、逐字段浮点差是不同量，不应混在一起解释。

旧模型再次独立跑1966080路径/3648139 TraceRay，能量反例1.26865688666仍存在，Fence49/49、Debug0；D.3十二组与D.4边界回归通过。全参数探针没有执行TraceRay，因此它的40320次采样不能混入真实路径/射线计数。

![GPU能量表实测](../../sandbox/path_tracing/pt08-materials/results/energy-gpu/energy-gpu.png)

## 边界与下一节

当前模型仍是单次GGX镜面加剩余能量近似漫反射；金属微面多次散射未补偿。保留前课OPAQUE、单面、UV0、几何法线、mip0的glTF能力边界。图为统计数据，不是完整路径追踪场景的粗糙度扫描渲染；后者与共享多反弹/NEE/MIS主线一起继续完成。

自测：为什么离线VNDF构表不要求GPU路径也改为VNDF？为什么Eavg必须跟随E使用相同的粗糙度插值权重？根参数10为何能对应t7？下一小节直接给答案，然后推进共享积分器与图像验收。
