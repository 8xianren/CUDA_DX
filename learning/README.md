# 学习资料总入口

当前项目：**模块化 CUDA / D3D12 / DXR 动态人物路径追踪 Demo**。学习与复习从下面入口进入；NVIDIA官方教程目录保持原样。

|现在想做什么|入口|
|---|---|
|直接运行当前Demo|[程序说明与双击启动](sandbox/d3d12/dynamic-character/README.md)|
|复习 F.1–F.10 抗锯齿、重建、超分与帧生成|[F 共享实验室与十节讲义](sandbox/d3d12/aa-reconstruction/README.md)|
|知道已经学到哪里|[当前学习进度](进度.md)|
|寻找任意课程的程序|[全部资料导航](资料导航.md)|
|查课堂讲义|[五条线路讲义总索引](笔记/README.md)|
|看光影、多灯、水体和画质的后续安排|[渲染器优化路线](规划/渲染器后续优化路线.md)|
|查完整课程顺序与教学要求|[学习计划](学习计划.md)|
|配置环境、构建或定位输出|[环境与构建](环境与构建.md)、[程序目录约定](sandbox/README.md)|
|找历史数据、迁移记录|[归档入口](归档/README.md)|

## 当前Demo

双击本机 `learning/sandbox/d3d12/dynamic-character/build/Release/character_demo.exe`。资源路径和质量档在EXE旁`character_demo.json`；无需先运行PowerShell。首次从源码恢复时按[工程README](sandbox/d3d12/dynamic-character/README.md)获取资产并构建。

默认1280×720、动态4 spp，天空/太阳参与照明，WASD/QE控制相机、右键转向，Space暂停、N单步、R复位。静止256 spp展示图和真实动态4 spp图分开标注。当前是受限教学渲染器；完整范围见[架构](sandbox/d3d12/dynamic-character/ARCHITECTURE.md)和[画质修正](笔记/d3d12/H.7-画质修正与程序天空.md)。

## 文件职责

2026-10-22新增F共享实验室：独立验证MSAA、FXAA、TAA、NIS、官方FSR/XeSS和官方帧生成，结果按课号存放。它复用既有D3D12基础资源模块；接入H人物路径追踪器属于后续应用工作，不能把F离屏实验的GPU时间直接当作H的FPS。

```text
learning/
├─ README.md / 资料导航.md    使用入口与完整程序目录
├─ 进度.md / 学习计划.md      当前状态 / 完整课程定义
├─ 规划/                     后续应用优化与计划导航
├─ 环境与构建.md              本机环境与运行方式
├─ 笔记/<线路>/              讲义：按课号查原理和实测
├─ sandbox/<线路>/<课程>/    程序、shader、验证脚本
│  └─ results/              本课图像、数值、日志和性能数据
├─ tools/                   目录生成与本地链接检查
└─ 归档/                    历史状态和资料迁移记录
```

成熟共享主线保留一份实现，基础实验按课程归档；不为课号复制一整套渲染器。构建缓存、下载资产和运行结果不列入源码目录计数，也不自动删除。

## 仓库关系

个人资料同步目标为[8xianren/CUDA_DX](https://github.com/8xianren/CUDA_DX)，原工作副本的remote为`cuda-dx`。原工作副本的`origin`继续跟踪NVIDIA官方教程；不把个人学习文件推到NVIDIA仓库。个人仓库包含最新H工程、资料重组和[聊天迁移包](../codex-chat-migration/README.md)；从个人仓库直接克隆时，`origin`指向个人仓库，以`git remote -v`为准。

构建产物、下载资产、实验图片和Nsight报告不提交；保留源码、资产恢复脚本、许可及数值验收记录。新电脑先按各课README恢复资源并构建，历史运行结果只代表记录时的环境。
