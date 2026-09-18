# sandbox 分类

`build.ps1` 仍放在本目录。编译时把源文件写成子目录相对路径，可执行文件会生成在源文件旁边。

```powershell
.\build.ps1 cuda\hello.cu
.\build.ps1 d3d12\d3d12_mesh_input_layout.cu -NoRun
.\build.ps1 particles\d3d12_static_particles.cu
.\build.ps1 path_tracing\pt1_radiometry.cu
```

| 目录 | 内容 |
|---|---|
| `cuda/` | CUDA 基础、性能、库、sanitizer、Python 探针 |
| `d3d12/` | 小型网格渲染器：窗口清除、VB/IB、材质、实例化 |
| `particles/` | CUDA↔D3D12 粒子、External Memory/Fence、Nsight 记录 |
| `path_tracing/` | 路径追踪验收程序（PT.1 起） |
