param([switch]$SkipBuild)
$ErrorActionPreference='Stop'
if(!$SkipBuild){& "$PSScriptRoot/build.ps1"}
$pt=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../path_tracing/dxr-path-tracer'))
$out=Join-Path $PSScriptRoot 'results/h6'
New-Item -ItemType Directory -Force $out | Out-Null
& "$PSScriptRoot/build/Release/h_temporal_test.exe" "$PSScriptRoot/assets/runtime" "$PSScriptRoot/build/shaders" "$pt/results/pt08/energy-lut.bin" $out 2>&1 | Tee-Object "$out/run.txt"
if($LASTEXITCODE -ne 0){throw 'H6 verification failed'}
