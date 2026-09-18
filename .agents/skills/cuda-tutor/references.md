# 参考资料入口（讲解时优先查证这里）

## NVIDIA 官方文档（首选权威来源）

- **编程指南**（本课程主参考，简称"编程指南 §x"）：https://docs.nvidia.com/cuda/cuda-programming-guide/index.html
  - §1 Introduction to CUDA / §1.3 The CUDA platform
  - §2 Programming GPUs in CUDA（2.1 C++、2.3 SIMT Kernels、2.4 Tile Kernels、2.5 Async、2.6 Unified/System Memory）
  - §3 Advanced CUDA（3.4 Multiple GPUs）
  - §4 CUDA Features（4.1 Unified Memory、4.2 CUDA Graphs、4.4 Cooperative Groups、4.19 Graphics Interop）
  - §5 Appendices（5.1 Compute Capabilities、5.3 C++ Support、5.7 Memory Model、5.8 Execution Model）
- **CUDA C++ Best Practices Guide**：https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/index.html
- **CUDA Runtime API**：https://docs.nvidia.com/cuda/cuda-runtime-api/index.html
- **Nsight Systems**：https://docs.nvidia.com/nsight-systems/ ｜ **Nsight Compute**：https://docs.nvidia.com/nsight-compute/
- **Thrust**：https://nvidia.github.io/cccl/thrust/ ｜ **CCCL（Thrust/CUB/libcudacxx）**：https://nvidia.github.io/cccl/
- **CuPy**：https://docs.cupy.dev/ ｜ **Numba CUDA**：https://numba.readthedocs.io/en/stable/cuda/index.html

查文档优先用编程指南；具体函数签名查 Runtime API；性能建议查 Best Practices Guide。

## D3D12 / HLSL 官方文档（Windows SDK）

- **Direct3D 12 编程指南**：https://learn.microsoft.com/en-us/windows/win32/direct3d12/directx-12-programming-guide
- **D3D12 API 参考**：https://learn.microsoft.com/en-us/windows/win32/api/d3d12/
- **D3D12 资源与堆**：https://learn.microsoft.com/en-us/windows/win32/direct3d12/memory-management
- **资源屏障与状态**：https://learn.microsoft.com/en-us/windows/win32/direct3d12/using-resource-barriers-to-synchronize-resource-states-in-direct3d-12
- **根签名**：https://learn.microsoft.com/en-us/windows/win32/direct3d12/root-signatures
- **描述符和描述符堆**：https://learn.microsoft.com/en-us/windows/win32/direct3d12/descriptor-heaps
- **命令队列与命令列表**：https://learn.microsoft.com/en-us/windows/win32/direct3d12/command-queues-and-command-lists
- **Fence 与多引擎同步**：https://learn.microsoft.com/en-us/windows/win32/direct3d12/user-mode-heap-synchronization
- **Swap Chain / DXGI**：https://learn.microsoft.com/en-us/windows/win32/direct3d12/swap-chains
- **Input Assembler**：https://learn.microsoft.com/en-us/windows/win32/direct3d12/input-assembler-stage
- **图形管线**：https://learn.microsoft.com/en-us/windows/win32/direct3d12/graphics-pipeline
- **D3D12 调试层**：https://learn.microsoft.com/en-us/windows/win32/direct3d12/using-the-debug-layer-to-test-apps
- **DRED（设备移除诊断）**：https://learn.microsoft.com/en-us/windows/win32/direct3d12/dred
- **DXR 光线追踪**：https://learn.microsoft.com/en-us/windows/win32/direct3d12/directx-raytracing
- **Mesh Shader**：https://learn.microsoft.com/en-us/windows/win32/direct3d12/mesh-shader
- **HLSL 文档**：https://learn.microsoft.com/en-us/windows/win32/direct3dhlsl/dx-graphics-hlsl

具体结构体声明以本机 Windows SDK 的 `d3d12.h` 为准；官方网页和 SDK 版本不一致时，要记录 SDK 版本与差异，不能猜测字段。

## 本仓库材料（用 Read 确认真实内容再引用）

- CUDA C++ 教程（核心）：`tutorials/cuda-cpp/notebooks/`（01.xx 算法、02.xx 异步/流、03.xx 内核）
- 各小节代码：对应目录下 `Sources/`（示例）与 `Solutions/`（练习答案）
- Tile 教程（需 Blackwell，本机不可运行）：`tutorials/cuda-tile/`
- 标准并行：`tutorials/stdpar/` ｜ 加速 Python：`tutorials/accelerated-python/`、`tutorials/nvmath-python/`
- Python 用户指南（12 章）：`Accelerated_Python_User_Guide/notebooks/`
- 视频课（CUDA C++）：https://www.youtube.com/playlist?list=PL5B692fm6--vWLhYPqLcEu6RF3hXjEyJr

## 本机环境约束（讲解/给命令时遵守）

- Windows + PowerShell；GPU = RTX 5070（Blackwell，`sm_120`，12GB）。
- 编译示例：`nvcc -arch=sm_120 xxx.cu -o xxx.exe`（务必 sm_120，勿用旧卡的 sm_86）。
- `nvcc` 可能未安装；首次编译前先按 `learning/README.md` 安装 CUDA Toolkit。
