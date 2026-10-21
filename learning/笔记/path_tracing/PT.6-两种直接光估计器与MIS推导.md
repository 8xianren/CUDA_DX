# PT.6：从两个直接光估计器推导 MIS

2026-10-21，PT.6进行中。本次讲透直接光MIS的估计器、共同测度、Balance/Power权重与delta边界，并完成CPU采样/积分+真实glTF/DXR遮挡实验。尚未把采样/PDF/积分迁入GPU shader，也没有相机主射线或多次反弹，不标记整章GPU积分器完成。

[代码/运行入口](../../sandbox/path_tracing/pt06-mis/README.md) · [数学与参考](../../sandbox/path_tracing/pt06-mis/mis_math.h) · [估计器](../../sandbox/path_tracing/pt06-mis/mis_test.cpp) · [结果](../../sandbox/path_tracing/pt06-mis/results/)

## 上节答案

PrepareMaterialBindings之后改CPU因子仍读旧GPU表，因为已复制出快照。UploadScene把原始vector数据复制进Upload后，原始数组可在无其它CPU用途时释放；staging必须等对应GPU复制Fence完成，函数返回/录制完成不够。

## 要求解的积分与两种选择

固定表面点x、出射方向wo，仅考虑来自发光体的直接光：I=∫Ω F(w) dw，F=fr(x,wo,w) Le(y,-w) V(x,y) max(0,n·w)。当前Lambert fr=rho/pi。V是可见性，0或1；找不到光源时Le为0。BSDF包含反射与透射，本课只用其反射部分BRDF。

BSDF采样根据散射分布选择方向，本课余弦半球pB=cos(theta)/pi；NEE直接选光源点，连接表面。小灯只占很小方向范围，BSDF多数射线找不到灯；大灯覆盖很广时，BSDF与Lambert*cos更匹配，面积均匀抽样可能浪费在远而倾斜的灯面。PDF是相对于所选积分测度的概率密度，不是某个精确方向的概率，可大于1。

## 先统一面积与立体角

小面积dA向观察点投影后对应立体角dω=cos_light/r²*dA。概率相等pA*dA=pL*dω，故pL=pA*r²/cos_light。均匀矩形面积A时pA=1/A；多光源还需乘选灯概率q_l。本实验只有一灯，q_l=1。

pB与转换后的pL都相对dω，才可进入同一个MIS权重。pA单位m^-2，pB单位sr^-1，不能直接比较数值。本灯z=2、表面z=0、法线相向，cos_light=cos_surface=c，r²=4/c²，所以pL=4/(A*c³)。方向不交灯面时pL=0；遮挡放在F的V里，本实验采样策略不因遮挡而改变PDF。

## 无偏约束先于权重公式

从pL采样，XL=F(wL)/pL(wL)；从pB采样，XB=F(wB)/pB(wB)。二者都估计I，直接相加的期望是2I。注意错误不是“随机抽到了同一精确射线”，而是两个估计器各自积分了整个目标。

0.5*(XL+XB)也是合法无偏估计，但固定半权重可能保留较差方法的大噪声。更一般：Ihat=wL(wL)F(wL)/pL(wL)+wB(wB)F(wB)/pB(wB)。期望为∫(wL(w)+wB(w))F(w)dw。只要在贡献区域权重和为1、某策略PDF为0时相应权重为0、联合采样支持覆盖非零F，就保持目标积分。权重为0的项不要计算0/0。

这是对同一个方向w的两个权重要求，不是要求实际两个不同随机方向的权重相加等于1。

多样本版本：sum_i (1/n_i) sum_j w_i(X_ij)F(X_ij)/p_i(X_ij)。每策略已自行取平均，最后不再额外除策略数量。

## Balance与Power

满足权重约束的方法不唯一。Balance选择wL=nL*pL/(nL*pL+nB*pB)，wB对称。等样本数时，两条样本各自贡献都可写为F/(pL+pB)，但PDF必须在各自的样本方向重新求值。

Power通常取指数beta=2：wL=(nL*pL)^2/((nL*pL)^2+(nB*pB)^2)，wB对称。它更偏向对当前方向分配高密度的策略，是启发式选择，不是由无偏条件唯一推导出的最优公式，也不保证超过最好的单一策略。

例：同一方向pL=20,pB=.2，等样本数；Balance灯权约.990099，Power约.999900。对于BSDF偶然抽中的这个方向，即使F/pB很大，也会因另一策略更容易覆盖它而得到较小BSDF权重。

Weight(own,other,exponent)函数见mis_math.h:9。本课样本数相等，n约掉。先按max(own,other)缩放，避免平方大数溢出；own<=0返回0。单样本混合模型还需要策略选择概率alpha，本节采用每策略分别抽样模型，不把两者归一化混用。

## glTF/DXR实验的执行契约

生成两个合法核心glTF资产，均含三个mesh/node：receiver z0、面积灯z2、遮挡板z1。小灯半边长.25，大灯4；receiver反射率.8、灯emissiveFactor=1。场景因子由Assimp适配读取；本教学约定把emissive标量映射到单位辐亮度标尺，不把glTF无量纲因子直接称为有固定物理单位的测量值。没有纹理、完整PBR或法线贴图。

CPU在24×24固定表面点生成样本，GPU通过D.4的共享资源/BLAS/TLAS/根签名/SBT/提交接口进行真实求交。射线结构32B：origin float3+tmin、direction float3+tmax；tmin=1e-5避免receiver自交，tmax=1e6用于本有界场景。灯采样射线也发到灯面以获得同一最近命中身份，而不是用提前截断的传统shadow-ray接口。灯后物体不可能先于灯成为最近命中；只接收发光材质ID作为入射光。

visibility.hlsl使用16B payload float4，t0 TLAS、t1对象表、t6输入、u0结果。TraceRay(scene,FORCE_OPAQUE,255,0,0,0,ray,p)中255为实例mask，后面三零分别为ray contribution、geometry contribution multiplier、miss index；单HitGroup单Miss，本节ClosestHit不递归。命中返回material+1及t，Miss返回0。CPU从命中材质与方向计算Le、PDF和积分贡献。

复用SampleHitMaterials(context,bindings,gpu,frame,rays,dxil)的提交外壳，但本节DXIL将返回float4解释为身份/距离，不是D.3颜色。这是固定教学复用，后续应抽取语义明确的可见性接口，避免把这个名字当作最终通用设计。

UploadScene与BLAS录制后Fence1等待，释放staging/scratch；TLAS录制后与第一次Dispatch同队列执行，依赖由UAV barrier保证。每批输出UAV→COPY_SOURCE→Readback→SubmitWait→Map。场景/绑定/TLAS活过全部seed循环，局部输出/SBT等活到本批Fence完成。每场景16批，共Fence17/17。shader lib_6_3，C++由VS2022构建，没有CUDA kernel；CUDA仍sm_120。

## 公平预算与结果

每个表面点64轮，单策略每轮2条同类方向，MIS每轮1灯+1 BSDF，因此每方法128方向样本。程序每轮实际生成2灯+2 BSDF以共享对照，MIS复用其中各1条；不是分别计时的性能benchmark。16个固定种子，各像素独立RNG流。两个场景各2359296条实际DXR射线，共4718592条，CPU独立灯/板几何判断与GPU发光命中mismatch0。

参考为面积域512²中点求积，另与256²比较；小/大灯逐点最大变化4.50307e-5/0.00179304。这是求积收敛诊断，不是严格误差上界。所有MSE在线性辐亮度上算；不是对截图算误差。

|方法|小灯MSE|大灯MSE|
|---|---:|---:|
|BSDF-only|4.35119e-5|8.72605e-4|
|NEE-only|1.03893e-7|4.67570e-3|
|Balance MIS|2.24817e-7|1.41651e-3|
|Power MIS|2.14259e-7|1.68281e-3|

小灯Power相对BSDF约203倍MSE改善，但NEE更好；大灯Balance相对NEE约3.30倍改善，但BSDF更好。分给较差策略的样本有机会成本，MIS不保证击败场景内最优单策略。Balance/Power也没有普遍赢家。

小灯参考空间均值.00726283、Power .00726564；大灯参考.616138、Power .616217。16次均值与参考在本测试统计/求积容差内相容，不用有限样本宣称“实验证明严格无偏”。wrong-add结果.0144163/1.23342，接近参考两倍。日志还输出跨seed像素方差、均值标准误SE；MSE衡量相对参考的平方偏差，样本方差衡量重复结果围绕其均值的波动，两者不同。

两份glTF Validator errors0/warnings0，GPU Debug/GPU Validation0。没有新增性能比较结论。

![数值CSV绘制的同曝光对照](../../sandbox/path_tracing/pt06-mis/results/comparison.png)

上排小灯曝光×16，下排大灯×1；每排所有方法同曝光，图示seed0，表格则汇总16seed。像素是固定表面点，不是完整相机成像。预览sRGB编码并裁到显示范围，原始CSV保留线性结果。

## delta边界

点光源从固定表面只对应一个精确方向，连续半球采样命中该方向概率为0；其采样包含离散/奇异分量，不能把普通有限sr^-1数值硬塞进同一公式。对理想点光源NEE，连续BSDF策略不能竞争该事件，使用权重1，贡献按点光源强度/距离平方等专用公式计算。

理想镜面BSDF只允许确定反射方向，也不是普通连续PDF。沿该delta散射事件命中发光体时，普通连续灯面采样不能生成同一镜面连接，通常给该事件权重1；不能以“PDF数值返回0”为由删掉镜面贡献。实际BSDF接口需要区分连续与delta事件。粗糙度很小但非零的光泽分布仍是连续分布，不能随意当delta。本次只有Lambert与面积灯，delta机制为讲解，未做GPU镜面/点光专项实验，后续GPU积分及PT.8材质补齐。

## 下一步

本课结束时计划继续PT.6，把采样/PDF/权重迁入GPU积分shader并接相机主射线。2026-10-21后续课堂已完成该接入和RTX5070验收，见[GPU积分与正交相机](PT.6-GPU积分与正交相机.md)；当前PT.6漫反射单灯直接光范围完成，下一课PT.7多次反弹。本文保留前课CPU实验记录。

自测：灯与BSDF各一条样本的MIS和为何不再除2？同一方向pL=0而pB>0时BSDF权重是多少？为什么两种策略的PDF必须同为立体角密度？

参考：[PBRT MIS](https://www.pbr-book.org/4ed/Monte_Carlo_Integration/Improving_Efficiency)、[PBRT灯接口与delta](https://www.pbr-book.org/4ed/Light_Sources/Light_Interface)、[PBRT路径追踪](https://pbr-book.org/4ed/Light_Transport_I_Surface_Reflection/A_Better_Path_Tracer)、[Veach与Guibas 1995原论文](https://www.graphics.stanford.edu/papers/combine/)。
