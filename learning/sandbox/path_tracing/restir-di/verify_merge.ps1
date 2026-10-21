$ErrorActionPreference='Stop'
$out=Join-Path $PSScriptRoot 'results/merge'
New-Item -ItemType Directory -Force $out | Out-Null
$sandbox=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
& "$sandbox/build.ps1" "$PSScriptRoot/verify_merge.cu" -NoRun 2>&1 | Tee-Object "$out/build.txt"
if($LASTEXITCODE -ne 0){throw 'merge build failed'}
& "$PSScriptRoot/verify_merge.exe" $out 2>&1 | Tee-Object "$out/run.txt"
if($LASTEXITCODE -ne 0){throw 'merge verification failed'}
# 共享reservoir.h新增Merge后回归原始候选Update/Normalization。
& "$PSScriptRoot/verify_reservoir.ps1"
if($LASTEXITCODE -ne 0){throw 'original reservoir regression failed'}
