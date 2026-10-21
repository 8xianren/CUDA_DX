# PT.8 共享积分器与粗糙度场景验收

2026-10-21。至本节，PT.8按既定教学模型完成：方向/Fresnel专项、glTF参数、GGX白炉、delta与数值扫描、共享DXR多反弹图像均已验收。后续依授权进入PT.10。本节仍有明确的材质、介质与数值边界，不能把它称为完整商业渲染器。

[代码、命令与输出](../../sandbox/path_tracing/dxr-path-tracer/README.md)；[上一节GPU能量表](PT.8-GPU能量表与窄高光数值稳定性.md)。

## 上节自测答案

1. 离线VNDF用于估计方向反照率；运行时NDF/余弦混合用于估计渲染方程。两者只需各自PDF正确，不必使用同一种分布。
2. 插值后的E函数是两行函数的线性组合；积分具有线性性质，Eavg必须用同一权重组合才与它匹配。
3. 根参数数组索引和HLSL寄存器是不同编号系统。根签名把参数10的Descriptor设为{7,0}，因此API写参数10，shader读t7/space0。

## 从单次材质测试到完整路径

白炉检验一个表面如何重新分配能量；现在把这些表面放进同一个场景，让光在它们之间传播。游戏直觉：金属球不仅反射灯，还会反射下方的红球与地板；玻璃需要依次经过进入、内部传播、离开边界，才可能看见后方物体。

同一材质接口必须支持两种操作：Eval在指定方向上求连续BRDF和PDF；Draw生成一个方向并返回已经除PDF或离散概率的权重。积分器不应该为每种材质复制一套发光、NEE、RR和求交循环。

因此每条路径持有origin/direction、RGB beta、累计L，以及previousPoint/previousPdf/previousDelta。再加介质身份medium和RR用的etaScale。RayGen顺序调用TraceRay，ClosestHit只返回实例/三角形/重心；State Object最大递归深度仍是1。

## 两种策略会计算同一条直接光路径

在顶点x，选中灯上y点的直接贡献为

\[
C=\beta f(x,\omega_o,\omega_i)L_e(y,-\omega_i)c_i V(x,y).
\]

NEE抽灯点得到C/pL；BSDF抽方向也可能命中同一个灯，得到C/pB。两者都是同一积分的估计器，直接相加会重复计算。

本课每个可连续散射的顶点各用一个灯样本和一个BSDF样本，选择Power权重：

\[
w_L=\frac{p_L^2}{p_L^2+p_B^2},\quad
w_B=\frac{p_B^2}{p_L^2+p_B^2}.
\]

同一方向上wL+wB=1，所以两项期望相加仍是原积分。实现先除以max(pL,pB)再平方，以避免高PDF直接平方溢出。MIS权重只作用于本次直接光估计，不能乘进后续整条路径的beta。

当路径在下一顶点命中灯，需要上一顶点的采样PDF，因此保存previousPdf。不能用灯表面自己的BRDF PDF，也不能事后根据另一个方向重新生成采样事件。

相机直接看到灯时没有上一顶点NEE竞争，权重为1。上一事件为delta时，连续灯面积采样不能以非零概率产生那个精确镜面方向，命中权重也为1。混合了漫反射与delta的材质必须按**实际抽中的事件**判断，不能只按材质名称判断。环境在当前实现中没有加入NEE，因此环境命中也没有竞争策略，权重恒为1。

这些状态与标准路径追踪实现的发光/MIS、specular事件和etaScale分工一致；可对照[PBRT 4：A Better Path Tracer](https://pbr-book.org/4ed/Light_Transport_I_Surface_Reflection/A_Better_Path_Tracer)。

## 从三角形面积采样推导方向PDF

宿主遍历所有实例，把发光网格顶点变换到世界空间后计算每个三角形面积Aj。不能在非均匀缩放后仍使用局部面积。场景有两块矩形灯、四个发光三角形，总面积A=27。

按面积构造CDF，选第j个灯三角形的概率为Aj/A。随后在三角形内均匀取点，条件面积密度1/Aj，因此联合面积密度：

\[
p_A(y)=\frac{A_j}{A}\frac1{A_j}=\frac1A.
\]

这解释了为何命中任意发光三角形后，LightPdf可用同一个总面积；若改为按功率选灯，公式必须同步修改，不能继续用1/A。

三角形取点用两个均匀数u、v，令r=sqrt(u)，重心为(1-r,r(1-v),rv)。沿顶点向对边走到比例r时，小三角形面积比例是r²，所以CDF为u=r²；直接令r=u会让点向顶点聚集。

面积元对着点x张开的立体角为

\[
d\omega=\frac{c_L}{d^2}dA,\quad c_L=n_L\cdot(-\omega_i),\quad d=|y-x|.
\]

因此与BSDF方向PDF比较的密度是

\[
\boxed{p_L(\omega_i)=\frac{d^2}{A c_L}}.
\]

cL<=0时单面灯不向该方向发光。可见性用实际DXR阴影射线确认，命中实例/primitive必须是选中灯三角形。选中点的发光值仍经过LoadSurface的材质/UV读取，不把纹理发光错误地简化成CPU常量。

## 循环更新顺序

`path_integrator.hlsl:25`每像素执行指定样本数。每次路径迭代：

1. TraceRay取最近命中，或返回环境。封闭介质内部未穿出边界却Miss视为错误。
2. 读取几何/材质；普通单面表面的背面终止，不偷偷翻转几何法线。
3. 用进入当前顶点前的beta收取发光，按前一事件应用MIS。
4. 若已达到K次散射则结束；最后顶点仍可收发光，但不再做多一步NEE。
5. 对连续表面采灯、转方向PDF、测试遮挡、累加NEE。
6. Draw生成下一方向，将返回权重乘入beta；合法null样本贡献0并结束。
7. 保存本顶点位置、实际采样PDF和delta标记，再做RR及其存活补偿。
8. 偏移起点、更新方向，进入下一轮。

K是最大散射次数，不是TraceRay总数。阴影射线也计入真实射线数，不能把SPP直接当作射线数。K=1时玻璃只来得及进入、到下一界面就截断，所以玻璃大部分发黑；这张负向对比反映了深度定义，不是把玻璃颜色设成黑色。K=8时它能穿出玻璃并看到地板/背景；镜面球下半部也能反射被照亮的地板和红球。

随机数由(pixel,sample,batchSeed,depth,dimension)直接哈希产生。相机、灯、BSDF、RR使用不同dimension，关闭NEE不会挪动BSDF序列，便于同种子配对。它是教学计数器式哈希，不是生产采样器质量的完整研究。

## 把平滑介质加入同一循环

共享材质工厂新增可选参数：

```cpp
MaterialBindings PreparePbrBindings(
    UploadContext&, const CpuScene&, const GpuScene&,
    const std::vector<float>* dielectricIors = nullptr);
```

前三参数仍是后端上下文、自有CPU场景、配套GPU场景。最后参数按材质索引提供IOR，0使用原PBR，正值使用本课无吸收平滑介质；向量长度必须匹配材质数，正IOR限制为[1,3]。它写入64B材质记录原本保留的emission.w，GPU Surface读入dielectricIOR。原默认参数保持前课行为，GPU材质回归已验证。

宿主只将`teaching_glass`标签显式设为1.5；glTF本身仍是OPAQUE。这是透明材质的教学覆盖，不是实现了KHR_materials_transmission。玻璃散射忽略原metallic/roughness/base吸收语义，保留无吸收模型；普通材料继续按glTF参数与纹理读取。

进入/离开由几何外向法线判断，并用实例ID核对medium状态。反射不改变介质；只有透射切换medium。当前支持互不嵌套的封闭玻璃，碰到嵌套或不一致状态直接记录错误。玻璃是delta事件，不执行普通面积灯NEE，阴影射线把玻璃视为遮挡；通过镜面/折射链的光由BSDF路径产生，因此焦散可能噪声较大。

SampleDielectric沿用已验收的Fresnel、TIR及Radiance权重，积分器只乘一次weight。折射时还累乘etaScale；RR使用max(beta)*etaScale计算存活概率，避免把进入高IOR介质后的辐亮度尺度变化误判成吸收。存活后beta除以存活概率，已经累加的L保持不变。

## 配置、输出和同步契约

`path_config.h`定义t6为ByteAddressBuffer的128B头，后接lightCount个64B灯记录。

| 字节偏移 | 内容 |
|---|---|
| 0 | uint4 width/height/spp/seed |
| 16 | uint4 maxScatters/mode/rrStart/flags |
| 32 | float3 eye + tanHalfFovY |
| 48 | float3 forward + environmentIntensity |
| 64 | float3 right + normalOffset |
| 80 | float3 up + lightScale |
| 96 | uint lightCount、float totalArea、两个保留uint |
| 112 | float3 environment + 保留float |

mode0=仅BSDF，mode1=Power MIS，mode2=故意双计数；flags最低位开RR，rrStart=4。相机用正交单位基生成透视射线，采用与前课一致的像素中心区间内抖动；这里没有新增一套窗口后端。

每个灯记录是三个float4顶点（w保留）加area/cdf/instance/primitive，实例和primitive用于定位真实场景材质与可见性。t0..t5、t7继续使用原场景和能量表绑定，不另建设备、BLAS/TLAS或根签名实现。

u0每像素112B：四个float4为HDR均值/亮度平方均值、首主样本基础色/roughness、几何法线/材质ID+1、位置/实例ID+1；三个uint4为射线/散射计数、错误/delta/透射计数、各类终止/发光计数。第一样本特征只用于当前几何审计，尚未声称是抗锯齿后可直接给成熟降噪器的最终G-buffer。

宿主继续调用共享同步DispatchMaterialBuffer：借用Scene/MaterialBindings/Frame资源，复制配置到UPLOAD，提交Dispatch和Readback复制，等待Fence后返回CPU自有字节数组。运行期间资源不能释放或覆盖；所有GPU错误与HRESULT由既有Check和Debug Layer路径处理。文件、参数、几何审计、非有限数值或介质不一致失败均退出非零。

每次最多32 spp，减少单个巨大Dispatch长时间占用Windows交互式GPU的风险。每批种子按baseSeed+6151*batch改变；CPU按样本数加权合并线性一阶/二阶矩，保持首批第一主样本特征。每批仍同步读回；持久GPU历史、异步帧资源、相机/尺寸变化重置留PT.10，不能把本节CPU分批平均称为完成了渐进显示系统。

固定起点偏移为1e-4场景单位，阴影方向重新指向采到的灯点。此偏移只经过当前尺度场景验证，不是跨任意坐标尺度的误差界；它与真实几何仍存在很小数值近似。

## 场景、运行与图像

场景包含20个mesh/instance、63496个三角形：两排各7个球，r=0/.02/.08/.2/.4/.7/1；上排金属、下排非金属；两侧IOR1.5玻璃；地面、背板和两块灯。球面64×32细分，使用真实三角形几何法线，因此光滑镜面高光仍可见几何分面，不是启用了平滑着色法线。

仓库根目录运行：

```powershell
.\learning\sandbox\path_tracing\dxr-path-tracer\verify_path.ps1
```

脚本按自身定位，不依赖启动工作目录。它构建CMake/VS2022宿主、生成并验证glTF、准备能量表、编译DXC lib_6_3/HV2021 shader，运行八组场景测试和前课PBR回归，最后运行analyze_gallery.py。没有CUDA kernel；真实路径在RTX5070上通过DXR执行。

从本课目录单独运行的参数顺序：

```powershell
.\build\Release\path_render.exe .\results\pt08\gallery.gltf .\results\pt08\path.dxil .\results\pt08\energy-lut.bin .\results\pt08\custom 384 192 256 8 1 0 1 12
```

依次是场景、DXIL、能量表、结果目录、宽、高、SPP、K、mode、seed、RR开关、灯强度倍率。结果目录中保存radiance.pfm、pixels.bin、summary.json和run.txt。PFM保存未截断的线性HDR，负scale=-1表示little-endian，按底行到顶行写RGB float。

预览为Reinhard L/(1+L)后执行一次sRGB编码；仅用于查看，MSE始终在线性HDR上计算。没有降噪，也没有把PNG亮度用于物理验收。所有输出直接位于共享主线results/pt08及各case子目录，统计/绘图依赖沿用前课隔离的numpy/matplotlib/Pillow。

![1024 spp参考](../../sandbox/path_tracing/dxr-path-tracer/results/pt08/gallery-reference.png)

## 本机结果与解释

八组测试共180486144个相机路径样本、522047572次TraceRay；512条独立CPU主射线身份/位置/法线审计通过。K=0另做64像素×16样本的CPU发光/环境参考，最大差2.63751e-9。各组invalid=0、nonfinite=0，Debug Layer0，glTF Validator0错误0警告。

| 384×192图像 | SPP | 平均亮度 | 均值标准误差 | 真实射线 |
|---|---:|---:|---:|---:|
| K1，MIS | 256 | .3724009214 | .0000993453 | 42488054 |
| K8，MIS | 256 | .4135397669 | .0001149803 | 58726597 |
| K8，仅BSDF | 256 | .4135121001 | .0002806634 | 40469474 |
| K8，双计数反例 | 256 | .6414238723 | .0022234359 | 58726597 |
| K8，MIS+RR | 256 | .4135297961 | .0001155909 | 56211632 |
| K8，高样本参考 | 1024 | .4134149758 | .0000575107 | 234884601 |

MIS、BSDF-only和RR与独立seed参考均通过6SE+.0005门槛。标准误差来自每像素路径的一阶/二阶矩再合并，不把图像空间亮暗变化当噪声；仍依赖采样统计近似，不是无条件数学保证。

相对1024 spp参考的线性RGB MSE：MIS .0014422275，BSDF .0069428316，RR .0014594171，双计数 .6019858468。相同256 spp下MIS的MSE约为BSDF的1/4.814，但多发出了阴影射线；这不是等GPU时间/等射线预算比较，性能评测在PT.10继续做。

RR减少约4.2825%的射线，均值保持。当前K8和场景下大多数路径本来就较短，不能把PT.7盒腔中的巨大节省照搬过来。参考图有8749852次delta事件、5623201次透射，介质状态检查没有报错。参考K8仍有255658次深度截断，所以不是无限反弹真值。

K1→K8使地板和背景间接光、镜面球对其他物体的反射、完整玻璃透射链出现；双计数并非全图恰好翻倍，因为相机直接看到灯、delta路径、环境项没有与NEE重复的同类贡献。关闭面积灯后只剩环境照明，平均亮度显著降低，符合预期。

![相同SPP对比](../../sandbox/path_tracing/dxr-path-tracer/results/pt08/gallery-comparison.png)

已查看粗糙度扫描图：未见数值异常形成的黑斑；K1截断、真实阴影、镜面暗区与金属单次微散射的高粗糙度变暗分别有模型原因，不能一律当作错误。残留噪声特别是玻璃焦散也不是非有限数值；当前没有做路径正则化、光子映射或焦散专用采样。

## PT.8完成审计与边界

| 既定要求 | 现有证据 |
|---|---|
| 反射/折射/Fresnel/TIR | mirror/refraction/dielectric专项；12969方向组、1800 Fresnel角度；GPU玻璃与多界面验收 |
| GGX/Smith/Schlick与采样区分 | GGX推导/独立积分/CPU Monte Carlo；glTF纹理与GPU混合PDF逐字段检查 |
| 能量守恒检查 | 旧模型反例；双侧归一化推导；GPU表外积分与白炉最大参考1.00006965（数值近似） |
| 粗糙度扫描 | CPU有限性、40960 GPU参数探针、真实场景r0到r1图像；非有限记录为0 |
| 镜面极限 | alpha<=1e-4明确delta，连续/离散事件分别处理，真实多反弹图像 |
| glTF映射边界 | 基础色/MR/发光纹理、顶点色、OPAQUE/UV0/几何法线/mip0；未支持语义明确拒绝 |

玻璃仍是显式教学覆盖，未实现glTF透射扩展、吸收、嵌套介质或体积散射；金属微面多次散射未补偿；固定K、固定起点偏移、首样本特征和CPU累积都是明确简化。商业引擎通常还会缓存管线/灯分布，使用更完整材质、鲁棒起点偏移和GPU历史/降噪；这里已经建立相同的路径权重和DXR资源机制，后续逐项补工程环节。

自测：为什么镜面命中灯不能直接使用连续方向MIS权重？为什么K1玻璃发黑但K8能看见背景？为什么本次MIS的MSE更低还不能直接宣布GPU更快？下一节直接解答，进入PT.10线性HDR GPU累积与history重置。
