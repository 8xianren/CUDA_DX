$ErrorActionPreference='Stop'
$out=Join-Path $PSScriptRoot 'results/bvh'
New-Item -ItemType Directory -Force $out | Out-Null
$shared=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../d3d12/gltf-scene'))
$sandbox=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
& cmake -S $shared -B "$shared/build" -G 'Visual Studio 17 2022' -A x64 2>&1 | Tee-Object "$out/configure.txt"
if($LASTEXITCODE -ne 0){throw 'export configure failed'}
& cmake --build "$shared/build" --config Release --target cuda_scene_export --parallel 8 2>&1 | Tee-Object "$out/export-build.txt"
if($LASTEXITCODE -ne 0){throw 'export build failed'}
& "$PSScriptRoot/build/Release/cuda_scene_export.exe" "$PSScriptRoot/../dxr-path-tracer/results/pt08/gallery.gltf" "$out/gallery.meshbin" 2>&1 | Tee-Object "$out/export.txt"
if($LASTEXITCODE -ne 0){throw 'scene export failed'}
& "$sandbox/build.ps1" "$PSScriptRoot/bvh_verify.cu" -NoRun 2>&1 | Tee-Object "$out/build.txt"
if($LASTEXITCODE -ne 0){throw 'BVH CUDA build failed'}
& "$PSScriptRoot/bvh_verify.exe" "$out/gallery.meshbin" $out full 2>&1 | Tee-Object "$out/run.txt"
if($LASTEXITCODE -ne 0){throw 'BVH verification failed'}
& compute-sanitizer --tool memcheck --leak-check full --error-exitcode 1 "$PSScriptRoot/bvh_verify.exe" "$out/gallery.meshbin" "$out/sanitizer" quick 2>&1 | Tee-Object "$out/memcheck.txt"
if($LASTEXITCODE -ne 0){throw 'BVH sanitizer failed'}
