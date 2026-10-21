$ErrorActionPreference='Stop'
$out=Join-Path $PSScriptRoot 'results/rr';New-Item -ItemType Directory -Force $out | Out-Null
$shared=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../d3d12/gltf-scene'))
& cmake -S $shared -B "$shared/build" -G 'Visual Studio 17 2022' -A x64 2>&1 | Tee-Object "$out/configure.txt"
if($LASTEXITCODE -ne 0){throw 'configure failed'}
& cmake --build "$shared/build" --config Release --target gpu_rr_test import_scope_test --parallel 8 2>&1 | Tee-Object "$out/build.txt"
if($LASTEXITCODE -ne 0){throw 'build failed'}
& dxc -T lib_6_3 -HV 2021 -Fo "$out/path.dxil" "$PSScriptRoot/gpu_path.hlsl" 2>&1 | Tee-Object "$out/shader-build.txt"
if($LASTEXITCODE -ne 0){throw 'shader failed'}
& python "$PSScriptRoot/make_box.py"
if($LASTEXITCODE -ne 0){throw 'fixture failed'}
$fixture=Join-Path $PSScriptRoot 'results/gpu/box.gltf'
& node "$shared/validation/validate_import.cjs" $fixture "$out/validation.json" 2>&1 | Tee-Object "$out/validation.txt"
if($LASTEXITCODE -ne 0){throw 'validation failed'}
& "$PSScriptRoot/build/Release/gpu_rr_test.exe" $fixture "$out/path.dxil" $out 2>&1 | Tee-Object "$out/run.txt"
if($LASTEXITCODE -ne 0){throw 'GPU RR failed'}
