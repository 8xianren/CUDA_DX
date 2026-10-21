$ErrorActionPreference='Stop'
$out=Join-Path $PSScriptRoot 'results/wavefront'
New-Item -ItemType Directory -Force $out | Out-Null
$sandbox=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
& "$sandbox/build.ps1" "$PSScriptRoot/wavefront_verify.cu" -NoRun 2>&1 | Tee-Object "$out/build.txt"
if($LASTEXITCODE -ne 0){throw 'Wavefront build failed'}
& "$PSScriptRoot/wavefront_verify.exe" "$PSScriptRoot/results/bvh/gallery.meshbin" $out full 2>&1 | Tee-Object "$out/run.txt"
if($LASTEXITCODE -ne 0){throw 'Wavefront full verification failed'}
& compute-sanitizer --tool memcheck --leak-check full --error-exitcode 1 "$PSScriptRoot/wavefront_verify.exe" "$PSScriptRoot/results/bvh/gallery.meshbin" "$out/sanitizer" quick 2>&1 | Tee-Object "$out/memcheck.txt"
if($LASTEXITCODE -ne 0){throw 'Wavefront memcheck failed'}
& compute-sanitizer --tool synccheck --error-exitcode 1 "$PSScriptRoot/wavefront_verify.exe" "$PSScriptRoot/results/bvh/gallery.meshbin" "$out/synccheck" quick 2>&1 | Tee-Object "$out/synccheck.txt"
if($LASTEXITCODE -ne 0){throw 'Wavefront synccheck failed'}
