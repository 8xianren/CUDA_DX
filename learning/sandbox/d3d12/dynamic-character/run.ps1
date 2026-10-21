param([switch]$Build,[int]$VerificationFrames=0)
$ErrorActionPreference='Stop'
if($Build){& "$PSScriptRoot/build.ps1"}
$arguments=@()
# 正常运行与双击EXE共用旁边JSON；课程验收仍显式选择旧基线，避免重写历史证据。
if($VerificationFrames -gt 0){
    $pt=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../path_tracing/dxr-path-tracer'))
    $arguments=@("$PSScriptRoot/assets/runtime","$PSScriptRoot/build/shaders","$pt/results/pt08/energy-lut.bin","$PSScriptRoot/results/h7/interactive","$VerificationFrames")
}
& "$PSScriptRoot/build/Release/character_demo.exe" @arguments
if($LASTEXITCODE -ne 0){throw 'demo failed'}
