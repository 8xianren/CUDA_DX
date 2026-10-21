# 从任意工作目录调用；所有产物按脚本自身路径归入本课results/mirror。
$ErrorActionPreference='Stop'
$out=Join-Path $PSScriptRoot 'results/mirror';New-Item -ItemType Directory -Force $out | Out-Null
$shared=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../d3d12/gltf-scene'))
& cmake -S $shared -B "$shared/build" -G 'Visual Studio 17 2022' -A x64 2>&1 | Tee-Object "$out/configure.txt"
if($LASTEXITCODE -ne 0){throw 'configure failed'}
& cmake --build "$shared/build" --config Release --target mirror_test import_scope_test --parallel 8 2>&1 | Tee-Object "$out/build.txt"
if($LASTEXITCODE -ne 0){throw 'build failed'}
& dxc -T lib_6_3 -HV 2021 -Fo "$out/mirror.dxil" "$PSScriptRoot/mirror.hlsl" 2>&1 | Tee-Object "$out/shader-build.txt"
if($LASTEXITCODE -ne 0){throw 'shader failed'}
& python "$PSScriptRoot/make_mirror.py"
if($LASTEXITCODE -ne 0){throw 'fixture failed'}
& node "$shared/validation/validate_import.cjs" "$out/mirror.gltf" "$out/validation.json" 2>&1 | Tee-Object "$out/validation.txt"
if($LASTEXITCODE -ne 0){throw 'validation failed'}
& "$PSScriptRoot/build/Release/mirror_test.exe" "$out/mirror.gltf" "$out/mirror.dxil" $out 2>&1 | Tee-Object "$out/run.txt"
if($LASTEXITCODE -ne 0){throw 'mirror GPU failed'}
