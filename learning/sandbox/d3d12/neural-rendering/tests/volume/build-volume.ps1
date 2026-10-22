param([switch]$NoRun)
$ErrorActionPreference='Stop'
$course=(Resolve-Path "$PSScriptRoot/../..").Path
$output=Join-Path $course 'build/volume'
New-Item -ItemType Directory -Force $output | Out-Null
$vcvars='C:/Program Files/Microsoft Visual Studio/2022/Community/VC/Auxiliary/Build/vcvars64.bat'
# 复用仓库build.ps1的VS初始化、UTF-8与sm_120约定；此课有三个翻译单元，所以单独显式链接。
$command='"{0}" >nul && nvcc -arch=sm_120 -std=c++17 -lineinfo -Xcompiler /utf-8 -Xcompiler /Zc:preprocessor "{1}/src/volume/volume.cu" "{1}/src/volume/volume_cpu.cpp" "{1}/tests/volume/volume_validate.cu" -o "{2}/volume_validate.exe"' -f $vcvars,$course,$output
cmd /c $command
if($LASTEXITCODE -ne 0){throw 'volume build failed'}
if(!$NoRun){
    & "$output/volume_validate.exe" "$course/results"
    if($LASTEXITCODE -ne 0){throw 'volume validation failed'}
}
