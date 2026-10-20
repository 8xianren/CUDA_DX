# 纯 CPU C++ 第三方库使用 CMake/VS2022 构建，不需要 nvcc 或 GPU 架构参数。
# CUDA 教学程序仍使用 sandbox/build.ps1 和 sm_120。
param([ValidatePattern('^[cd][0-9]{2}$')][string]$Lesson = 'c02')
$ErrorActionPreference = 'Stop'
$logDir = Join-Path $PSScriptRoot "results/$Lesson"
New-Item -ItemType Directory -Force $logDir | Out-Null
& cmake -S $PSScriptRoot -B "$PSScriptRoot/build" -G 'Visual Studio 17 2022' -A x64 2>&1 | Tee-Object "$logDir/configure.txt"
if ($LASTEXITCODE -ne 0) { throw 'CMake configure failed' }
& cmake --build "$PSScriptRoot/build" --config Release --parallel 8 2>&1 | Tee-Object "$logDir/build.txt"
if ($LASTEXITCODE -ne 0) { throw 'CMake build failed' }
