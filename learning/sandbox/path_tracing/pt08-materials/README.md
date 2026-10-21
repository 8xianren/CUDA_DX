# PT.8 材质专项验收

当前完成理想镜面、多界面玻璃DXR，GGX/Smith/Schlick CPU参考、glTF材质读取与GPU混合采样，以及双侧能量耦合的GPU二维表与白炉验收。旧基线1.26866能量反例保留；修正模型已测最大白炉参考1.00007。上述模块已接入[共享多反弹/NEE/MIS主线](../dxr-path-tracer/README.md)，粗糙度场景和玻璃/RR图像验收通过，PT.8在声明的教学范围内完成；详见[共享积分器与粗糙度场景验收](../../../笔记/path_tracing/PT.8-共享积分器与粗糙度场景验收.md)。下一节进入PT.10。
讲义：[理想镜面与离散采样](../../../笔记/path_tracing/PT.8-理想镜面与离散采样.md)。

| 文件 | 职责 |
|---|---|
| mirror.hlsli | 材质采样契约，反射方向、离散概率、吞吐量权重 |
| mirror.hlsl | 两段真实DXR射线，正确发光贡献与错误MIS负对照 |
| mirror_test.cpp | 导入/共享后端调度、CPU double独立几何与辐亮度验收 |
| make_mirror.py | 两平面glTF fixture；名称显式覆盖教学镜面材质 |
| verify_mirror.ps1 | 构建、DXC、Khronos校验、GPU验证与日志 |

从仓库根目录执行（脚本内部路径独立于当前工作目录）：

```powershell
.\learning\sandbox\path_tracing\pt08-materials\verify_mirror.ps1
```

C++宿主继续用`../../d3d12/gltf-scene`的CMake/VS2022共享后端；shader用`dxc -T lib_6_3 -HV 2021`。
本实验为D3D12/DXR，无CUDA kernel，无需nvcc目标架构；实际执行在RTX5070。
构建输出`build/Release/mirror_test.exe`；glTF/bin/DXIL及校验、构建、运行日志和summary.csv全部在`results/mirror/`。
直接运行参数依次为glTF路径、DXIL路径、结果目录，例如从本课目录运行：

```powershell
.\build\Release\mirror_test.exe .\results\mirror\mirror.gltf .\results\mirror\mirror.dxil .\results\mirror
```

五组64×64路径：正视、斜视、全miss、R=0、R=1。解析比较命中身份/位置/方向、RGB与错误权重，任一差超过3e-5则退出1；工具失败也立即停止。
2026-10-21：40960 TraceRay；最大逐字段差1.95464789909e-6；Fence6/6；Debug0/0；Validator0/0，PASS。
summary的hit_rgb是命中灯路径的均值，用于验证R×Le，**不是全图均值**；miss行无命中时用0占位。

范围：固定几何平面与法线、常量线性R、单次反射、黑环境。镜面名称覆盖不是glTF roughness/metallic完整实现；正TMin和z投影为本fixture数值简化；关闭三角形背面剔除但只测试正面观察与灯朝下发光。
黑镜面仍发第二条射线用于验证几何；生产代码可提前终止零吞吐量。
复用共享同步DispatchRayBuffer，未修改PT.6/PT.7算法或公共实现。通常引擎还需要材质系统、纹理/法线、异步帧资源与误差有界的起点偏移。

## 折射方向与全反射（CPU）

讲义：[折射方向与全反射](../../../笔记/path_tracing/PT.8-折射方向与全反射.md)。
`refraction_math.h`负责float方向与介质选择，`refraction_test.cu`负责独立double三角参考、Snell/可逆性/费马驻时和非法输入验收，`verify_refraction.ps1`负责构建与结果归档。
从仓库根目录执行：

```powershell
.\learning\sandbox\path_tracing\pt08-materials\verify_refraction.ps1
```

脚本不依赖启动工作目录，用共享build.ps1初始化VS2022并以nvcc/sm_120构建；**本程序仅CPU执行，无CUDA kernel或DXR提交**。
exe为本课目录的`refraction_test.exe`；结果为`results/refraction/anchors.csv`、`summary.txt`、`build.txt`和`run.txt`。
从本课目录直接运行：`./refraction_test.exe ./results/refraction`；参数为输出目录。
2026-10-21：12969组，10869次逆向检查、6类非法输入；最大方向差1.64927e-6、Snell残差2.51258e-7，PASS。
其中一个理论临界角float样本单独做边界诊断，不声称实数临界分类保证。无Fresnel、无吞吐量更新、无GPU玻璃集成；两介质平滑界面，不能代替嵌套介质管理。

## Fresnel与透射路径权重（CPU）

讲义：[Fresnel与透射路径权重](../../../笔记/path_tracing/PT.8-Fresnel与透射路径权重.md)。
`dielectric_math.h`复用折射几何，提供功率Fresnel、反射/透射离散抽样、Radiance模式weight和RR etaScale；`dielectric_test.cu`独立验证边界条件/功率/立体角Jacobian、Monte Carlo均值和两个错误对照。

从仓库根目录运行：

```powershell
.\learning\sandbox\path_tracing\pt08-materials\verify_dielectric.ps1
```

脚本定位独立于工作目录，nvcc/sm_120构建，**仅CPU执行**。exe为本课`dielectric_test.exe`，从本课目录可直接运行`./dielectric_test.exe ./results/dielectric`；参数为结果目录。
`results/dielectric/`包含fresnel.csv、sampling.csv、summary.txt和构建/运行日志。
2026-10-21：1800角度、3145728分支样本，所有均值在6SE容差内；功率残差<=5.56e-16、Jacobian相对差<=2.80e-12；两次透射IOR缩放相消、RR尺度、非法RNG等通过。
sampling.csv的后续辐亮度固定为反射2、透射3，仅验收界面估计器；Fresnel策略并非每个用例方差最低，80度时半半策略更好。无GPU玻璃、吸收、粗糙度、偏振传播或嵌套介质。

## DXR单平滑介质界面

讲义：[DXR平滑介质界面](../../../笔记/path_tracing/PT.8-DXR平滑介质界面.md)。
`dielectric.hlsli`提供可复用HLSL材质采样；`glass.hlsl`执行两条真实射线并输出诊断；`glass_test.cpp`独立double平面/材质/统计验收；`make_glass.py`生成一界面两灯glTF；`verify_glass.ps1`完成构建、验证与运行。
从仓库根目录执行：

```powershell
.\learning\sandbox\path_tracing\pt08-materials\verify_glass.ps1
```

脚本与启动工作目录无关，复用gltf-scene的CMake VS2022后端，shader用DXC lib_6_3/HV2021；无CUDA kernel。可执行文件`build/Release/glass_test.exe`；所有生成资源、DXIL、summary.csv/paths.csv和日志在`results/glass/`。
从本课目录直接运行：`./build/Release/glass_test.exe ./results/glass/glass.gltf ./results/glass/glass.dxil ./results/glass`，参数依次为glTF、DXIL和结果目录。
2026-10-21 RTX5070：393216路径/786432 TraceRay，逐字段最大差4.64916e-6；6种情况×F/半半策略，所有RGB均值与分支频率通过，Fence97/97、Debug0/0、Validator0/0。
当前仅单界面和固定几何法线，记录etaScale但没有执行RR；名称覆盖教学材质，不代表完整glTF透射扩展支持。80度反射miss作为零样本纳入均值。共享后端实现及旧实验源码未修改。

## 有厚度玻璃与多界面状态

讲义：[有厚度玻璃与多界面状态](../../../笔记/path_tracing/PT.8-有厚度玻璃与多界面状态.md)。
`make_slab.py`生成上下两个玻璃面和外侧双色灯；`slab.hlsl`在RayGen逐界面追踪并记录inside/beta/etaScale；`slab_reference.h`定义交换布局、独立double解析求交审计与有限几何级数目标；`slab_test.cpp`管理资源与统计验收；`verify_slab.ps1`构建、校验并运行。

从仓库根目录运行（脚本本身与启动工作目录无关）：

```powershell
.\learning\sandbox\path_tracing\pt08-materials\verify_slab.ps1
```

复用gltf-scene的CMake VS2022共享后端，DXC lib_6_3/HV2021，无CUDA kernel。exe在`build/Release/slab_test.exe`。从本课目录直接执行：`./build/Release/slab_test.exe ./results/slab/slab.gltf ./results/slab/slab.dxil ./results/slab`；三个参数分别为glTF、DXIL和结果目录。

所有输出在`results/slab/`：glTF/bin、DXIL、summary.csv、steps.csv、negative-control.txt与构建/验证/运行日志。summary中的upper/lower是路径数；upper_coefficient/lower_coefficient是Radiance组合系数，内部相机时不能当成总和为1的功率比例。tail是未完成物理分支质量，非漏掉的RGB。

2026-10-21 RTX5070：524288条正确路径、2374279 TraceRay；8用例×2策略全部通过逐步状态与6SE均值验收。最大位置累计误差.000302315（几何阈值5e-4，其余数值3e-5）；Fence130/130、Debug0/0、Validator0/0。另有4096条禁用偏移负对照，2724条介质一致性拒绝、12293 TraceRay，不混入正确统计。

范围：厚度1、半宽256有限平面，无侧壁，所有测试正确路径均不越界；标量Fresnel、无吸收/薄膜干涉/偏振状态/嵌套介质。每线程1312B审计记录。固定2^-10法线偏移只用于本尺度，不是通用误差界；负对照次数依赖本机硬件与驱动。etaScale被验证但未执行RR；PT.8的GGX与glTF金属粗糙度映射继续推进。

## GGX微表面与白炉（CPU）

讲义：[GGX微表面推导与白炉验证](../../../笔记/path_tracing/PT.8-GGX微表面推导与白炉验证.md)。
`ggx_math.h`实现局部坐标GGX、Smith高度相关遮蔽、Schlick、NDF采样、显式delta分支；`ggx_quadrature.h`实现独立方向积分；`ggx_test.cu`负责分布/几何/白炉/错误对照验收；`verify_ggx.ps1`构建运行；`plot_ggx.py`从真实CSV画图。

从仓库根目录运行（两个脚本均按自身路径定位）：

```powershell
.\learning\sandbox\path_tracing\pt08-materials\verify_ggx.ps1
python .\learning\sandbox\path_tracing\pt08-materials\plot_ggx.py
```

共享build.ps1以nvcc/sm_120构建，**仅CPU执行，无CUDA kernel或DXR**。exe位于本课`ggx_test.exe`；从本课目录运行`./ggx_test.exe ./results/ggx`，唯一参数为输出目录。结果包括summary.txt、roughness.csv、distribution.csv、furnace.csv、构建/运行日志与PNG/SVG。

绘图可选依赖matplotlib，本机隔离在`results/ggx/plot_packages`，重建命令见讲义；数值验收无该依赖。图中误差条是扫描数据的6SE，与furnace.csv的独立4seed统计不是同一批样本。

2026-10-21：18874368个白炉MC样本、884736扫描样本；投影归一化误差9.99e-16、Smith投影面积2.11e-15、9744次数值Jacobian最大相对误差2.33e-10、10000组互易性差1.81e-14，全部PASS。方向积分自适应至最多1024×2048，最终细化差<=1.80e-8。
alpha1正视F0=1解析1-ln2=.30685281944，NDF均值.30681967；错误只平均有效样本.61430956、漏Jacobian .08576225；80°去掉Smith时2.879385超过能量界。

范围：各向同性、单次微反射、无微面多次散射补偿、只有镜面反射分量；NDF而非VNDF采样。alpha=roughness²；alpha<=1e-4明确按delta处理，这是应用近似阈值。尚未验证GPU图像/黑斑或接入glTF漫反射组合，不将CPU有限性扫描冒充GPU渲染验收。

## glTF材质与GPU混合采样

讲义：[glTF材质与GPU混合采样](../../../笔记/path_tracing/PT.8-glTF材质与GPU混合采样.md)。
共享实现放在[dxr-path-tracer](../dxr-path-tracer/README.md)：pbr_resources负责材质表/sampler，surface.hlsli负责身份/几何/纹理读取，pbr.hlsli负责GGX与混合采样。专项pbr_math.h为CPU参考，pbr_test.cpp/.hlsl为独立方向积分/逐字段GPU验收，make_pbr.py生成10材质与三张2×2纹理，plot_pbr.py画实际统计数据。

从仓库根目录运行，脚本与当前目录无关：

```powershell
.\learning\sandbox\path_tracing\pt08-materials\verify_pbr.ps1
python .\learning\sandbox\path_tracing\pt08-materials\plot_pbr.py
```

CMake VS2022宿主、DXC lib_6_3/HV2021，真实DXR，无CUDA kernel。exe位于`build/Release/pbr_test.exe`。从本课目录可直接执行`./build/Release/pbr_test.exe ./results/pbr/pbr.gltf ./results/pbr/pbr.dxil ./results/pbr`。结果均在`results/pbr/`，包含输入资产、DXIL、summary.csv、samples.csv、summary.txt、日志和PNG/SVG；绘图沿用results/ggx/plot_packages的隔离matplotlib，数值测试无此依赖。

2026-10-21 RTX5070：1966080路径/3648139 TraceRay；逐权重归一化差<=1.04485e-6，基础色解码差<=.000339887，位置差<=9.54e-7。不同ps均值符合独立方向积分；离散/连续分流、零贡献样本、错误选中PDF反例通过。Fence49/49、Debug0/0、Validator0/0。共享DispatchMaterialBuffer与sampler转换提取后，D.3十二组与D.4边界回归通过。

**模型尚有失败项：** 白色非金属roughness=.25在80°下白炉解析1.26865688666，GPU同样大于1。summary.txt明确记录MODEL_ENERGY_FAILURE。脚本成功代表材质读取/采样/反例复现成功，不能当成物理模型完成验收；下一节修正能量耦合。

当前OPAQUE、单面、UV0、几何法线、mip0；MASK/BLEND、doubleSided、normal/AO纹理显式拒绝，未接完整多反弹/NEE/MIS或累积显示。发光槽独立验收，白炉统计不含自发光。真实白炉第二条射线必须Miss，异常命中直接失败。

## 漫反射与镜面能量耦合（CPU参考）

讲义：[漫反射与镜面能量耦合](../../../笔记/path_tracing/PT.8-漫反射与镜面能量耦合.md)。
`energy_quadrature.h`独立方向积分构造镜面E；`energy_balance.h`负责曲线查询、余弦平均和双侧归一化漫反射；`energy_test.cpp`负责完整BRDF积分、混合MC、互易性/坏输入/负对照；`verify_energy.ps1`构建运行，`plot_energy.py`从实际CSV画图。

仓库根目录运行，脚本内部路径独立于当前工作目录：

```powershell
.\learning\sandbox\path_tracing\pt08-materials\verify_energy.ps1
python .\learning\sandbox\path_tracing\pt08-materials\plot_energy.py
```

CMake/VS2022 Release纯CPU构建，无CUDA kernel或DXR提交。exe为`build/Release/energy_test.exe`；从本课目录直接运行`./build/Release/energy_test.exe ./results/energy`，唯一参数为输出目录。`results/energy/`保存energy.csv、furnace.csv、sampling.csv、summary.txt、构建/运行日志及PNG/SVG。绘图沿用results/ggx/plot_packages隔离matplotlib，数值验收无该依赖。

2026-10-21：5行×257节点（r=0/.25/.5/.75/1），320表外点最大误差9.78188e-6，积分最高2048阶；7864320 MC样本和10000互易性对通过。15组完整白炉最大偏离1为1.15403e-6，与独立能量预测最大差1.16248e-9。旧模型r=.25/80°的1.268656887修正为.999999958；单侧能量缩放互易性负对照差.289752。四类坏输入拒绝。

数学证明要求精确E；数值表的误差直接成为白炉偏差。当前按cos=(j/256)²加密掠射节点，在实际cos上线性插值并对该函数精确求average。不做roughness维插值、不覆盖全部连续参数域；GPU仍保留上一节基线，下一步实现GPU能量表和主线接入。模型属于可分离剩余能量闭合，非完整折射层内散射；金属微面多次散射仍未补偿。

## GPU能量表与窄高光数值稳定性

讲义：[GPU能量表与窄高光数值稳定性](../../../笔记/path_tracing/PT.8-GPU能量表与窄高光数值稳定性.md)。
`vndf_energy.h`与`energy_lut_build.cpp`负责CPU可见法线能量积分、float二维表/平均、细化和独立参考。共享`dxr-path-tracer/energy_lut.h/.hlsli`负责格式、加载与CPU/GPU插值。`pbr.hlsli`新增PBR_ENERGY_BALANCED编译选择，并保留采样微面法线避免掠射相消。`pbr_test.cpp/.hlsl`同一套验收支持基线/修正；新探针覆盖delta阈值、log粗糙度、掠射与端点，旧模型仍作独立负对照。

仓库根目录执行（脚本与启动目录无关）：

```powershell
.\learning\sandbox\path_tracing\pt08-materials\verify_energy_gpu.ps1
python .\learning\sandbox\path_tracing\pt08-materials\plot_energy_gpu.py
```

CMake/VS2022 Release构建CPU宿主和离线表，DXC lib_6_3/HV2021构建shader，实际DXR运行于RTX5070，无CUDA kernel。exe在build/Release。直接运行参数：`energy_lut_build.exe <结果目录>`；`pbr_test.exe <glTF> <DXIL> <结果目录> <energy-lut.bin>`为修正模型，省略最后参数为基线，shader必须对应宏选择。

全部本节新输出在results/energy-gpu：energy-lut.bin、glTF/纹理、DXIL、offgrid.csv、summary.csv、samples.csv、summary.txt、日志与PNG/SVG；旧模型在negative-baseline/。脚本含共享根签名修改后的D.3/D.4回归。绘图继续使用results/ggx/plot_packages隔离matplotlib。

2026-10-21：129×257能量表共133144字节，512表外点最大误差.000285061、20组独立方向积分差1.74125e-6。40960 GPU探针（40320实际采样）查表差1.82759e-7、权重差4.17281e-7；旧重构半角PDF负对照相对差最高2413.77。1966080白炉路径/3648139 TraceRay通过，权重差7.18173e-7、最大白炉参考1.00006965，Fence50/50、Debug0、Validator0/0。旧模型1.26866反例重现，D.3十二组与D.4通过。

表覆盖连续alpha∈(1e-4,1]并以log(alpha)插值；方向节点cos=(j/256)^4；delta独立解析。有限表外点检查不是全参数域严格误差界。一般方向Eval仍受float精度限制，已修复采样时丢失已知微面法线的问题。当前仍是专项白炉/数值扫描，完整多反弹/MIS和粗糙度图像待下一节接入。
