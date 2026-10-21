# D.3 纹理色彩空间与采样验证

2026-10-21。D.2之后的一整节，不再拆子课。目标：从DXR命中三角形得到UV，按材质选择纹理视图与sampler，返回正确的线性RGBA。本节基础色诊断不是完整PBR、光照或路径追踪。

[共享代码与命令](../../sandbox/d3d12/gltf-scene/README.md) · [ClosestHit](../../sandbox/d3d12/gltf-scene/shaders/material_rays.hlsl) · [GPU装配](../../sandbox/d3d12/gltf-scene/src/material_sampling.cpp) · [CPU参考](../../sandbox/d3d12/gltf-scene/src/material_sampling_test.cpp) · [结果](../../sandbox/d3d12/gltf-scene/results/d03/)

## 从命中位置推导UV

纹理映射像给模型表面贴一张画：顶点提供画上的坐标，命中点通常位于顶点之间，必须求出它对应画中的位置。BLAS负责空间求交，不会替应用导入或绑定材质。

三角形顶点P0/P1/P2与射线O+tD满足：

`O+tD=P0+b1(P1-P0)+b2(P2-P0)`。

DXR已完成求交，并把b1/b2作为BuiltInTriangleIntersectionAttributes.barycentrics返回。令b0=1-b1-b2，三权重之和为1。采用三角形内部的仿射属性插值约定，就有`uv=b0*uv0+b1*uv1+b2*uv2`，顶点色同理。这里是求交得到的三角形重心坐标，不再额外按clip.w做一次透视修正。光栅路径的屏幕空间插值才需要处理透视校正。

本主线一mesh一个BLAS、每BLAS一个geometry：InstanceID查80B对象表；对象表的mesh查16B网格范围；PrimitiveIndex是该geometry内的三角形编号。C++ Vertex=48B，position/normal/uv/color偏移为0/12/24/32B。索引uint32，仍为mesh局部值。

因此先从`4*(firstIndex+3*PrimitiveIndex())`读3个索引，再对各索引计算`48*(firstVertex+localIndex)`，最后加24B取UV、加32B取顶点色。firstIndex单位是索引元素，firstVertex单位是顶点元素，ByteAddressBuffer.Load的参数单位才是字节。共享缓冲区的两个偏移不能漏掉或重复叠加。当前若扩成一个BLAS多个geometry，还需GeometryIndex对应的范围表，不能照搬本课假设。

## UV方向：区分源规范、导入库与图片行序

核心glTF把(0,0)定义在图像左上。固定Assimp 6.0.2把源v转换成1-v；当前CPU结构保留库约定。WIC解码没有倒排图片行，因此shader在最终采样前执行`uv.y=1-uv.y`恢复源约定。这是本适配链的约定，不是D3D要求所有纹理翻转；若未来导入器输出原始glTF UV，该恢复必须相应取消。

自编fixture的源v=-0.75，测试独立断言CPU结果为1.75。不能只让CPU/GPU使用同一错误公式后互相证明。

官方BoxTextured父矩阵使world=(x,z,-y)，其朝+Z的面左侧u=4、右侧u=3、顶部v=0、底部v=1。因此正面logo应水平镜像。verify_official_orientation.py只审计这个固定样本的原始float32布局/矩阵/索引，并独立重算整张正面图；不是新的通用解析器。

## 从连续UV推导过滤

宽W高H的纹理，每个texel中心为((i+0.5)/W,(j+0.5)/H)。要把连续UV变成以texel中心为整数的坐标，令x=uW-0.5、y=vH-0.5。i=floor(x)、j=floor(y)、a=x-i、b=y-j。双线性值为：

`(1-a)(1-b)C(i,j)+a(1-b)C(i+1,j)+(1-a)bC(i,j+1)+abC(i+1,j+1)`。

point选择最近texel中心；非分界位置可写为floor(uW)、floor(vH)。UV=(0,0)处是图片边界而非首texel中心；双线性邻域可能跨边界，这就是需要address mode的原因。

对整数邻居应用寻址：REPEAT周期为W；CLAMP把索引限制到[0,W-1]；MIRROR周期为2W，后半段反向。u=-0.2的repeat为0.8，不能用截断代替floor。特别是repeat边缘，四个邻居必须各自寻址，不能先把UV clamp再过滤。U和V可分别设置，本次六组主验收让二者相同。

minification表示纹理被缩小、magnification表示被放大；mipmap是一系列低分辨率层，mip过滤决定层间如何选/混合，不等于层内双线性。当前纹理只有mip0，SampleLevel显式取0，MinLOD=MaxLOD=0。代码映射glTF min/mag/mip枚举，但实测只覆盖min=mag=point/linear，不宣称验证了完整mip链或各向异性。ClosestHit没有天然的光栅像素导数；后续射线footprint/显式梯度是另一个质量问题。

## sRGB：先解码每个texel，再过滤

PNG文件字节先由WIC解码为RGBA8编码值；这是图像格式解码，不是sRGB传递函数解码。UNORM把整数q映射为q/255。对sRGB颜色通道，线性值D(c)为c<=0.04045时c/12.92，否则((c+0.055)/1.055)^2.4。

要求颜色能做线性加权混合，决定了应先D(c_i)再加权；因为D非线性，D(sum(w_i*c_i))一般不等于sum(w_i*D(c_i))。黑白中点正确线性结果0.5；先平均编码值再解码只有约0.214。按sRGB显示时，线性0.5约编码成188/255。

资源仍为R8G8B8A8_TYPELESS，D.1已为每张图创建UNORM与UNORM_SRGB两个SRV。本节根据基础色槽选择sRGB视图。一个资源可有不同解释视图，无需复制纹理；颜色空间属于用途，不能仅凭PNG后缀判断。sRGB只转换RGB，alpha保持线性。baseColorFactor、顶点色也是线性值，不能重复解码。

最终基础色RGBA为`sampledTexture * baseColorFactor * interpolatedVertexColor`，alpha同样相乘，但本节强制opaque进行求交，仅验证alpha数值，不实现MASK/BLEND可见性。normal、metallic-roughness、occlusion应使用线性数据视图；emissive颜色纹理用sRGB。后续PT.8展开实际BRDF、法线切线空间及材质可见性，本节不把五槽元数据称为五槽着色已完成。

## GPU绑定、API、所有权与失败路径

HLSL纹理读取本课使用`float4 Texture2D<float4>::SampleLevel(SamplerState sampler,float2 location,float lod)`。这是本课类型对应的三参数形式，另有可选offset/status重载。sampler决定寻址与过滤；location是归一化UV；lod=0显式选择mip0。返回RGB已按SRV格式解码，alpha未做sRGB转换。

`void ID3D12Device::CreateSampler(const D3D12_SAMPLER_DESC* pDesc,D3D12_CPU_DESCRIPTOR_HANDLE DestDescriptor)`：pDesc是CPU侧配置，DestDescriptor是SAMPLER heap中的CPU写入位置，函数不返回HRESULT。结构体字段：Filter为min/mag/mip过滤组合；AddressU/V/W为三个维度寻址；MipLODBias为LOD偏移；MaxAnisotropy仅各向异性模式使用；ComparisonFunc仅比较过滤使用；BorderColor[4]仅BORDER使用；MinLOD/MaxLOD限定级别。当前bias0、anisotropy1、comparison NEVER、border0、LOD范围0。初版ALWAYS在当前Debug Layer产生提示，已改为NEVER，最终warning/error为0。

`void SetDescriptorHeaps(UINT NumDescriptorHeaps,ID3D12DescriptorHeap* const* ppDescriptorHeaps)`：本课Num=2，数组包含GpuScene的CBV_SRV_UAV heap与本批次SAMPLER heap。一次至多绑定每种shader-visible heap各一个。`void SetComputeRootDescriptorTable(UINT RootParameterIndex,D3D12_GPU_DESCRIPTOR_HANDLE BaseDescriptor)`分别将8、9号root参数指向两种heap起始GPU handle。CPU handle写描述符，GPU handle供命令引用，二者不是纹理数据指针。

t0为TLAS，t1对象表，t2/t3原始VB/IB，t4网格范围，t5材质表，t6输入射线；u0为float4输出。space1中的t0纹理数组与space0的t0 TLAS不是同一绑定。32B材质记录为float4 factor加textureIndex/samplerIndex/padding两个uint。不同射线可能命中不同材质，纹理和采样器数组索引均用NonUniformResourceIndex标明非一致性。本课使用无界descriptor range，实际访问仍受CPU构造的有效索引限制，无界声明不等于无限内存。

VB/IB保留NON_PIXEL_SHADER_RESOURCE读状态；纹理同时支持PIXEL与NON_PIXEL读取。BLAS/TLAS保持AS专用状态，构建后的UAV barrier建立依赖。输出UAV写→COPY_SOURCE transition→CopyBufferRegion到Readback→提交→Fence完成→Map读取。SubmitWait完成后才能释放局部材质/网格/射线表、sampler heap、SBT及输出；GpuScene/BLAS/TLAS由外层持续持有。描述符不会替应用延长资源寿命。

非法wrap/filter、UV集合、空输入会抛错；创建资源/管线等HRESULT经Check检查，shader编译失败由脚本终止，Debug Layer警告或错误使验收失败。库/Validator校验仍在GPU测试之前。当前并非设备移除恢复框架；继承的异常退出也不能当作生产多帧资源回收方案。

## 本机实测

RTX5070，DXC lib_6_3，C++由CMake/VS2022构建，无CUDA kernel所以此目标不使用nvcc；后续CUDA程序仍必须sm_120。两个原始glTF均Validator errors0/warnings0。

|输入|每组样本|组数|最大RGBA绝对误差|
|---|---:|---:|---:|
|自编2x2纹理、两primitive/不同因子|992|6|0.00562435|
|官方BoxTextured|5952|6|0.00199491|

总计41664条数值对照，阈值0.006内全部通过；这是绝对线性分量误差，不是相对误差或显示码值误差。GPU过滤与sRGB转换有有限精度，CPU参考不要求逐bit一致；本实验没有进一步隔离误差来自权重量化、颜色转换还是其它环节，不把某个单一机制当作已证明原因。point样本避开texel分界，第一次正好落边界时曾产生邻格选择差异，不能把不连续采样的分界结果当作稳定验收点。

每组wrong_v与wrong_srgb反例都有超过0.03的明显差异。它们是故意错误的CPU参考，不是另外运行了错误GPU shader。每组三色通道/alpha/顶点色/材质因子均对照。官方正面另有16384条射线，直接原始glTF参考逐像素RGB码值最大差1。通常Fence2/2；额外正面预览那组Fence3/3。所有组Debug/GPU Validation warning/error0。D.2四阶段229376像素回归mismatch0、Fence5/5、Debug0。

![官方样例真实GPU正面读回](../../sandbox/d3d12/gltf-scene/results/d03/official/box-front.png)

官方资产：KhronosGroup/glTF-Sample-Assets，固定commit 15cd02d304e54cb42a4db4eefe719f76190f4b68，BoxTextured（Cesium）。下载文件、来源、SHA256及LICENSE在results/d03/BoxTextured，CC-BY-4.0；标志另受原商标条款约束。水平镜像来自该面原始UV，非loader错误。

## 动手与工程边界

从仓库根执行，每步成功后继续：

```powershell
& learning/sandbox/d3d12/gltf-scene/build_importer.ps1 -Lesson d03
& learning/sandbox/d3d12/gltf-scene/verify_sampling.ps1
python learning/sandbox/d3d12/gltf-scene/preview_sampling.py
python learning/sandbox/d3d12/gltf-scene/verify_official_orientation.py
```

preview脚本依赖Pillow，只做真实读回PPM→PNG格式转换。结果日志、CSV、预览全部在本课results/d03。已有C.6 Node依赖；新副本按共享README先完成依赖初始化。

练习：预测2x2纹理uv=(.5,.5)在point与linear下的结果；解释黑白平均为何0.5不应再次sRGB解码；沿ClosestHit指出firstIndex与firstVertex分别消除哪一种错位。

引擎通常复用PSO/描述符与材质缓冲、缓存sampler、提供离线mip/压缩及异步上传/退役。本课每组重新创建资源并等待Fence，目的是隔离语义和验证，不是吞吐设计；描述符解释、重心插值、sRGB和同步依赖的底层机制一致。下一节D.4整理解析器/资源工厂/命令录制边界，之后PT主线接入光照积分与完整材质。

## 权威依据

- [glTF 2.0规范](https://github.com/KhronosGroup/glTF/blob/main/specification/2.0/Specification.adoc)：UV原点、基础色与因子语义。
- [SampleLevel](https://learn.microsoft.com/en-us/windows/win32/direct3dhlsl/dx-graphics-hlsl-to-samplelevel)：显式LOD采样。
- [D3D12_SAMPLER_DESC](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ns-d3d12-d3d12_sampler_desc)：配置字段。
- [DXGI颜色空间转换](https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/converting-data-color-space)：SRGB视图读取/输出转换。
- [Direct3D功能规范](https://microsoft.github.io/DirectX-Specs/d3d/archive/D3D11_3_FunctionalSpec.htm)：纹理采样、格式转换和精度约束。


2026-10-21 D.4维护：sampler与mesh/material表准备已移至[material_bindings.cpp](../../sandbox/d3d12/gltf-scene/src/material_bindings.cpp)，调用PrepareMaterialBindings返回MaterialBindings；SampleHitMaterials改收该对象。D.3 shader/布局/数值结果保持，完整回归通过。见[D.4](D.4-解析器资源与命令提交边界.md)。
