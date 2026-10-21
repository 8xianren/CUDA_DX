# H.3：世界运动决定状态，动画表达状态

2026-10-21。[代码目录](../../sandbox/d3d12/dynamic-character/README.md)。核心实现 `src/simulation/character_controller.cpp`，映射在 `src/app/locomotion_mapping.h`。

## 概念与类比

人物控制器回答“在哪里、速度多少、是否接地”；动画播放器回答“这个状态怎样表现”。像游戏中播放受击动作不会自动产生可靠碰撞一样，Jump_Land 播完不能作为落地的物理判据。我们用简单水平面接触验证整条链，不把装饰树石称作碰撞体。

## 从运动方程推出更新

假设一个固定步内重力恒定、水平速度由意图给定，y轴向上。dv/dt=-g，积分得到 v1=v0-gΔt；再积分位置得到 y1=y0+v0Δt-½gΔt²。这里必须用更新前的v0；先更新速度再直接 y+=v1Δt 会多算半步重力位移。

固定步 Δt=1/120秒。渲染帧积累 elapsed，每满一个固定步执行一次 Step，剩余时间留到下帧。30/60/144Hz只是同一批仿真步的不同分组。真实窗口卡顿时应用把一次elapsed限到0.25秒，极端卡顿会丢弃时间；这是教学防止长时间补步的策略，不是严格实时钟或网络确定性承诺。

## 接口、顺序、失败路径

`void CharacterController::Step(const CharacterIntent&)` 每次只执行一个配置固定步。意图包含水平x/z、run、jumpPressed，方向长度大于1时归一化。walk=1.5、run=3.5世界单位/秒，起跳速度4.5，g=9.81。非有限意图或非法配置拒绝执行。控制器持有自己的状态，没有 HWND、Assimp 或 GPU 指针。

接地且不在落地缓冲时消费起跳边沿；向上阶段Jump，v_y≤0转Fall；向下越过ground时把y夹到平面、速度归零、grounded=true、转Land；0.15秒后按水平意图进入Idle/Walk/Run。先更新仿真，再按最终状态选择动作。Land期间水平运动仍有效，当前没有脚步锁定。

`unsigned FixedClock::Advance(double elapsed, const std::function<void(uint64_t)>& callback)` 接收秒数，callback每个固定步调用一次，参数为时钟步号，返回执行步数。非有限、负数或大于1秒的输入报错。暂停由App停止Advance；单步直接调用一次控制器，因此App的角色tick才是场景版本，不能误用独立时钟tick作为暂停后的权威状态。

自动行为与未来玩家行为都可以产出CharacterIntent。目前默认每8秒换向：待机、步行、奔跑、起跳、恢复步行、待机；玩家WASD仍用于相机。角色会走离起始视野，允许自由相机跟随，未实现自动跟拍。

## 动手与实测

根目录运行 `& learning/sandbox/d3d12/dynamic-character/verify_h3_h4.ps1`。16秒在30/60/144Hz分组下均为1920步、最终状态一致；六状态全部覆盖，抛物线最大误差1.93881e-6，落地步号符合解析飞行时间向上取整。结果 `results/h3/summary.json`。

商业角色控制器还会做扫掠碰撞、台阶、斜坡、根运动、网络修正；本课只做平面，但意图→状态→动画的依赖方向可保留。自测答案：提高渲染帧率不应提高移动速度；只按落地动画长度判断接触会导致悬空或穿地；起跳边沿补步时只能消费一次。下一节把窗口消息变成意图。
