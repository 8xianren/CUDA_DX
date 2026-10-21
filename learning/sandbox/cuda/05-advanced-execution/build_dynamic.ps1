# device 端启动 kernel 需要可重定位设备代码和设备运行时；普通 build.ps1 不替它隐式开启。
param([switch]$NoRun)
$ErrorActionPreference = 'Stop'
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
$vcvars = 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path -LiteralPath $vcvars)) { throw '未找到 VS2022 C++ 环境' }
$command = '"{0}" >nul && nvcc -arch=sm_120 -std=c++17 -Xcompiler /utf-8 -rdc=true "{1}\dynamic_parallelism.cu" -lcudadevrt -o "{1}\dynamic_parallelism.exe"' -f $vcvars,$PSScriptRoot
& cmd /c $command
if ($LASTEXITCODE -ne 0) { throw '动态并行编译失败' }
if (-not $NoRun) {
    & "$PSScriptRoot/dynamic_parallelism.exe"
    if ($LASTEXITCODE -ne 0) { throw '动态并行验证失败' }
}
