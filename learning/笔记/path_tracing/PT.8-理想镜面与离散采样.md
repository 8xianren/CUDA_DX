# PT.8 理想镜面与离散采样

2026-10-21；PT.8进行中，仅完成本节。代码及命令见[pt08-materials](../../sandbox/path_tracing/pt08-materials/README.md)，结果见[summary.csv](../../sandbox/path_tracing/pt08-materials/results/mirror/summary.csv)。

## 上节答案

1. s=.25，beta=(.08,.04,.02)，幸存beta=beta/s=(.32,.16,.08)。乘幸存概率后期望仍是原beta。
2. RR选择的是尚未追踪的后续贡献；已经累积的L不由这个随机事件决定，不能一起除以s。
3. RR保留当前有限K目标的期望；确定性截断丢掉的尾项不会凭空回来。无偏须说清相对哪个积分目标。

## 从几何约束推导方向

目标：给定撞向镜面的单位射线方向d和单位法线n，求反弹方向r。镜面模型采用几何光学的镜面反射定律；这里只由该定律推导向量公式，不声称推导了电磁反射规律。
像游戏中的弹道反弹：切向运动保持，法向运动反号。光的亮度还由材料反射率控制。

把d正交分解：d_n=(d·n)n，d_t=d-d_n。镜面要求r_t=d_t、r_n=-d_n，于是

`r=d_t-d_n=d-2(d·n)n`。

若d=(.6,0,-.8)，n=(0,0,1)，得到r=(.6,0,.8)。长度仍1；切向.6保持，法向-.8变+.8。若n不单位，投影应为(d·n)/(n·n)n；工程中应先得到正确的单位世界法线。

BSDF接口通常让wo和wi都离开交点：wo=-d，wi=r，因此wi=2(wo·n)n-wo。
HLSL的float3实例化调用是`float3 reflect(float3 i,float3 n)`，i取d或-wo，n取单位法线，返回反射向量；不能误传wo。
[Microsoft reflect](https://learn.microsoft.com/en-us/windows/win32/direct3dhlsl/dx-graphics-hlsl-reflect)给出同一公式。

## 为什么镜面需要离散事件

固定wo后，Lambert可接收整个半球方向的光；理想镜面只接收唯一wi*。连续PDF pOmega的单位sr^-1，只能通过区域积分给概率，某个孤立方向的概率为0。纯镜面对唯一方向的选择概率为1；这是离散概率质量，不能拿数字1充当连续密度。

用相对立体角的Dirac分布deltaOmega表示理想镜面：它的定义是积分筛选性质∫deltaOmega(w-w*)g(w)dw=g(w*)，不是浮点无穷大。对非掠射方向形式上写

`f(wo,wi)=R*deltaOmega(wi-wi*)/abs(n·wi)`。

代入渲染方程∫f Li abs(n·wi)dwi，余弦抵消，再用筛选性质，得到Lo(wo)=R Li(wi*)。
因此路径更新beta'=beta*R。不是看到反射方向就额外乘cos，也不是把delta写成大常数。R=1无损、R=0吸收；常量RGB R只是本课模型，真实反射率的角度变化留到Fresnel。

本课`MirrorSample`字段：wi为单位出射查询方向；weight为已完成散射项/几何项/抽样分布比值的RGB；pdfOmega为连续部分密度；eventMass为离散事件概率；isDelta为事件标签。`SampleMirror(wo,n,R)`要求单位wo/n、wo在n正半球、有限线性R∈[0,1]，返回wi、R、0、1、true。函数无分配、无GPU同步；积分器不能对weight再次除PDF。

如果通用Eval/Pdf接口只评价连续部分，纯镜面返回0不代表完全吸收。PBRT把隐含delta的采样PDF记为1，并由事件类型区分；本课显式拆开密度和质量，避免误用。[PBRT BSDF Representation](https://www.pbr-book.org/4ed/Reflection_Models/BSDF_Representation)。

非零粗糙度即便非常小，仍通常是连续模型；把其截成理想delta是模型选择。混合镜面/漫反射时，分支选择概率还必须进入采样权重；本节只有唯一镜面分支。

## NEE与MIS为什么要分流

普通面积灯NEE随机选灯面位置，再从镜面连向它，恰好满足唯一镜面方向的概率为0；纯镜面的连续部分为0，因此本课不生成NEE阴影射线。相机→镜面→灯由镜面采样确定。

当上一事件是delta，发光面命中贡献用权重1。对这个单点方向，竞争的连续灯采样没有离散概率质量；不要把pB=1与pL(sr^-1)放进power heuristic。混合材质的连续部分仍可NEE；更复杂的专门镜面连接采样也不属于这里讨论的普通NEE。

本节在独立shader中落实规则，未把PT.7限定Lambert盒腔的多反弹shader冒充通用材质积分器。将来合并时保存previousWasDelta；相机直接命中或previousWasDelta时加beta*Le，其余可竞争事件再应用共同测度的MIS。[PBRT A Better Path Tracer](https://pbr-book.org/4ed/Light_Transport_I_Surface_Reflection/A_Better_Path_Tracer)。

## 数据、资源和执行

生成glTF有镜面z=0、x/y∈[-8,8]，矩形灯z=2、x/y∈[-1,1]，灯面积4。相机起点z=1，x/y为64×64网格中心，范围[-1.6,1.6]；d=normalize(sx,sy,-1)。镜面点为(ox+sx,oy+sy,0)，反射后灯平面点为(ox+3sx,oy+3sy,2)。后者是否在灯内给独立CPU命中参考。

glTF经Khronos校验、Assimp、自有CpuScene、共享UploadScene、BLAS/TLAS。名称Mirror显式覆盖为本课常量R理想镜面，不是完整glTF金属材质解释。导入R=(.8,.5,.25)、Le=(.2,.6,1)。真实DXR负责两段求交，shader利用fixture已知法线，不读任意网格插值法线。

配置64B：offset0 uint4尺寸/材料ID；16 float4斜率；32 R；48 Le。输出96B：offset0位置xyz/t；16反射方向xyz/离散mass；32 beta/isDelta；48 L/发光MIS权重；64错误L/连续灯PDF；80 uint4首/次命中材料ID、TraceRay数、NEE数。C++有sizeof/offsetof检查。结构化buffer stride不等于CBV槽对齐要求。

根签名t0 TLAS、t1 80B对象表、t2配置、u0输出；payload16B只保存材料ID和t。两次TraceRay顺序发生在RayGen，最大嵌套深度仍1。每线程独占一个96B输出，无跨线程数据依赖。

`DispatchRayBuffer(UploadContext&,const InstanceFrame&,const void* data,size_t configBytes,UINT width,UINT height,size_t outputBytes,const filesystem::path& dxil)`：c为设备/队列，frame为借用TLAS/对象表，data及configBytes为CPU配置，width/height为发射尺寸，outputBytes为输出总字节，dxil为已编译库；返回拥有数据的字节vector。调用者保证shader布局一致及BLAS/TLAS寿命。

helper把配置复制到UPLOAD；DEFAULT UAV写入后转COPY_SOURCE，复制到READBACK COPY_DEST；提交同一DIRECT队列并等Fence，再Map/memcpy。Map不负责等待。调用者的gpu/BLAS/frame跨所有调度存活；上传staging和BLAS scratch仅在构建Fence完成后释放；helper内临时资源返回前已退役。HRESULT/等待/校验失败抛异常，脚本返回失败，不宣称完成设备恢复。

## 实测与负对照

2026-10-21 RTX5070，DXC lib_6_3，五组各4096路径，两次TraceRay/路径，总40960，阴影射线0。所有网格中心避开矩形边界；逐字段double误差阈值3e-5。

| 实验 | 命中灯数 | 正确命中RGB | 错误MIS红分量 |
|---|---:|---|---:|
| 正视 |1600|(.1600000113,.3000000119,.25)|.08000000566|
| 斜视sx=.2 sy=-.1 |1600|同上|.07415561378|
| 大倾角，全miss |0|(0,0,0)|0|
| R=0 |1600|(0,0,0)|0|
| R=1 |1600|(.200000003,.600000024,1)|.10000000149|

表中命中RGB为条件均值，不是全体像素平均；整个图像包含黑色miss。
正视时镜面到灯距离2、cosLight=1，所以pL=2²/(4*1)=1 sr^-1。错误地与离散mass1比较得到1/(1+1)=1/2；正确结果没有这一半。斜视设len=sqrt(1+sx²+sy²)，则pL=len³，错误权重1/(1+len⁶)，可由CPU独立核算。

最大字段绝对差1.95464789909e-6；Fence6/6、Debug警告/错误0、Khronos错误/警告0；全部PASS。没有测GPU耗时，不作性能结论。编译初次遇到Windows near宏和HLSL point保留字，分别改为checkNear和position后全流程通过。

本课固定TMin=1e-5、命中z投影到0、黑环境、单次反射；不是任意尺度的鲁棒网格积分器。引擎一般经材质系统提供Fresnel/粗糙度/纹理/世界法线，复用帧资源并延迟回收；相同的底层反射规律、事件采样和GPU资源生命周期仍适用。这里保留黑镜面第二段射线为了几何验收；生产可早停零beta。

## 自测与下一步

1. d=(.6,0,-.8)，n=(0,0,1)，反射方向和wo分别是多少？
2. 镜面Sample返回eventMass=1而pdfOmega=0，为什么不矛盾，也不会把beta除以0？
3. R=(.8,.5,.25)、Le=(.2,.6,1)，无遮挡镜中灯的RGB是多少？再乘cos会发生什么？

下一小节：由折射的几何约束与Snell定律推导透射方向，随后处理全反射、Fresnel分支及折射传输权重。PT.8其余内容未完成。
