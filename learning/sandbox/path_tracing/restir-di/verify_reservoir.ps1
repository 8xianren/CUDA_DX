$ErrorActionPreference='Stop'
$out=Join-Path $PSScriptRoot 'results/reservoir'
New-Item -ItemType Directory -Force $out | Out-Null
$sandbox=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
# 沿用课程sm_120构建入口；本小节只运行宿主CPU概率实验，没有GPU kernel。
& "$sandbox/build.ps1" "$PSScriptRoot/verify_reservoir.cu" -NoRun 2>&1 | Tee-Object "$out/build.txt"
if($LASTEXITCODE -ne 0){throw 'reservoir build failed'}
& "$PSScriptRoot/verify_reservoir.exe" $out 2>&1 | Tee-Object "$out/run.txt"
if($LASTEXITCODE -ne 0){throw 'reservoir verification failed'}
