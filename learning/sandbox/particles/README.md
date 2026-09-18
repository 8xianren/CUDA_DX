# particles

CUDA↔D3D12 粒子与 External Memory / Fence。静态粒子 HLSL 是 `d3d12_static_particles.hlsl`，动态/双缓冲程序也从可执行文件目录加载它，所以 `.hlsl` 必须和对应 `.exe` 同目录。

```powershell
cd ..
.\build.ps1 particles\d3d12_static_particles.cu
```
