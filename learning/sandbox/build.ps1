# 一键编译并运行 CUDA 程序（Windows + RTX 5070 / Blackwell / sm_120）
# 用法： .\build.ps1 cuda\00-01-foundations\hello.cu
#        .\build.ps1 path_tracing\pt01-radiometry\pt1_radiometry.cu
#        .\build.ps1 d3d12\r01-r08-mesh\d3d12_mesh_input_layout.cu -NoRun
param(
    [Parameter(Mandatory = $true)] [string]$Source,
    [string]$Arch = "sm_120",
    [string[]]$Libraries = @(),
    [switch]$NoRun
)

$ErrorActionPreference = "Stop"

# 1) 确保 nvcc 在 PATH（从注册表读取机器级/用户级 PATH，免去重开终端）
$machine = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
$user    = [System.Environment]::GetEnvironmentVariable("Path", "User")
$env:Path = "$machine;$user"

# 2) 定位 Visual Studio 的 vcvars64.bat（提供 cl.exe / INCLUDE / LIB）
$vcvars = "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $vcvars)) { throw "找不到 vcvars64.bat，请确认已安装 VS2022 的 C++ 工具" }

$exe = [System.IO.Path]::ChangeExtension($Source, "exe")
$linkArgs = ($Libraries | ForEach-Object { "-l$_" }) -join " "

# 3) 在已加载 MSVC 环境的 cmd 子进程里调用 nvcc
#    /utf-8        : 消除中文环境下的 C4819 代码页警告
#    /Zc:preprocessor : Thrust/CCCL 要求 MSVC 使用标准预处理器
#    --extended-lambda: 允许在 thrust/cub 里用 __host__ __device__ lambda
$cmd = "`"$vcvars`" >nul && nvcc -arch=$Arch -std=c++17 --extended-lambda -Xcompiler /utf-8 -Xcompiler /Zc:preprocessor `"$Source`" $linkArgs -o `"$exe`""
if (-not $NoRun) { $cmd += " && echo ===== RUN ===== && `"$exe`"" }

cmd /c $cmd
