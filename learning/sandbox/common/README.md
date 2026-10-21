# 单文件课程的公共辅助

`lesson_paths.h` 为旧单文件Windows课程提供 `lesson_paths::ResultDirectory()`：根据当前EXE绝对路径创建旁边的 `results/`，不依赖启动工作目录。

这是路径辅助，没有渲染设备、CUDA资源或游戏状态。CMake主线已有各自输出参数，不需要改用此接口。D3D12显示公共组件另见 [d3d12/common](../d3d12/common/README.md)。
