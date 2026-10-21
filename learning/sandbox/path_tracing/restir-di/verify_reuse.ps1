$ErrorActionPreference='Stop'
$out=Join-Path $PSScriptRoot 'results/reuse'
New-Item -ItemType Directory -Force $out | Out-Null
$sandbox=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
& "$sandbox/build.ps1" "$PSScriptRoot/verify_reuse.cu" -NoRun 2>&1 | Tee-Object "$out/build.txt"
if($LASTEXITCODE -ne 0){throw 'reuse build failed'}
& "$PSScriptRoot/verify_reuse.exe" $out 2>&1 | Tee-Object "$out/run.txt"
if($LASTEXITCODE -ne 0){throw 'reuse verification failed'}
