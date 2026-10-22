# G 实验室的模块和交接契约

[工程入口](README.md) · [G10讲义](../../../笔记/d3d12/G.10-表示集成与跨API同步.md)

```text
Window / 输入1–4、R
          ↓
app Frame：相机/尺寸/设备输出缓冲（拥有者）
          ├─ VolumePass → CUDA 3D texture积分
          ├─ GaussianPass → project / CUB scan-sort / tile splat
          └─ NerfPass → 已训练网络离线输出的显式CPU staging
                     ↓ 线性预乘float4
SharedTexture：CUDA linear buffer → CUDA mapped array → D3D12 texture
                     ↓
Graphics：真实网格MRT color/Z → radiance合成 → SDR编码 → swapchain
```

相机采用 +X右、+Y上、+Z前；世界原点在场景中心，eye=(0,0,-3)，垂直 FOV 50°。图像左上原点，像素中心 `(x+.5,y+.5)`。内参 `fx=fy=height/(2*tan(25°))`，`cx=width/2,cy=height/2`，投影 y 取负号。resize更改宽高和内参，不能只更改输出buffer。

## 所有权

|对象|拥有|借用/寿命|
|---|---|---|
|UploadContext|D3D device、queue、allocator、list、内部Fence|整个应用最后销毁|
|Volume|3D CUDA array、texture object、occupancy|Render借用输出，不存帧指针|
|gs::Renderer|canonical高斯、投影、CUB临时区、tile ranges|setScene替换前完成上次工作；render会为计数检查同步|
|DeviceFrame|CUDA color/depth/meshZ/meshRay|销毁前同步该stream|
|SharedTexture|D3D committed resource、external memory、mipmapped array|mip0只借用；顺序释放mip→external memory→D3D|
|Graphics|PSO、root signature、view heaps|资源另由app持有；覆盖view槽前提交已完成|
|NerfPass|CPU缓存文件副本|上传显式复制，PyTorch进程已经结束|

## 两条单生产者 Fence

第 `n` 帧的 `ready=n` 只由 D3D Signal，`done=n` 只由 CUDA Signal：

1. D3D 绘制真实网格，写颜色及 R32_FLOAT camera-Z；深度共享纹理、输出共享纹理归入 COMMON。
2. 提交后 D3D Signal ready=n。
3. CUDA stream Wait ready=n；读共享深度 array 到 linear buffer；换算 `t=Z/d.z`。
4. 本帧 Pass 生成预乘 RGBA；复制到共享输出 array；CUDA Signal done=n。
5. D3D queue Wait done=n；共享颜色 COMMON→PIXEL_SHADER_RESOURCE；合成并显示。
6. 最终本地 Fence 完成后，CPU可回收/覆写帧资源和view；resize先排空双方，再重新导入新纹理。

资源状态只说明 D3D12 的合法用法，不能代替 CUDA/D3D12 执行依赖；Fence 只说明先后完成，不能代替纹理状态转换。两者都需要。本课采用单帧同步基线，明确没有实现生产级多帧流水和异步重叠。

## 颜色和深度

全屏合成 `C = Cpremul + (1-alpha)*Cmesh` 在线性空间完成，最后一次转换到 sRGB 编码写 RGBA8_UNORM。共享颜色是 RGBA32_FLOAT，共享网格深度是 R32_FLOAT；CUDA array映射采用完全一致的 channel/extent/mip。

所有Pass输出深度的单位统一为 camera-Z，但统计意义不同：Volume是累积alpha首次超过0.5的位置；Gaussian/NeRF是贡献权重的条件期望。它们都是诊断guide，不能当成精确不透明深度。真正遮挡从网格几何深度送入积分或高斯裁切，而不是事后比较两个平均深度。

参考照片高斯的颜色拟合通常使用照片编码值；导入预览明确在合成外观后解除预乘、sRGB解码、重新预乘。这是显示适配假设，不代表该训练资产提供物理标定的线性辐射亮度，也不是对原论文图像指标的复现。

## 验证边界

独立CPU核对网格Z、Z到射线距离、体渲染遮挡及预乘合成；G6–8另对高斯投影/排序/图像进行CPU对照。G10内存与同步工具覆盖真实共享texture读写；D3D Debug/GPU validation与性能模式分开。训练集/假设场景不同的表示只做工程成本与可编辑性对照，不进行伪公平画质排名。
