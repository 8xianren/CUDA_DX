# H.1 资产体检与绑定空间

代码及命令：[dynamic-character](../../sandbox/d3d12/dynamic-character/README.md)。本节没有 GPU 动画执行，不能把导入成功称为动画播放成功。

## 1. 我们要解决什么问题

静态网格只有顶点和节点变换。角色会弯肘屈膝，需要一套随时间变化的坐标系，以及顶点跟随这些坐标系的规则。骨架是节点层级；动画轨道记录局部平移、旋转、缩放；蒙皮权重把顶点关联到骨骼。这三者是不同数据。

像引擎中的 Skeletal Mesh，模型形状、Skeleton 与 Animation Clip 可以是不同资源，但共享名字不证明比例与绑定坐标相同。我们的首版选同一文件里的角色与片段，先避免重定向。成熟引擎的重定向会处理骨骼比例、参考姿势与根运动，不是按同名直接覆盖 TRS。

## 2. 实际资产与选择

2026-10-21 下载并核验作者 Standard 免费包。UAL1 非 RM 文件包含 43 个动作，65 个关节，Assimp 拆成两个 primitive 网格，共 8546 顶点、13744 三角形。Idle_Loop、Walk_Loop、Sprint_Loop、Jump_Start、Jump_Loop、Jump_Land 均存在。世界 Y 范围约 0.00046 到 1.82918，可作为约 1.83 米角色使用；这是资产尺度约定，不是从人类身高反推坐标。

Base Characters 的 Superhero Male 有 8483 顶点、14318 三角形。两个包共享 66 个同名节点、父子关系一致，但最大局部矩阵差为 0.2766。因此先用 UAL 自带 Mannequin。候选人物两张法线图 URI 多了 `_png`，准备脚本用精确别名复制修复，不模糊搜索或悄悄丢图。

许可证和 SHA256 见资产清单；环境选择 Kenney 的树、灌木、石头。下载缓存与最终运行资产分别管理，避免把所有格式和大图全部发布到学习仓库。

## 3. 从空间转换推导蒙皮

约定列向量，p 是网格绑定时的局部点。某骨骼的逆绑定矩阵 O_j 把该点送到骨骼绑定空间；G_j(t) 是当前骨骼到世界的变换。于是这根骨骼独立影响点的世界结果是 G_j(t) O_j p。多骨骼线性混合为 sum(w_j G_j(t) O_j p)。

若缓存仍存网格局部坐标，还要左乘当前网格世界变换 M(t) 的逆：S_j(t)=inverse(M(t))*G_j(t)*O_j。位置 p'(t)=sum(w_j S_j(t) p)，权重非负且总和为 1。Assimp 的 mOffsetMatrix 对应 O_j；不能把它当作要直接追加到动画旋转上的位移。

绑定时 G_j(bind)*O_j 应等于网格绑定世界矩阵，所以 S_j(bind)=I。前提是节点默认姿势确实对应绑定姿势；格式允许两者不同，因此探针先测量而不是盲目假设。

独立 NumPy 原始 glTF 审计得到绑定位置最大误差 6.8498e-7，权重和误差 1.1921e-7。故意漏掉 O_j 后误差 1.5714，负对照被检出。Assimp 检查的绑定矩阵最大误差 7.1526e-7，两条不同数据读取路径相互佐证。

glTF 矩阵序列按列主序保存，NumPy reshape 必须显式 order='F'；Assimp aiMatrix4x4 的索引按行访问，但数学仍可使用列向量。存储顺序与乘法约定是两件事。

## 4. API、生命周期和失败路径

实际使用 `const aiScene* Assimp::Importer::ReadFile(const std::string& file, unsigned int flags)`。file 是输入路径，flags 使用 Triangulate 和 ValidateDataStructure，不启用 PreTransformVertices、骨骼裁剪、坐标翻转或节点合并。前者把多边形三角化，后者检查库解码后的结构，不代表完整原始 glTF 规范验证。

返回场景及其子数组由 Importer 持有；Importer 析构或再次加载会使旧指针失效。失败返回空指针，GetErrorString 提供诊断；探针返回非零退出码，不给后端传半构造资源。本节全部发生在 CPU，无 GPU 上传、Fence 或 CUDA stream。

aiAnimation 的 mDuration 与 key.mTime 都是 ticks；秒数=ticks/mTicksPerSecond。时间单位由实际导入结果记录，不猜测所有格式固定 25 或 30 FPS。aiNodeAnim 的 TRS 关键帧替换节点局部变换，不是相对于默认姿势的增量。本节检查轨道目标唯一、时间严格递增、四元数近似单位长度及缩放有效；插值在 H2 实现。

旧 LoadCpuScene 继续拒绝动画和骨骼，直到新适配器明确保存并处理这些信息。H1 的独立探针读取骨骼不等于允许旧静态后端忽略它们。

## 5. 动手与自测答案

运行 README 中的 verify_h1.ps1，检查 results/h1 的两个结构报告、兼容性报告和 gltf-audit.json。丢失文件应返回非零，静态石头应被旧导入器接受，动画应被旧静态入口拒绝。

为什么同骨骼名字不够？因为父子空间、参考姿势和骨段长度决定了局部 TRS 的含义。为什么不能省略逆绑定？因为顶点原本不在骨骼局部空间。为什么选非 RM 文件？因为首版由状态机更新世界位移，重复应用片段根位移会把角色移两遍。

下一节 H2：采样局部姿势，再做骨骼层级更新；先用 CPU 参考保证空间正确，再接 GPU 并行蒙皮。
