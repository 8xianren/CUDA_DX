# 本课既有设备模块（无 main），也有纯 Driver API 宿主；分别编译，保留可观察的 PTX。
param([switch]$NoRun)
$ErrorActionPreference = 'Stop'
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
$vcvars = 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path -LiteralPath $vcvars)) { throw '未找到 VS2022 C++ 环境' }
foreach ($mode in @('cubin','ptx')) {
    $command = '"{0}" >nul && nvcc -arch=sm_120 -std=c++17 -Xcompiler /utf-8 --{1} "{2}\asm_demo.cu" -o "{2}\asm_demo.{1}"' -f $vcvars,$mode,$PSScriptRoot
    & cmd /c $command
    if ($LASTEXITCODE -ne 0) { throw "asm_demo $mode 编译失败" }
}
$command = '"{0}" >nul && nvcc -arch=sm_120 -std=c++17 -Xcompiler /utf-8 --cubin "{1}\pred_demo.cu" -o "{1}\pred_demo.cubin"' -f $vcvars,$PSScriptRoot
& cmd /c $command
if ($LASTEXITCODE -ne 0) { throw 'pred_demo 编译失败' }
& "$PSScriptRoot/../../build.ps1" "$PSScriptRoot/driver_api.cpp" -Libraries cuda -NoRun
if ($LASTEXITCODE -ne 0) { throw 'Driver API 宿主编译失败' }
if (-not $NoRun) {
    & "$PSScriptRoot/driver_api.exe"
    if ($LASTEXITCODE -ne 0) { throw 'Driver API 验证失败' }
}
