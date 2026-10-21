# PT.9 CUDA路径状态与Megakernel

2026-10-21。本节将已验证的BVH接入Lambert/面光源/NEE/Power MIS/RR路径积分，建立CPU/GPU与后续Wavefront共同基线。代码：[cuda-path-tracer](../../sandbox/path_tracing/cuda-path-tracer/README.md)。PT.9仍进行中，Wavefront/Nsight尚未实现，不把本节出图当成整章完成。

## 1. 上节三题答案

A盒入口较近，只表示A中的交点不可能早于该入口，不保证实际交点早于B；只有B入口已大于当前最近t才能剪枝。平衡树约束树高，而重叠包围盒可能让一条射线访问两个分支直到全部叶子，因此仍有O(N)最坏遍历。512B私有栈描述每线程独立存储，本机上一节报告的是local memory，不是512B寄存器；访问次数、缓存和瓶颈还需实际profiling。

## 2. 从有限渲染方程到每线程状态

对当前表面x：Lo(x,wo)=Le(x,wo)+∫f(x,wi,wo)Li(x,wi)|n·wi|dwi。抽取wi~p得到一项f Li cos/p。反复代入Li对应的下一表面，可以把路径上到达每一顶点前的累积乘数写成RGB beta：beta0=(1,1,1)，beta_{d+1}=beta_d f_d cos_d/p_d。

因此必须保存当前射线、beta、已累积L。看到发光时先加beta_d Le_d，再更新到beta_{d+1}，不能提前乘当前表面的反射率。直接看到反射率0的灯仍然有Le，这在GPU解析案例中精确得到(3,2,1)。

为了给BSDF走到灯的事件计算MIS，还需保存上一表面位置和上一方向PDF；为了按固定随机序列重排工作，还需pixel/sample/depth。`path_integrator.h:25`的PathState<float>本机sizeof=88B，是C++逻辑布局，不等于GPU已分配88B寄存器。

当前K表示最多K次散射。深度0是主射线，到达深度K仍可观察Le，之后停止，不再生成NEE或BSDF下一段。因此每条样本路径最多K+1条路径射线，阴影射线另计。固定K会截断更长光路；RR并不能消除这个截断。

## 3. Lambert采样的代数取消

本节rho是RGB反射率，约束每通道[0,1]。Lambert f=rho/pi；余弦半球p=cos/pi。因此beta'=beta*rho，而不是“漏掉了PDF”。选择别的方向分布就不能继续使用这个简式。

圆盘采样半径的面积CDF为u=r²，故r=sqrt(u)，phi=2pi v，z=sqrt(1-u)。将(r cosphi,r sinphi,z)用正交切线基旋转到表面法线，得到余弦分布。代码`path_math.h:33`。表面散射使用朝向入射侧的几何法线，灯发光则只在原三角形几何法线正面。没有纹理或着色法线。

## 4. 灯选择、面积到方向PDF、MIS

本节灯列表有L个发光三角形，等概率选择一个，q_j=1/L。三角形内均匀面积采样的条件密度1/A_j，因此联合面积密度p_A=1/(L A_j)。这不是PT.8的面积加权灯分布，两者都可用，但PDF必须与当前抽样一致。

三角形面积采样：s=sqrt(u)，点y=(1-s)a+s(1-v)b+sv c；其根号来自从顶点a向对边扩展的相似三角形面积比例s²。若原表面点为x、距离r=|y-x|、方向wi=(y-x)/r、灯法线nL，则domega=cosL/r² dA，所以p_light,omega=r²/(L A_j cosL)。

NEE贡献为 beta*(rho/pi)*Le*cosSurface/p_light * V * wLight。其中可见性V由有限阴影射线判断。Power权重wLight=pLight²/(pLight²+pBsdf²)，pBsdf=cosSurface/pi。BSDF真正走到灯时改用互补权重wBsdf，主射线直接见灯权重1。两类策略评估共同方向测度下的PDF，不能把面积PDF与方向PDF直接平方相加。

当前偏移策略：PDF和几何项使用原表面点，shadow origin沿法线偏移epsilon后重新指向同一个灯样本，tmax=偏移后距离-epsilon；下一路径射线也沿法线偏移。epsilon=1e-4是当前米级场景数值近似，不是通用稳健偏移。本节阴影复用closest查询，尚未做any-hit提前结束优化。

## 5. RR终止未来，不能删除当前顶点贡献

当前顶点先生成NEE任务，再生成下一方向并更新beta。第三次散射起，s=clamp(max(beta),.05,.95)；以s继续，继续时beta/=s。条件期望E[1_survive beta/s]=beta，解释了补偿原因。

若RR终止，path.alive=false只表示“不再发出下一条路径射线”。当前顶点生成的ShadowTask仍必须查询可见性并累加，否则直接光也被RR概率削弱。

独立最小锚点令rho=.1、上方面光Le=2，固定样本明确触发RR终止，但当前NEE可见且红通道贡献0.0472905。`path_verify.cu:20`检查alive=false、rrKilled=1、shadow.valid=true、贡献>0及实际无遮挡。积分循环在RR终止后仍执行该shadow任务。

## 6. Megakernel意味着怎样执行

入口`path_gpu.cuh:5`：

```cpp
__global__ void Megakernel(PathView scene, RenderConfig config, PixelResult* output);
Megakernel<<<ceil(pixelCount / threads), threads, 0, stream>>>(scene, config, output);
```

scene按值传递device地址与数量，不携带CPU vector；config按值包含分辨率/SPP/样本偏移/seed/K/NEE/RR和相机基；output是DeviceBuffer分配的结果数组。默认128线程/block，0动态shared，nonblocking stream。线程i越界立即返回，正常线程独占output[i]。

每个线程执行：for样本→生成相机射线→while路径存活→BVH最近命中→发光/NEE/BSDF/RR→阴影查询→下一反弹；一个像素全部样本按固定顺序求和后除SPP。完整循环`path_integrator.h:101`。没有跨像素通信，无需原子浮点累加或__syncthreads。

每像素输出104B：RGB12B加92B诊断；诊断包括路径射线、阴影、顶点、RR终止、错误、哈希，以及17层活跃数。场景几何/材料/节点/索引/灯表只读。CPU vector和device分配各自拥有独立存储，DeviceScene活过所有render调用；kernel结束并读回后才释放输出，最后释放场景。

沿用上节API：cudaMalloc(void**,size_t)按字节分配，cudaMemcpy(dst,src,count,kind)显式HtoD/DtoH。默认流pageable上传后DeviceSynchronize建立完成边界，避免与nonblocking求交流缺少依赖。每配置1预热+3计时；同stream的begin event→kernel→end event，EventSynchronize后ElapsedTime读取毫秒再DtoH。上传/分配/读回不在GPU区间内。cudaGetLastError检查启动，所有完成点检查异步错误；异常输出操作名并exit1，RAII释放，不声称实现设备恢复。

## 7. 为什么随机数不能绑定临时队列下标

采用无状态哈希采样：Random(pixel,sample,seed,depth,dimension)，全部key为32bit无符号运算。哈希高23位加.5再乘2^-23，得到严格(0,1)的float值；CPU double也使用同一float随机输入，避免随机输入差异掩盖算术误差。

|维度|用途|
|---|---|
|0、1，depth0|像素内相机jitter|
|2|选择灯三角形|
|3、4|灯内面积采样|
|5、6|BSDF余弦方向|
|7|RR存活决定|

这是可复现伪随机映射，不宣称不同维度有严格数学独立性。把路径重新分配给线程或压缩队列，原pixel/sample/depth必须随状态一起移动；不能拿当前队列槽位生成新的随机数。否则比较Megakernel/Wavefront时连样本也变了，差异难以归因。

64/128/256 block得到逐RGB完全一致、路径哈希/计数一致；8spp对4+4连续sampleOffset加权合并，最大归一化差7.87501e-8。后者的小差来自浮点求和分组，不是采样不同；若第二批不增加sampleOffset，就重复第一批样本，不能算8个不同样本。

## 8. CPU参考的独立性与证据边界

GPU：float/BVH/Möller–Trumbore。CPU：double射线/代数、暴力遍历所有三角形，先平面交点再Gram重心方程；同一份float场景和相机作为输入，最终存float图像。CPU与GPU共享积分代数模板，所以它们的一致性不能单独证明共同公式无误；解析恒定Le/黑色、RR任务保留和既有PT.4–7推导补充约束。

31×17×8=4216初始路径；五组全部检查逐像素RGB与离散路径哈希/计数。哈希是摘要，不称完整逐顶点轨迹审计。误差=maxRGB |GPU-CPU|/(1+|CPU|)，阈值2e-4；本次实测远低于阈值，没有排除边界像素。

|模式|路径射线|阴影射线|RR终止|最大归一化差|
|---|---:|---:|---:|---:|
|K0发光|4216|0|0|0|
|K1直接光|8003|3103|0|1.58146e-7|
|K4 MIS/RR关|14899|7882|0|3.63667e-7|
|K4 MIS/RR开|11874|6977|1763|3.65607e-7|
|K4 BSDF-only|14899|0|0|6.66803e-8|

K4 RR图的最大线性绝对差5.06639e-7，MSE2.48012e-15。注意这是同样本CPU/GPU一致性误差，不是对真实无限反弹解的渲染误差。K1平均RGB .204185，K4无RR .261263，间接光贡献为正；RR .261420与无RR接近，但单seed相近不是独立统计无偏证明。

GPU解析发光精确(3,2,1)，无发光黑色精确0。非法K17和SPP0被拒绝。Compute Sanitizer quick为13×9×4=468初始路径、五组/解析/block/分批检查，0errors、0字节泄漏。大图没有CPU逐路径核对，CSV误差-1表示未测。

![CPU GPU差异](../../sandbox/path_tracing/cuda-path-tracer/results/megakernel/cpu-gpu.png)

## 9. 活跃路径和下一节为什么需要队列

|深度|RR关|RR开|
|---|---:|---:|
|0|4216|4216|
|1|3787|3787|
|2|2808|2808|
|3|2255|696|
|4|1833|367|

![活跃路径](../../sandbox/path_tracing/cuda-path-tracer/results/megakernel/active-paths.png)

这是逻辑上仍需发射该深度射线的样本数量，不等于硬件warp活跃lane或occupancy。Megakernel内不同线程可能处于不同样本、反弹和BVH节点，统计路径减少也不自动推出GPU按同比例加速。

本机Megakernel报告83寄存器、624B local、0静态shared。相比纯BVH的48寄存器/512B local，积分器确实改变资源需求，但不能由差值直接断言多少字节属于哪个变量，也不能仅凭寄存器数宣布瓶颈。

本轮盒室144×96/128spp/K8：5517221路径+3457325阴影=8974546次查询，中位27.5731ms。gallery192×96/32spp/K6：1188588+536510=1725098次查询，中位40.6936ms。两个场景三角形复杂度不同，不能只按射线数比较速度。gallery明确使用Lambert材质覆盖，未移植PT.8金属/GGX/玻璃/纹理，因此这也不是与DXR完整渲染器的公平后端性能比较。

![GPU出图](../../sandbox/path_tracing/cuda-path-tracer/results/megakernel/gpu-images.png)

Megakernel避免阶段间显式队列，但复杂分支与长期存活状态可能增加执行成本。Wavefront将求交/着色/阴影/继续路径拆成阶段，压缩仍活跃任务，代价是更多kernel launch、队列读写和压缩工作。不能预设后者必然更快；下一节用同一个积分器、随机身份和场景实现后比较。[PBRT GPU执行映射](https://www.pbr-book.org/4ed/Wavefront_Rendering_on_GPUs/Mapping_Path_Tracing_to_the_GPU)、[CUDA SIMT文档](https://docs.nvidia.com/cuda/cuda-programming-guide/02-basics/writing-cuda-kernels.html)。

## 10. 运行和继续

仓库根目录执行`learning/sandbox/path_tracing/cuda-path-tracer/verify_paths.ps1`。GPU脚本依赖上一小节导出的gallery.meshbin；绘图脚本及本课隔离依赖安装命令见README，所有结果在results/megakernel。绘图使用PFM原始线性float核对误差，预览经过Reinhard和一次sRGB。Matplotlib3.11.2/NumPy2.5.4/Pillow13.0.0位于本课build/python-deps，未修改系统包。

下节先回答：①RR终止为什么仍可能要执行当前ShadowTask？②为什么路径压缩后必须保留原pixel/sample身份？③活跃路径变少为什么不保证Megakernel耗时按比例降低？然后实现Wavefront射线/命中/阴影队列与compaction，继续Nsight验收。PT.11/PT.12仍待后续自动推进。
