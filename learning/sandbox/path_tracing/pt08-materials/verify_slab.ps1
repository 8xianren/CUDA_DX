$ErrorActionPreference='Stop'
# 从脚本路径定位目录；不依赖当前PowerShell工作目录。所有结果直接进入本课results/slab。
$out=Join-Path $PSScriptRoot 'results/slab'
New-Item -ItemType Directory -Force $out | Out-Null
$shared=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../d3d12/gltf-scene'))
& cmake -S $shared -B "$shared/build" -G 'Visual Studio 17 2022' -A x64 2>&1 | Tee-Object "$out/configure.txt"
if($LASTEXITCODE -ne 0){throw 'configure failed'}
& cmake --build "$shared/build" --config Release --target slab_test --parallel 8 2>&1 | Tee-Object "$out/build.txt"
if($LASTEXITCODE -ne 0){throw 'build failed'}
& dxc -T lib_6_3 -HV 2021 -Fo "$out/slab.dxil" "$PSScriptRoot/slab.hlsl" 2>&1 | Tee-Object "$out/shader-build.txt"
if($LASTEXITCODE -ne 0){throw 'shader failed'}
& python "$PSScriptRoot/make_slab.py"
if($LASTEXITCODE -ne 0){throw 'fixture failed'}
& node "$shared/validation/validate_import.cjs" "$out/slab.gltf" "$out/validation.json" 2>&1 | Tee-Object "$out/validation.txt"
if($LASTEXITCODE -ne 0){throw 'validation failed'}
& "$PSScriptRoot/build/Release/slab_test.exe" "$out/slab.gltf" "$out/slab.dxil" $out 2>&1 | Tee-Object "$out/run.txt"
if($LASTEXITCODE -ne 0){throw 'slab GPU failed'}
