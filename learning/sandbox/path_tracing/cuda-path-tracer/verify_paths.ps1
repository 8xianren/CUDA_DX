$ErrorActionPreference='Stop'
$out=Join-Path $PSScriptRoot 'results/megakernel'
New-Item -ItemType Directory -Force $out | Out-Null
$sandbox=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
& "$sandbox/build.ps1" "$PSScriptRoot/path_verify.cu" -NoRun 2>&1 | Tee-Object "$out/build.txt"
if($LASTEXITCODE -ne 0){throw 'path CUDA build failed'}
& "$PSScriptRoot/path_verify.exe" "$PSScriptRoot/results/bvh/gallery.meshbin" $out full 2>&1 | Tee-Object "$out/run.txt"
if($LASTEXITCODE -ne 0){throw 'path verification failed'}
& compute-sanitizer --tool memcheck --leak-check full --error-exitcode 1 "$PSScriptRoot/path_verify.exe" "$PSScriptRoot/results/bvh/gallery.meshbin" "$out/sanitizer" quick 2>&1 | Tee-Object "$out/memcheck.txt"
if($LASTEXITCODE -ne 0){throw 'path sanitizer failed'}
