param([switch]$SkipBuild)
$ErrorActionPreference='Stop'
if(!$SkipBuild){& "$PSScriptRoot/build.ps1"}
$pt=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../path_tracing/dxr-path-tracer'))
$out=Join-Path $PSScriptRoot 'results/h7'
New-Item -ItemType Directory -Force $out | Out-Null
& "$PSScriptRoot/run.ps1" -VerificationFrames 300 2>&1 | Tee-Object "$out/window.txt"
& "$PSScriptRoot/build/Release/h_performance_test.exe" "$PSScriptRoot/assets/runtime" "$PSScriptRoot/build/shaders" "$pt/results/pt08/energy-lut.bin" $out 2>&1 | Tee-Object "$out/performance-run.txt"
if($LASTEXITCODE -ne 0){throw 'H7 performance run failed'}
python "$PSScriptRoot/audit_course.py"
if($LASTEXITCODE -ne 0){throw 'H chapter audit failed'}
