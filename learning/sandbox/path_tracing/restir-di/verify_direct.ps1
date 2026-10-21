$ErrorActionPreference='Stop'
$out=Join-Path $PSScriptRoot 'results/direct'
New-Item -ItemType Directory -Force $out | Out-Null
$sandbox=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
& "$sandbox/build.ps1" "$PSScriptRoot/verify_direct.cu" -NoRun 2>&1 | Tee-Object "$out/build.txt"
if($LASTEXITCODE -ne 0){throw 'direct lighting build failed'}
& "$PSScriptRoot/verify_direct.exe" $out 2>&1 | Tee-Object "$out/run.txt"
if($LASTEXITCODE -ne 0){throw 'direct lighting verification failed'}
