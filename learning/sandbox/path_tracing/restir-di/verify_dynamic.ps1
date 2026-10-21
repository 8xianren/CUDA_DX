$ErrorActionPreference='Stop'
$out=Join-Path $PSScriptRoot 'results/dynamic'
New-Item -ItemType Directory -Force $out | Out-Null
$sandbox=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
& "$sandbox/build.ps1" "$PSScriptRoot/verify_dynamic.cu" -NoRun 2>&1 | Tee-Object "$out/build.txt"
if($LASTEXITCODE -ne 0){throw 'dynamic reuse build failed'}
& "$PSScriptRoot/verify_dynamic.exe" $out 2>&1 | Tee-Object "$out/run.txt"
if($LASTEXITCODE -ne 0){throw 'dynamic reuse verification failed'}
