# PT.12 辐射缓存教学主线

2026-10-21开始。第一小节完成缓存后缀的物理定义、误差推导与UE/NVIDIA资料对照；第二小节已完成可运行缓存积分实验与均值/方差验收，整章审计已完成。

[第一节讲义](../../../笔记/path_tracing/PT.12-缓存后缀与三种表示.md)。本课将实现极小位置/朝向缓存，不训练MLP，不把教学表叫作NVIDIA NRC，也不声称实现Lumen探针系统。

|文件|职责|
|---|---|
|plot_overview.py|独立生成完整路径、缓存替换、探针插值三者的估计对象示意图；不产生数值实验数据|

仓库根运行，无编译步骤：

```powershell
python ./learning/sandbox/path_tracing/radiance-cache/plot_overview.py
```

图写入results/overview/path-cache-probes.png，复用相邻cuda-path-tracer/build/python-deps中的Matplotlib。后续实验源码、脚本和结果均归本目录，结果另建子目录，不平铺在线路根。


## 第二小节：方向缓存与偏差方差实测

[讲义](../../../笔记/path_tracing/PT.12-方向缓存与偏差方差实测.md)。cache_scene.h定义两次散射积分、方向性教学BRDF、面积抽样和独立后缀求积；directional_cache.h管理A/B系数网格、独立更新、双线性查询及版本/覆盖拒绝；verify_cache.cu负责4096独立run、5接收点、完整后缀与四缓存对照、仿射/格点/方向/非法查询检查；plot_cache.py绘制均值、偏差与方差并输出summary.json。

仓库根构建、运行、绘图：

```powershell
& ./learning/sandbox/path_tracing/radiance-cache/verify_cache.ps1
python ./learning/sandbox/path_tracing/radiance-cache/plot_cache.py
```

结果results/cache/含build/run.txt、checks.txt、statistics.csv、summary.json、bias-variance.png。每run重新更新缓存，64灯样本/节点、64路径/接收点。参考加密差5.27939e-6；3×3/9×9偏差RMS .00642398/.000445578。粗缓存方差更低而MSE更高，全部缓存均值匹配其近似积分。144/1296B只是系数逻辑内存；更新工作量另计，本小规模实验不构成加速。构建sm_120但计算全在CPU，未训练MLP、未实现Lumen系统。


## 最终验收

[逐项核对与课程收尾](../../../笔记/path_tracing/PT.12-最终验收与课程收尾.md)。2026-10-21完成，证据在results/final/audit.json：25组统计、两幅已查看的图、源码/结果哈希及PT.11七组实验已核对。PT.12按原定教学范围结束，本次自动课程停在PT.12。保留CPU/解析两次散射模型，无神经网络训练、NRC SDK集成或UE运行结论。
