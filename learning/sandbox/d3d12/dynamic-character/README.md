# H1–H7 动态角色路径追踪共享主线

用户于 2026-10-21 授权连续学习与工程实施至 H7。本次教学范围已实现并通过分模块数值检查、300帧真实窗口验收和RTX5070离屏计时。完整证据见 `results/h7/summary.json`，具体限制见H5–H7讲义。

架构约束与帧数据流见 [ARCHITECTURE.md](ARCHITECTURE.md)。用户明确要求按模块化小型渲染器整合；课节编号组织验收，代码按资产、动画、仿真、输入、渲染与应用职责组织。

采用 Quaternius UAL1 Standard 包自带 Mannequin 作为首版人物，65 关节、43 动作、13744 三角形；Base Characters 候选的骨骼局部变换不同，保留为后续重定向候选。环境取 Kenney Nature Kit 的少量模型。资产来源、实际成员路径、哈希见 [manifest](assets/manifest.json)，许可见 `assets/licenses/`。

| 文件 | 职责 |
|---|---|
| fetch_assets.ps1 / prepare_assets.py | 获取作者免费包、检查归档路径、选资源、精确修复两处候选人物纹理 URI 文件名并归档哈希 |
| tests/asset_probe.cpp | 固定版本 Assimp 结构/权重/绑定/动画时间探针，人物与动画骨架差异报告 |
| src/core/math.h | 项目自有向量/四元数/矩阵，明确列向量与行存储约定 |
| src/assets/character_import.cpp | 唯一依赖Assimp的角色导入适配器，深拷贝为项目类型 |
| src/animation/ | CPU姿势采样、混合、骨骼层级和蒙皮参考，不依赖GPU/输入/导入库 |
| src/render/cuda/ | GPU蒙皮执行及显存所有权 |
| tests/animation_test.cpp / audit_animation.py | CUDA与CPU对照，以及原始glTF独立采样/重排/蒙皮参考 |
| audit_gltf.py | 独立原始 accessor/绑定方程参考与漏逆绑定负对照，不是完整 glTF Validator |
| verify_h1.ps1 | 构建、实际资产、独立参考、失败路径及静态导入回归 |
| src/input/ / src/simulation/ | 窗口输入适配、动作映射、固定步角色控制器和自由相机 |
| src/render/dxr/ / shaders/ | 动态BLAS/TLAS、PT积分复用、变形重投影和有界历史滤波 |
| src/app/ | 资产组装、运动到动作映射、场景快照提取、主循环 |
| tests/ / verify_h*.ps1 / audit_course.py | 分模块验收、完整窗口轨迹和性能证据汇总 |

## 日常启动：直接双击 EXE

打开 `build/Release/character_demo.exe` 即可运行，无需终端、PowerShell 或命令行参数。
程序自动读取旁边的 `character_demo.json`；`assets`、`shaders`、`energy_lut`、`output` 都可以改成相对路径，**相对 JSON 所在目录解析**，不依赖启动时的工作目录。`render.width` / `render.height` 是内部渲染分辨率（16–4096），默认 1280×720。修改后重新启动生效。

默认配置模板在 `config/character_demo.json`。构建首次部署配置，后续编译保留用户已经编辑的版本；同时把 `cudart64_13.dll` 放到 EXE 旁，运行时无需 CUDA 的 PATH。无参数启动出错时弹出错误框，并尽力保存到 EXE 旁的 `startup-error.txt`。

CMD 也可以直接运行 EXE；以下命令从仓库根目录执行：

```cmd
learning\sandbox\d3d12\dynamic-character\build\Release\character_demo.exe
```

原先四个路径参数及可选验收帧数仍兼容；也支持 `--config file.json` 和 `--verify-frames 24`。
启动专项验收：`python learning\sandbox\d3d12\dynamic-character\verify_startup.py`，结果独立保存在 `results/startup/`。

## 开发构建与课程验收

下面为已有 PowerShell 开发脚本，日常启动不需要执行它们（Python 数值参考需 NumPy）：

```powershell
& learning/sandbox/d3d12/dynamic-character/fetch_assets.ps1
& learning/sandbox/d3d12/dynamic-character/verify_h1.ps1
& learning/sandbox/d3d12/dynamic-character/verify_h2.ps1
& learning/sandbox/d3d12/dynamic-character/verify_h3_h4.ps1
& learning/sandbox/d3d12/dynamic-character/build.ps1
& learning/sandbox/d3d12/dynamic-character/verify_h5.ps1
& learning/sandbox/d3d12/dynamic-character/verify_h6.ps1 -SkipBuild
& learning/sandbox/d3d12/dynamic-character/verify_h7.ps1 -SkipBuild
# 正常交互；窗口持续运行，Esc退出。
& learning/sandbox/d3d12/dynamic-character/run.ps1
```

复用 `../gltf-scene` 的 CMake 工程与固定 Assimp 版本；`H_CHARACTER=ON` 开启本课目标。需要VS2022 C++、CMake、CUDA13.3（sm_120）、DXC和Python NumPy；图像预览转换可选Pillow。产物放 `build/Release`，shader在 `build/shaders`。完整build会在缺失时生成共享PT能量表。资产缓存和运行素材由脚本恢复，不上传Git；来源站点可用性/免费版本变动可能影响重新获取，保留清单和原始归档。结果写入 `results/h1` 至 `results/h7`，不依赖进程启动目录。

控制：WASD平移相机，Q/E升降，Shift加速，右键拖动转向；Space暂停人物并累积，N暂停时单步，R恢复相机并重置历史，Esc退出。人物按自动意图往返并跳跃，WASD首版不直接控制人物；接口允许后续接入玩家CharacterIntent。展示模式采用半径2.5m的圆周路线，保留走/跑/跳时序；旧验收场景仍沿原15m路线。

窗口现默认1280×720内部渲染、运动4 spp/6次散射，暂停每帧16 spp。JSON可配置moving_spp、paused_spp、max_scatters、presentation和sky_intensity；1080p将width/height改为1920/1080后重启。旧四路径验收保留320×180黑环境基线；新增展示性能覆盖720p/1080p。不要混用窗口帧耗时和不含Present的离屏数值。H2动画查看集成在同一最终窗口，通过Space/N检查姿势，没有另复制一套查看器。

讲义：[H1 资产与绑定空间](../../../笔记/d3d12/H.1-资产体检与绑定空间.md)。完整范围见[实施计划](../../../H阶段-动态角色路径追踪Demo实施计划.md)。

- [H2 姿势与CUDA蒙皮](../../../笔记/d3d12/H.2-姿势采样混合与CUDA蒙皮.md)
- [H3 固定步与状态机](../../../笔记/d3d12/H.3-固定步长与角色状态机.md)
- [H4 输入与自由相机](../../../笔记/d3d12/H.4-输入快照与自由相机.md)
- [H5 动态DXR与边界](../../../笔记/d3d12/H.5-动态DXR与模块边界.md)
- [H6 变形重投影](../../../笔记/d3d12/H.6-变形重投影与有界时域滤波.md)
- [H7 整合和性能](../../../笔记/d3d12/H.7-整合验收与性能边界.md)

## 画质修正（2026-10-21）

默认展示已增加参与反射/间接照明的程序天空和太阳、平滑法线、更近相机与树石布景；初始客户区匹配内部尺寸。天空是程序近似，不是HDRI或物理大气；当前素材仍为低多边形风格。窗口resize不自动提高内部尺寸。

`& learning/sandbox/d3d12/dynamic-character/verify_visual.ps1`生成720p静态256spp与奔跑/起跳4spp对照、天空数值验收与720p/1080p计时（PNG转换需Pillow）。结果在results/visual，详细证据和范围见[画质修正讲义](../../../笔记/d3d12/H.7-画质修正与程序天空.md)。旧H章数值结果保留，不用新场景覆盖。
