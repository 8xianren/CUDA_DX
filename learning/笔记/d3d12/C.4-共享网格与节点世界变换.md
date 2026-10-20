# C.4 共享网格与节点世界变换

2026-10-19。一个完整课节；[代码入口](../../sandbox/d3d12/gltf-scene/README.md)。继承 C.3 的自有 CPU 网格，新增节点层级和实例引用，不提前实现材质或 GPU 上传。

## 对象与约定

glTF 一个 mesh 可含多个 primitive；当前样例两个 primitive 经 Assimp 导入成为两个 aiMesh，分别复制为两个 CpuMesh。Left/Right 各引用 [0,1]，产生四个 node-mesh 引用，只有两份网格数组。CpuNode 存 name、parent、local/world、meshIndices；MeshInstance 存 nodeIndex/meshIndex，世界矩阵通过节点取得，不重复缓存。遍历保留无网格的 Group 节点。导入器合成 ROOT 后本例有五个节点，不能按原 JSON 节点编号访问导入结果。

CPU 本课保留导入坐标，采用列向量 p'=M*p；Matrix4 内存按行存 m[row*4+column]。行列向量、内存行列主序、坐标系轴约定是三个独立问题，不自动转换到 UE。glTF matrix 数组按列展开，交给 Assimp 解释；从 aiMatrix4x4 按具名行字段复制进自有 Matrix4，不 memcpy JSON 序列。

## 从空间映射推导乘法顺序

L_child 把节点局部点映射到父空间：p_parent=L_child*p_local。W_parent 把父空间映射到世界：p_world=W_parent*p_parent。代入得到 p_world=(W_parent*L_child)*p_local，所以 W_child=W_parent*L_child。根节点没有父空间变换，W_root=L_root；即使根无mesh，其变换也不能跳过。

TRS在列向量下：p1=S*p，p2=R*p1，p3=T*p2，故 L=T*R*S。glTF用TRS或matrix表达节点变换，不把二者重复相乘。缺失TRS分量使用平移0、单位旋转、缩放1。glTF四元数排列x/y/z/w，本例绕Z正转90度为(0,0,sqrt(.5),sqrt(.5))。依据：[Khronos](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#transformations)。

样例父Group为S(2,3,1)、Rz90、T(10,1,0)，子Left/Right为T(-2,0,0)/T(2,0,0)。对局部点(x,y,z)，先子平移x+d，再缩放(2(x+d),3y,z)，旋转(-3y,2(x+d),z)，平移得到(10-3y,1+2(x+d),z)。两个子原点为(10,-3,0)/(10,5,0)。不能简单把父子translation相加，因为父旋转缩放也作用于子节点的位置。

对应父矩阵为各行(0,-3,0,10)、(2,0,0,1)、(0,0,1,0)、(0,0,0,1)。若换成行向量表达，矩阵转置且 W_child_row=L_child_row*W_parent_row；这不是坐标轴转换。到D阶段还需单独适配D3D/DXR布局。非均匀缩放下法线要使用逆转置等已学规则，本节TransformPoint只处理位置。

## 课堂补充：重新挂接、非均匀缩放与剪切

2026-10-19，学习者提出实际引擎中的情形：Object 原来挂在 A 下，将它改挂到 A 的兄弟 B 下，希望世界外观保持不变，但缩放可能使结果难以匹配。关键不是“只要有 scale 就出错”，而是非均匀缩放与不对齐的旋转组合后，所需局部变换可能无法由单个 TRS 精确表达。

先区分操作目标：保持 local 不变，允许 world 改变；或保持完整 world 不变，重新求 local。继续采用本课列向量约定，第二种目标的约束为：

```text
W_B * L_new = W_old
L_new = inverse(W_B) * W_old
```

只要新父世界矩阵 W_B 可逆，而且节点允许保存完整仿射矩阵，这个解就能保持所有点的世界位置（忽略浮点误差）。若用行向量表达，公式对应为 L_new = W_old * inverse(W_B)。顺序变化来自表达约定，不是更换了空间映射。

困难出在将 L_new 再存成 position、rotation、scale 时。单个普通 TRS 的线性部分为 R*S，S 是对角缩放矩阵；它的列向量是旋转后的各轴乘以各自尺度，仍然两两正交。一般仿射矩阵则可能包含剪切（Shear），使轴斜交。矩形变成平行四边形是剪切的直观例子。

例如忽略平移和 Z，旧世界变换为旋转45度，新父为X缩放2、Y缩放1。令 c=sqrt(2)/2：

```text
W_old = [ c  -c ]     W_B = [ 2  0 ]
        [ c   c ]           [ 0  1 ]

L_new = inverse(W_B) * W_old
      = [ c/2  -c/2 ]
        [ c      c ]
```

L_new 两列的点积为 -(c*c)/4+c*c=3/8，不为零。因此它不能精确写成单个 R*S。把它强行分解回普通 TRS 必须丢弃或近似部分信息，物体可能出现形状、尺寸或方向变化。这是表达能力限制，不是单纯的浮点精度问题；用三个世界缩放分量除以父缩放，也无法通用地补偿旋转改变的缩放轴。

保持物体原点的世界位置，比保持整个物体的世界变换要求更弱。前者可以对一个点使用父逆矩阵；后者必须保持完整线性变换。中心没有移动，不代表轮廓和所有顶点都没变。Unity 官方也指出父缩放与子旋转可能产生倾斜，三个分量的 lossyScale 不能完整表达这种情况：[Transform.lossyScale](https://docs.unity3d.com/6000.0/Documentation/ScriptReference/Transform-lossyScale.html)。此处是通用矩阵推导，不声称已对某个 UE/Unity 版本的挂接实现做本机测试。

边界与工程处理：

- 非零均匀缩放与普通旋转、平移组成的变换，可以保持在 TRS 表达范围内；非均匀缩放在轴对齐等特殊情况下也可能没有问题，并非每次重挂都会产生剪切。
- 新父存在零缩放时矩阵不可逆；任意世界变换不再保证可保持。接近零的尺度还会放大数值误差。
- 经常挂接/旋转的逻辑根节点尽量保持单位缩放，模型非均匀缩放放在独立 Visual 子节点，能减少耦合；这不是对任意既有层级的万能修复。
- 必须保留任意仿射变换时，需要支持完整矩阵/剪切，或在合适的资产流程中烘焙几何；不能只靠重新填写三个 scale 值。

与本课代码的边界：当前 local/world 使用完整 Matrix4，层级乘法能保留产生的剪切，没有再分解回 TRS。**但当前并未实现重新挂接 API、矩阵求逆或上述剪切反例的自动测试**；已有测试仅覆盖文末列出的四组。nodes 数组要求父先子后，未来重挂还需检查循环、维护顺序和索引引用，不能只改 parent 数字。此补充仍属于 C.4，不另拆课程。

## 实现

LoadCpuScene(path)同步ReadFile，只导入一次；复用CopyCpuMeshes复制定义，Visit按父先子后顺序保存所有节点并检查网格引用，UpdateWorldMatrices全量更新，返回时Importer析构。所有节点名、矩阵、索引和顶点均为自有值，失败抛异常，不返回半成品。递归时不持有vector元素引用，避免扩容后引用悬空。当前不声称可处理无限深恶意层级。

UpdateWorldMatrices要求parent=-1或parent<当前索引，错误索引与非有限矩阵报错。改local不会自动触发更新，必须显式调用；它只改world，不烘焙网格。更新未涉及GPU状态、Fence或BLAS重建。

本课四个mesh引用不强制等于四个TLAS实例：未来可为两个primitive分别建立BLAS，也可一个多geometry BLAS由Left/Right共享，具体在D阶段选择。渲染器通常缓存world并更新脏子树；本课全量更新便于检查，不把该策略称大场景最优方案。

## 拓扑与验证

TRIANGLES每三个索引一面；STRIP序列a,b,c,d给出(a,b,c)、(c,b,d)，第二面交换顺序保持绕序；FAN给出(a,b,c)、(a,c,d)，共享锚点a。交给Assimp转换，适配层检查每面确有三个索引。正方形的源顶点按逆时针0/1/2/3排列，strip输入0/1/3/2，fan输入0/1/2/3；输出各两个正绕序三角形，面积和1。

仓库根执行：

```powershell
& learning/sandbox/d3d12/gltf-scene/build_importer.ps1 -Lesson c04
& learning/sandbox/d3d12/gltf-scene/verify_hierarchy.ps1
```

results/c04保存自编变体与日志。TRS对独立标量参考最大误差4.76837e-7，matrix为0。修改Group局部X平移+10后，两子原点分别变(20,-3,0)/(20,5,0)，所有网格局部位置不变，mesh2/实例引用4保持不变。Strip/Fan面积及绕序通过。复用网格复制逻辑后C.3五组测试回归通过。无GPU成像，未导入相机投影/动画/材质资源，不称完整引擎场景系统。

自测：①上述父变换下，Left的局部点(1,0,0)世界位置是多少？②增加第三节点引用同一个双primitive mesh，网格定义与实例引用各多少？③为什么本课world=parentWorld*local，换行向量时顺序会改变？下一节C.5材质与纹理。
