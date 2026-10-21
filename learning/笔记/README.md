# 学习讲义总目录

[学习入口](../README.md) · [完整学习计划](../学习计划.md) · [学习进度与验收记录](../进度.md) · [程序与复现实验](../sandbox/README.md)

截至本次整理，这里有 **108 篇讲义、补充课与实验记录**，按五条线路保存。各线路 README 是完整阅读索引；正文保持原路径，避免旧引用失效。本文中的篇数不包含 README，也不代表完成课节数。

| 线路 | 现有资料 | 阅读入口 | 程序入口 |
|---|---|---|---|
| CUDA | 1 篇：3.2 Streams 专题；其他已学内容的记录见进度与程序，未补造不存在的讲义 | [CUDA 索引](cuda/README.md) | [CUDA 程序](../sandbox/cuda/README.md) |
| D3D12 / DXR | 57 篇：R.0–R.13、C.1–C.6、D.1–D.4、E.1–E.3、H.1–H.7及补充 | [D3D12 / DXR 索引](d3d12/README.md) | [D3D12 程序](../sandbox/d3d12/README.md) |
| 粒子系统 | 4 篇：P.4.2、P.4.3、P.5.1、P.5.2 | [粒子索引](particles/README.md) | [粒子程序](../sandbox/particles/README.md) |
| 路径追踪 | 41 篇：PT.1–PT.12、多小节推导、复习与验收 | [PT 索引](path_tracing/README.md) | [PT 程序](../sandbox/path_tracing/README.md) |
| 图形着色器补充 | 5 篇：HLSL/GLSL、空间、绑定、插值、Billboard | [着色器索引](shaders/README.md) | 复用 D3D12 / 粒子课程，无独立重复工程 |

## 从哪里开始

- **继续当前小型渲染器**：先看 [H 阶段架构](../sandbox/d3d12/dynamic-character/ARCHITECTURE.md)与[运行入口](../sandbox/d3d12/dynamic-character/README.md)，再按 [H.1–H.7](d3d12/README.md) 回看资产、动画、仿真、输入、动态 DXR 与历史。
- **补渲染基础**：按 D3D12 索引走 R → C → D；R.13 以矩阵相机新版为主，旧基向量实验明确列作历史对照。
- **补路径追踪原理**：PT.1–PT.8 → PT.10 → PT.9 → PT.11 → PT.12。先掌握成像与积分，再比较 CUDA 执行架构与高级采样。
- **查 CUDA 与图形交接**：先读 Streams 与粒子互操作，再读 E.1–E.3；H 在此基础上引入真实角色蒙皮。

## 阅读约定

“主讲义”解释该节机制；“补充/复习”串联或加深已有知识；“测试记录”保留环境和验收证据；“历史对照”保留旧实现背景。各节正文的日期、阶段性失败和下一节安排反映当时状态，当前范围以[进度](../进度.md)及后续验收为准。

代码、Shader、验证脚本和结果统一从[程序索引](../sandbox/README.md)进入。讲义只保留一份，多个课节共享程序时链接同一主线。新增讲义时同步更新所属线路索引、这里的覆盖范围与进度；新增代码遵循[后续课程目录约定](../sandbox/README.md)。
