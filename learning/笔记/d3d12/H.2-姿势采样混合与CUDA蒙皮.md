# H.2：从动作片段到变形网格

2026-10-21，代码见[共享工程](../../sandbox/d3d12/dynamic-character/README.md)，模块关系见[架构](../../sandbox/d3d12/dynamic-character/ARCHITECTURE.md)。

## 目标与直觉

动画片段是随时间变化的关节局部姿势，不是每帧完整顶点副本。可以把骨骼想成层级安装的机械臂：上臂改变会带着前臂走，但前臂仍保留相对上臂的姿势。角色在世界中跑了几米是仿真模块的问题；挥臂抬腿是动画模块的问题。

## 先推导空间链

假设采用列向量，矩阵按行存储（存储顺序不改变乘法含义）。设绑定顶点为 p，逆绑定矩阵为 B_j，当前关节世界矩阵为 J_j，网格节点世界矩阵为 M。B_j 将绑定网格点送到关节绑定空间，J_j 将它送到当前世界空间。如果输出缓存仍以网格局部空间解释，就必须再乘 M⁻¹。因此单关节矩阵为 P_j=M⁻¹J_jB_j，多关节位置为 p'=Σw_j P_j p。最后实例变换再乘 M，不能把 M 重复算两次。角色整体变换在 App 提取阶段另行合成。

层级矩阵必须父先于子：W_child=W_parent T R S。先混合局部 TRS，再求层级；直接线性混合世界矩阵通常破坏旋转的正交性。位置/缩放在两键时间间 u=(t-t0)/(t1-t0) 线性插值；四元数使用最短弧 Slerp 并归一化，q 与 -q 代表同一旋转，符号必须统一。

## 实际接口与所有权

`src/animation/animation.cpp` 提供：

```cpp
std::vector<Pose> Sample(const Rig&, uint32_t clip, double seconds, bool loop=true);
std::vector<Pose> Blend(const std::vector<Pose>& a,
                        const std::vector<Pose>& b, float alpha);
std::vector<Mat4> Worlds(const Rig&, const std::vector<Pose>&);
std::vector<Mat4> Palette(const Skin&, const std::vector<Mat4>& world);
```

Rig 是加载后由应用持有的自有 CPU 数据，参数引用只借用；返回 vector 自有内存。clip 是片段下标，seconds 已转换为秒。loop=true 对片段长度取模，否则夹取首尾；缺失轨道保留节点默认 TRS。Blend 的 alpha 必须有限且在[0,1]，两组姿势长度必须一致。Worlds 要求节点父索引在前；Palette 需要网格矩阵可逆。非法片段、非有限时间、尺寸错误及不可逆矩阵抛错，不默默输出随机姿势。

`AnimationPlayer` 只接收目标片段和时间。切换时捕获当前姿势，0.12 秒内混合到新动作；它不包含 Idle/Jump 等游戏状态枚举。具体资产名与状态映射放在 `src/app/locomotion_mapping.h`。

`SkinDevice::Record(const SkinMatrix* paletteHost, cudaStream_t stream, Vertex* externalOutput=nullptr)` 只提交操作：paletteHost 在流完成前保持有效；stream 是后端拥有的非默认流；externalOutput 为空时写内部输出，否则写外部共享缓存。调用方负责完成异步工作后再销毁输入与资源。

Vertex 48B，Influence 32B（4个uint32关节索引+4个float权重），SkinMatrix 112B（16float位置矩阵+12float法线矩阵）。CUDA 一线程一顶点，128线程一块，尾线程检查越界。绑定顶点不改；输出仅替换位置/法线，UV/颜色保留。法线按各关节逆转置加权再归一化；这是常用蒙皮近似，不等于空间变化权重所定义形变的精确雅可比逆转置。当前无切线字段、无法线贴图着色，不声称切线空间蒙皮已经实现。

## 动手与结果

仓库根运行 `& learning/sandbox/d3d12/dynamic-character/verify_h2.ps1`。六动作、五时间、两网格共60项：CPU/CUDA最大误差3.57628e-7，绑定误差7.52509e-7，循环及混合端点误差0；最终版本 memcheck 0错误、0泄漏。

独立 Python 直接解析原始 GLB，双精度采样/层级/蒙皮，Walk 中点两网格误差4.4980e-7与4.6040e-7。发现 Assimp 根据索引首次出现顺序重排顶点，参考程序先核对绑定点再建立对应，不能把同一数组下标武断当作同一顶点。结果在 `results/h2/`。

本课只支持所选资产已审计的 LINEAR 动画和最多4权重。通用 CUBICSPLINE、重定向、压缩、动画图和脚底 IK 不在本次范围。商业引擎通常预处理片段并按任务图批量更新；本课保留直接采样，以便检查每个空间转换。

自测答案：逆绑定把顶点带回关节绑定空间；混合发生在局部姿势；动作播放不能代替世界运动。规范对照：[glTF 2.0 skins / animations](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html)。下一节把世界运动交给独立控制器。
