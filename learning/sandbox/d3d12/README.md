# d3d12

小型网格渲染器。当前主程序是 `d3d12_mesh_input_layout.cu` / `.hlsl`。

HLSL 必须和 `.exe` 放在同一目录：程序按可执行文件目录加载 `d3d12_mesh_input_layout.hlsl`。

```powershell
cd ..
.\build.ps1 d3d12\d3d12_mesh_input_layout.cu -NoRun
.\d3d12\d3d12_mesh_input_layout.exe --frames 2 --no-vsync
```
