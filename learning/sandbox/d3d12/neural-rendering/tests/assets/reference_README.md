# G.9 配对资产与参考相机预览

从仓库根目录执行，先已构建本课 `g_gaussian` 共享库：

```powershell
python learning/sandbox/d3d12/neural-rendering/python/assets/reference_camera.py
& learning/sandbox/d3d12/neural-rendering/tests/assets/reference_build.ps1
python learning/sandbox/d3d12/neural-rendering/python/assets/reference_preview.py
```

Python需要NumPy/Pillow，可使用本课 `.venv/Scripts/python.exe`。独立构建面向 `sm_120`，使用 `/MD` 与CMake Release库的CRT保持一致。不修改窗口程序、主CMake或原资产导入测试。

镜像固定为 [camenduru/gaussian-splatting](https://huggingface.co/camenduru/gaussian-splatting/tree/c63df2ffae19c1d288f81c1d5faf53ff6661be84/train)，revision `c63df2ffae19c1d288f81c1d5faf53ff6661be84`；使用同一目录的7000步PLY与 `cameras.json` 中的camera0。667,872个degree3高斯全部加载，不做bbox归一化或抽样。它与G.9原先741,883个高斯的另一份公开资产不同，两者的文件、相机、报告不能混用。

下载文件保存为 `downloads/reference/camera-paired-*`；结果在 [reference-preview](../../results/g9/reference-preview/report.json)。`reference_camera.py`复用严格PLY转换器，但隔离报告输出，保留原`results/g9/import.json`。新的[逐字段导入报告](../../results/g9/reference-preview/camera-paired-import.json)和[相机来源报告](../../results/g9/reference-preview/camera-provenance.json)分别保存。

上游[相机JSON写出函数](https://github.com/graphdeco-inria/gaussian-splatting/blob/main/utils/camera_utils.py)把C2W的旋转和位置写入JSON；本课先求逆得到world→camera，再左乘`diag(1,-1,1,1)`把相机Ydown转Yup。几何原坐标保持不动，镜头fx/fy分别按640/1959、360/1090缩放。脚本独立验证刚体逆矩阵、三点投影以及实际float32相机误差，超过阈值立即失败。

预览调用`gs::Renderer`直接渲染640×360，所有中间输出归本验证程序所有，API返回前同步stream，再把RGBA读回为`camera0.f32`。PNG黑背景合成后直接量化RGB，不再额外做gamma。上游训练通常直接拟合输入图像RGB数值，本资产没有提供足以证明物理线性辐射的色彩元数据，所以不能无条件把这份参考模型的颜色称为物理线性HDR。

一次暖机加一次测量结果：完整667,872、可见517,029、tile引用2,079,055，单次CPU墙钟3.8765ms。它用于证明完整参考资产和相机可共同工作，不是重复统计的性能基准；阶段GPU时间、分配字节、文件SHA256、源码SHA256见报告。

图像能看到火车主体，但未声称和官方渲染逐像素等价。具体差异包括本课近面0.05、屏幕半径上限4096，以及没有上游在计算投影协方差前进行的离轴夹取；上游[近面筛除](https://github.com/graphdeco-inria/diff-gaussian-rasterization/blob/main/cuda_rasterizer/auxiliary.h)使用0.2，[投影协方差](https://github.com/graphdeco-inria/diff-gaussian-rasterization/blob/main/cuda_rasterizer/forward.cu)还限制x/z、y/z到1.3倍视场边界。偏灰外观的具体误差贡献尚未做消融，不能仅凭图像断言是训练质量或相机错误。原始PLY、GSBIN、PNG、浮点输出均不提交，脚本和数值报告可复现。
