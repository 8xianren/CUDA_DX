$ErrorActionPreference='Stop'
# 复用共享D3D12/DXR后端；脚本从任意工作目录定位本课结果。
$out=Join-Path $PSScriptRoot 'results/glass';New-Item -ItemType Directory -Force $out | Out-Null
$shared=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../d3d12/gltf-scene'))
& cmake -S $shared -B "$shared/build" -G 'Visual Studio 17 2022' -A x64 2>&1 | Tee-Object "$out/configure.txt"
if($LASTEXITCODE -ne 0){throw 'configure failed'}
& cmake --build "$shared/build" --config Release --target glass_test import_scope_test --parallel 8 2>&1 | Tee-Object "$out/build.txt"
if($LASTEXITCODE -ne 0){throw 'build failed'}
& dxc -T lib_6_3 -HV 2021 -Fo "$out/glass.dxil" "$PSScriptRoot/glass.hlsl" 2>&1 | Tee-Object "$out/shader-build.txt"
if($LASTEXITCODE -ne 0){throw 'shader failed'}
& python "$PSScriptRoot/make_glass.py"
if($LASTEXITCODE -ne 0){throw 'fixture failed'}
& node "$shared/validation/validate_import.cjs" "$out/glass.gltf" "$out/validation.json" 2>&1 | Tee-Object "$out/validation.txt"
if($LASTEXITCODE -ne 0){throw 'validation failed'}
& "$PSScriptRoot/build/Release/glass_test.exe" "$out/glass.gltf" "$out/glass.dxil" $out 2>&1 | Tee-Object "$out/run.txt"
if($LASTEXITCODE -ne 0){throw 'glass GPU failed'}
