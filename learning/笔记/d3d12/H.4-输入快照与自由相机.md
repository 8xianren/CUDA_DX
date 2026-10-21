# H.4：输入是意图的来源

2026-10-21。[共享工程](../../sandbox/d3d12/dynamic-character/README.md)。实现 `src/input/window_input.cpp`、`actions.h` 和 `src/simulation/free_camera.h`。

## 概念、类比与推导

按键像控制台上的开关，不能直接焊到渲染器内部。平台层识别窗口消息，映射层解释操作含义，相机模型只处理向前/向右/转向这样的量。这样回放、手柄与键盘可以提供同一种CameraIntent。

键盘保持量没有时间维度：速度v乘Δt才得到位移。鼠标传来的是已经在该帧累计的像素位移Δx，角度变化是灵敏度乘Δx，不能再乘Δt，否则相同鼠标轨迹会随帧率改变视角。相机水平前向由yaw构造，垂直移动独立；斜向向量超过单位长度时归一化，避免W+D更快。

## 数据与生命周期

`InputSnapshot` 保存 held/pressed 布尔数组、mouseX/Y、focused/looking。`Actions MapActions(const InputSnapshot&)` 返回CameraIntent及AppCommands；没有角色/GPU指针。自动重复KEYDOWN不会再次产生pressed。`WindowInput::Consume()` 返回本帧快照并消费边沿和鼠标增量，held持续到KEYUP或失焦。

窗口适配器以SetWindowSubclass附加消息处理，右键捕获拖动，失焦释放捕获并清空保持键。HWND只是借用，WindowInput不销毁窗口。App先构造renderer再构造input，逆序析构时先解除子类化，窗口才被渲染后端的显示对象销毁。非窗口业务库不包含Windows消息码。

`void FreeCamera::Update(const CameraIntent&, double elapsed)` 以秒推进平移，非法elapsed拒绝。初始eye=(6,5,9)，朝向(0,1,0)；pitch夹到±1.5弧度，防止极点退化。普通速度3、Shift速度8，鼠标灵敏度0.003弧度/像素。R重置相机并让App请求历史重置；曝光调整理论上只影响显示，不应该重置线性辐射历史。

操作：WASD水平移动，Q/E升降，鼠标右键拖动转向，Shift加速；Space暂停/恢复人物，N在暂停时推进一个固定步，R重置相机，Esc退出。暂停时相机仍工作。

## 验证与边界

`verify_h3_h4.ps1` 使用真实隐藏窗口消息，验证重复按下、保持、释放、焦点及捕获语义；30/60/144Hz相机位移误差3.2652e-5。H7真实显示窗口再执行暂停/单步、resize、最小化与恢复、按住W后失焦，共300帧通过。

这里用窗口消息位移，没有Raw Input、游戏手柄、可配置绑定或多窗口路由。商业引擎通常有独立平台窗口服务和增强输入系统；本课保留小适配器。当前窗口生命周期仍由renderer中的显示对象管理，公共头只通过借用句柄接App；以后多窗口时可再独立平台宿主，不影响仿真/动画接口。

自测答案：held用于连续移动，pressed用于暂停等一次性操作；失焦必须清键，否则人物/相机会持续移动；鼠标位移不重复乘dt。下一节把独立模块输出提交到DXR。
