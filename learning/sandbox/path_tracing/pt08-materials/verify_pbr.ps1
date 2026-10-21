$ErrorActionPreference='Stop'
$out=Join-Path $PSScriptRoot 'results/pbr'
New-Item -ItemType Directory -Force $out | Out-Null
$shared=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../d3d12/gltf-scene'))
& cmake -S $shared -B "$shared/build" -G 'Visual Studio 17 2022' -A x64 2>&1 | Tee-Object "$out/configure.txt"
if($LASTEXITCODE -ne 0){throw 'configure failed'}
& cmake --build "$shared/build" --config Release --target pbr_test material_sampling_test --parallel 8 2>&1 | Tee-Object "$out/build.txt"
if($LASTEXITCODE -ne 0){throw 'PBR build failed'}
& dxc -T lib_6_3 -HV 2021 -Fo "$out/pbr.dxil" "$PSScriptRoot/pbr_test.hlsl" 2>&1 | Tee-Object "$out/shader-build.txt"
if($LASTEXITCODE -ne 0){throw 'PBR shader failed'}
& python "$PSScriptRoot/make_pbr.py"
if($LASTEXITCODE -ne 0){throw 'PBR fixture failed'}
& node "$shared/validation/validate_import.cjs" "$out/pbr.gltf" "$out/validation.json" 2>&1 | Tee-Object "$out/validation.txt"
if($LASTEXITCODE -ne 0){throw 'PBR glTF validation failed'}
& "$PSScriptRoot/build/Release/pbr_test.exe" "$out/pbr.gltf" "$out/pbr.dxil" $out 2>&1 | Tee-Object "$out/run.txt"
if($LASTEXITCODE -ne 0){throw 'PBR GPU sampling failed'}
