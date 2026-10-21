# PT.8：GGX微表面推导与白炉验证

2026-10-21。代码入口：[pt08-materials](../../sandbox/path_tracing/pt08-materials/README.md)。结果：[results/ggx](../../sandbox/path_tracing/pt08-materials/results/ggx/)。本节是CPU double数学参考，使用nvcc/sm_120构建但没有CUDA kernel或DXR执行。

## 承接上节

有限反弹深度造成截断偏差，增加样本只减少噪声；两次透射的q²会相消，但抽样补偿不必相消；全反射不跨越介质边界。本节将单一镜面法线推广为统计分布，推导连续BRDF和采样PDF。

## 为什么需要微表面

想象一块磨砂金属板由许多尺寸小于像素的微小镜子组成。每片仍服从镜面反射，但朝向不同；宏观上同一入射光会分散到一片方向，形成有宽度的高光。

不必把每个微镜建成真实三角形，可以用统计模型描述其法线面积分布。宏观表面仍负责场景求交，微表面模型负责命中后的角度分布。它不是每个像素随机转一下宏观法线便完成了：还必须有对应的BRDF、概率密度和遮蔽模型。

宏观法线n=(0,0,1)。wo指向观察者，wi指向光源，两者都从表面向外；实际到达表面的光传播方向是-wi。与之前射线传播方向d相比，wo=-d。仅考虑wo.z>0、wi.z>0的反射。

## 先解几何约束：哪一个微镜能连接wi与wo

对微表面法线m，镜面反射约束为：

wo=-wi+2(wi·m)m。

移项可得wi+wo与m平行，因此：

m=h=(wi+wo)/|wi+wo|。

h称半程向量。它不是第三条任意选择的方向，而是由入射和出射方向唯一确定的候选微面法线。本节两方向都在上半球，因此和向量不会为零，且h.z>0。

采样时反过来：给定wo，先选m，再令wi=2(wo·m)m-wo。反射映射是互易的，所以两种用法一致。

## 从面积守恒确定D的归一化

定义D(m)dωm为：每单位宏观面积中，法线落在dωm内的微表面实际面积。将这些面积投影到宏观平面后，必须覆盖一单位宏观面积。因此：

∫_(m.z>0) D(m)m.z dωm=1。

这里D不是本课直接抽样的归一化概率密度。归一化的是p_m(m)=D(m)m.z。D可大于1，因为它是连续面积密度，不是某个事件的概率。

引入微表面的二维斜率s=(sx,sy)，可以写m=(-sx,-sy,1)/sqrt(1+|s|²)。各向同性模型对斜率正负旋转对称，采样时直接使用正的径向方位表示也等价。

GGX选择的斜率概率模型是：

P(s)=alpha²/[pi(alpha²+|s|²)²]。

这是模型选择，不是唯一能从光学定律推出的分布；它具有较长尾部。极坐标中，半径r的概率密度为：

p_r(r)=2alpha² r/(alpha²+r²)²。

积分得到CDF：

C(r)=r²/(alpha²+r²)，C(0)=0，C(+∞)=1。

斜率面积与球面立体角的Jacobian为dωm=m.z³ dsx dsy。于是：

P(s)ds=D(m)m.z dωm，D(m)=P(s)/m.z⁴。

代入r²=(1-m.z²)/m.z²：

D_GGX(m)=alpha²/[pi(1+(alpha²-1)m.z²)²]。

代码使用等价但数值更稳定的分母：m.x²+m.y²+alpha²*m.z²，避免非常光滑时1-m.z²相消。

本课采用alpha=roughness²。roughness是资产/美术控制参数，alpha是分布尺度；两者不能在公式中随意交换。该映射与[glTF附录B](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#appendix-b-brdf-implementation)一致。这里的alpha也不是材质透明度alpha。

## 由反射映射推导BRDF分母

以wi为极轴，微面法线与wi夹角为theta_m。反射后wo与wi的夹角是2theta_m，方位角相同，因此：

dωo/dωm = [sin(2theta_m)*2dtheta_m*dphi]/[sin(theta_m)*dtheta_m*dphi]
          =4cos(theta_m)=4|wi·m|。

给定微小入射方向范围dωi，宏观面积dA对应的微面面积为D(m)dωm dA。入射功率与Li(wi)(wi·m)dωi D(m)dωm dA成正比。乘上微镜Fresnel反射率F和双向可见比例G，再将dωm换为dωo/[4|wi·m|]，微面投影因子被约掉。

另一方面，宏观输出功率定义为dLo(wo)(n·wo)dA dωo。比较两边得到：

dLo(wo)=Li(wi)dωi F D(h) G(wo,wi)/[4(n·wo)]。

渲染方程又要求dLo=fr Li(wi)(n·wi)dωi，故：

fr(wo,wi)=F(wo·h)D(h)G(wo,wi)/[4(n·wo)(n·wi)]。

所以分母的两个宏观余弦来自宏观辐亮度/渲染方程定义；因子4来自反射方向映射。它们不是为了把高光亮度“调得顺眼”添加的参数。

## Smith：法线分布本身不能确定遮蔽

相同的法线直方图，可以对应不同高度和排列的表面。哪些微面从观察方向可见、哪些能被光照到，需要额外的微表面空间组织假设。本课选择Smith随机高度模型，并采用高度相关的双向遮蔽。

从一条方向v观察，令theta为v与n夹角，t=tan(theta)。将二维斜率分布对另一轴积分，得到沿观察方向的斜率边缘分布：

p_s(s)=alpha²/[2(alpha²+s²)^(3/2)]。

所有朝向v的微面正投影面积（除以宏观投影面积）为：

A(v)=∫max(1-ts,0)p_s(s)ds。

t>0时积分上限为1/t，下限为-∞。两个原函数是：

∫p_s(s)ds=s/[2sqrt(alpha²+s²)]；
∫s p_s(s)ds=-alpha²/[2sqrt(alpha²+s²)]。

因此：

A(v)=[1+sqrt(1+alpha²tan²(theta))]/2。

宏观表面真正可见的投影面积只能是1，Smith模型下对应归一化比例为G1(v)=1/A(v)。定义多出来的投影面积Lambda(v)=A(v)-1，就有：

Lambda(v)=[sqrt(1+alpha²tan²(theta))-1]/2，G1(v)=1/[1+Lambda(v)]。

正视t=0时A=1、Lambda=0。代码将Lambda公式有理化为s/[2(sqrt(1+s)+1)]，其中s=alpha²tan²(theta)，避免小s时相减损失精度。

为什么不直接G=G1(wo)G1(wi)？两方向可能看向同一个较高微面，高度同时提高它对两方向的可见性，这两件事不是独立事件。

用q表示微面高度的累积分布值，q在[0,1]上均匀。Smith的固定高度可见性模型为q^Lambda(v)；在固定高度下忽略额外方向相关性，两方向联合可见性为q^(Lambda(wo)+Lambda(wi))。先相乘、再对共同高度平均：

G(wo,wi)=∫_0^1 q^(Lambda(wo)+Lambda(wi))dq
         =1/[1+Lambda(wo)+Lambda(wi)]。

这是高度相关模型，仍不是包含全部空间/方向相关性的精确微几何。局部背向的可见性因子在本课有效反射半球与半程向量条件下自动满足。模型来源与边界见[Heitz 2014，附录B](https://jcgt.org/published/0003/02/03/paper.pdf)与[PBRT微表面章节](https://pbr-book.org/4ed/Reflection_Models/Roughness_Using_Microfacet_Theory)。

## Schlick Fresnel的性质与近似边界

希望微镜正入射时F=F0，掠射时F趋向1。可选择F(c)=F0+(1-F0)(1-c)^p满足端点约束，c=wo·h。Schlick选p=5形成便宜的近似：

F(c)=F0+(1-F0)(1-c)^5。

两个端点不能唯一决定指数5，它是近似模型选择，不能称为从端点严格推导出的唯一Fresnel定律。这里用微面角wo·h，不能换成宏观n·wo。

空气/IOR1.5介质正入射F0=.04。本课逐0.1°扫描0..89.9°，Schlick与精确介质Fresnel最大绝对差.0356921，位于85°。因此上一节玻璃继续用精确介质Fresnel；本节反射模型采用Schlick便于接入glTF metallic-roughness。

F0可以是RGB，描述彩色金属的法向反射率；当前(.9,.6,.2)仅是受控材质参数，不是某种金属的测量数据。非金属的.04仅为表面镜面部分，不包含体内散射后返回的漫反射；下一小节添加完整metallic-roughness组合，不能把本节.04的白炉结果当作完整塑料材质。

## BRDF计算与采样是两件事

Eval接收给定的wo、wi，计算fr和“本课NDF采样策略”的PDF；它不选择方向。Draw接收wo和两个随机数u,v，先选微法线m，再生成wi，最后返回用于beta更新的fr*cos/pdf。

由CDF反解：

r=alpha sqrt(u/(1-u))，phi=2pi v，m=(r cos(phi),r sin(phi),1)/sqrt(1+r²)。

概率密度是p_m(m)=D(m)m.z。生成wi=2(wo·m)m-wo后，换到wi的立体角测度：

p(wi|wo)=D(h)h.z/[4|wo·h|]。

路径权重为：

w=fr(wo,wi)wi.z/p(wi|wo)=F G(wo,wi)|wo·h|/[wo.z*h.z]。

实现按Eval的fr/pdf相除，测试另对Jacobian做数值微分。余弦采样的PDF则是wi.z/pi，权重变成pi*fr；同一个BRDF可以配不同采样器，只要各用自己的正确PDF。

NDF采样会选择从wo看不到的m，也可能得到wi.z<=0。此时本次样本贡献为零，计入总样本数。本实现返回event=1的合法null事件；不能while重抽到有效以后继续使用原始PDF。对有效半球积分，本课PDF之和可能小于1，剩余概率属于null事件。

正视wo=n时，wi.z>0要求m.z>1/sqrt(2)，即斜率半径r<1，故有效概率为C(1)=1/(1+alpha²)。alpha=1时正好只有一半样本有效。这给出了独立的PDF积分/抽样频率验收锚点。

更高效的VNDF（可见法线分布）会把观察方向可见性纳入法线采样；本节先保留容易从CDF推导的NDF基线。采用VNDF时PDF必须同时更换，不能只替换随机方向生成代码。是否减少方差要实测，不能说“重要性采样永远比余弦好”。

## 白炉的目标、解析锚点和错误对照

白炉设所有入射方向Li=(1,1,1)，因此输出E(wo)=∫fr(wo,wi)wi.z dωi。对F0=1且包含全部微面多次反射的无损反射体，输出应为1。当前单次微反射模型只统计一次反射后就逃出的光；被微几何挡住的后续多次反射未补回，因此输出可以显著小于1。

alpha=1、wo=n时，D=1/pi，G=2z/(1+z)，其中z=wi.z。所以fr=1/[2pi(1+z)]，于是：

E=2pi∫_0^1 z/[2pi(1+z)]dz=1-ln(2)=.306852819440。

这不是数值误差，也不能通过提高SPP恢复到1。需要微面多次散射模型或有明确依据的能量补偿。它与上一节玻璃在两个宏观界面间来回反射不是同一尺度的现象。

真实结果：NDF均值.306819673923，SE=.000713305929；余弦采样均值.306905667338，SE=.000096107942，均匹配解析值。该粗糙正视案例余弦采样方差更低；不要给某种采样策略贴上普遍最优标签。

三项错误对照：

- 丢掉null样本，只平均有效样本：.614309561678，接近正确值两倍。
- 漏掉PDF的反射Jacobian：.085762254982，系统性偏暗。
- alpha=1、wo为80°时去掉Smith遮蔽：2.87938524157；正确模型参考为.668185943872。错误模型制造了额外能量。

最后一项也可独立推导：没有G且F=1、D=1/pi，E=1/[2cos(theta_o)]，80°得到2.879385。白炉因此同时检验不产生额外能量、量化单次散射缺失，并用解析锚点区分模型损失与实现错误。不能称本节单次模型为严格能量完备模型。

## 镜面极限与API契约

roughness=0时D趋向delta，不能将alpha=0直接代入连续公式。本实现明确规定alpha<=1e-4（roughness<=.01）走理想镜面分支。这是应用层对非常窄高光的近似策略，不是glTF规范强制阈值；0<roughness<=.01的连续模型被有意替换。

镜面分支返回wi=(-wo.x,-wo.y,wo.z)、weight=Schlick(F0,wo.z)、mass=1、连续pdf=0、event=3。Eval在这个分支返回连续f=0、pdf=0；它不代表镜面没有贡献，贡献只能通过离散抽样事件表示。后续MIS必须根据事件类型分流，不能拿pdf=0去做普通连续除法。

`ggx_math.h`的主要原型：

```cpp
struct Material { double roughness; V F0; };
Evaluation Eval(Material material, V wo, V wi);
Sample Draw(Material material, V wo, double u, double v);
```

V为三个double的局部向量。Material的roughness、F0各分量要求有限且在[0,1]。wo/wi要求有限单位向量；Draw要求wo.z>0、u/v有限且在[0,1)。Eval对合法单位但下半球的方向返回零反射，valid=true；数据非法时valid=false。

Evaluation含RGB f、每球面度pdf、valid。Sample含wi、RGB weight、连续pdf、离散mass和event：0非法输入，1合法null，2连续反射，3离散镜面。连续事件mass=0，delta事件pdf=0/mass=1。null方向不可当成下一条有效射线使用。

函数均按值传递，无动态资源所有权，无GPU同步。宿主测试拥有随机生成器、积分节点vector、输出流；任何非法测试结果或输出错误抛异常并返回1。扫描7类坏输入，包含随机数1/负数/NaN、零向量、下半球wo、负roughness和F0越界。raw D/Lambda/NormalFromNdf为内部数学助手，其单位向量/正alpha/随机数范围前置条件由调用层负责。

## 验收、结果与运行

源码职责：ggx_math.h实现模型和NDF采样；ggx_quadrature.h实现独立Gauss-Legendre方向积分；ggx_test.cu进行约束/负对照/MC验证；verify_ggx.ps1编译运行；plot_ggx.py读取CSV生成PNG与SVG。

从仓库根目录运行：

```powershell
.\learning\sandbox\path_tracing\pt08-materials\verify_ggx.ps1
python .\learning\sandbox\path_tracing\pt08-materials\plot_ggx.py
```

验证脚本按自身路径定位，不依赖启动目录。使用共享build.ps1、nvcc -arch=sm_120；仅CPU执行。exe为本课ggx_test.exe；从本课目录可执行`./ggx_test.exe ./results/ggx`。

绘图依赖matplotlib。本机将它隔离安装到results/ggx/plot_packages，plot脚本只为自身添加该搜索路径，不修改系统Python包。重建绘图依赖可从仓库根目录运行：

```powershell
python -m pip install --target learning/sandbox/path_tracing/pt08-materials/results/ggx/plot_packages matplotlib
```

绘图采用Windows微软雅黑，PNG与SVG已实际打开检查，无标签裁切。数值验证本身不依赖matplotlib。

实测汇总：

|项目|结果|
|---|---:|
|投影NDF归一化最大误差|9.99e-16|
|Smith正投影面积相对误差|2.11e-15|
|反射Jacobian数值微分|9744组，最大相对误差2.33e-10|
|BRDF互易性|10000组，最大归一化差1.81e-14|
|粗糙度/掠射扫描|884736样本，无非法数值|
|白炉Monte Carlo|18874368样本，36材质/角度组合×2策略|
|参考积分最大细化差|1.80e-8|
|Schlick与精确介质Fresnel最大差|.0356921，85°|

每个白炉策略用4seed×65536样本。参考从256×512与512×1024节点比较，roughness=.25、80°加密到1024×2048；所有均值在6SE+3e-6内。两级积分差不是一般严格误差界，另有alpha1解析值、归一化和Jacobian约束作交叉验证。非常光滑区域只做有限性/镜面极限/归一化扫描，不声称有限均匀方向网格已精确积分其窄峰。

|正视F0=1，roughness|独立方向积分|
|---|---:|
|.25|.995688060694|
|.5|.915812430250|
|.75|.626885656723|
|1|.306852819440|

![实测图](../../sandbox/path_tracing/pt08-materials/results/ggx/ggx-white-furnace.png)

本节没有渲染真实网格或GPU图片，因此不能据此宣称已经完成GPU粗糙度扫描、没有渲染黑斑或完整glTF材质支持。已验证的是CPU模型与估计器。生产渲染器还会结合可见法线采样、多次散射处理、纹理/法线过滤和完整材质混合；本课保留NDF与单次散射作为可解释的基线。

## 自测及连续课程衔接

1. D为什么不直接作为采样PDF？它描述实际微面面积；投影归一化后p_m=D*m.z才是本课法线概率密度。
2. 为什么不能重抽直到wi在上半球？这样把采样分布条件化了；若仍用原PDF，遗漏接受概率的归一化，结果偏亮。
3. F0=1而白炉只得到.30685，是不是证明采样器错了？不是。本例单次微反射模型解析结果就是1-ln2；独立积分、两种MC策略都一致。需区分模型缺失与积分错误。

下一小节直接进入GPU GGX与静态核心glTF metallic-roughness：把反射模型与漫反射组合，定义混合采样PDF，再接入真实DXR材质路径。PT.8仍未整章完成。
