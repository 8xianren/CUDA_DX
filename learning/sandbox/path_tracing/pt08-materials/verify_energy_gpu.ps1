$ErrorActionPreference='Stop'
$out=Join-Path $PSScriptRoot 'results/energy-gpu'
$negative=Join-Path $out 'negative-baseline'
New-Item -ItemType Directory -Force $out,$negative | Out-Null
$shared=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../d3d12/gltf-scene'))
& cmake -S $shared -B "$shared/build" -G 'Visual Studio 17 2022' -A x64 2>&1 | Tee-Object "$out/configure.txt"
if($LASTEXITCODE -ne 0){throw 'configure failed'}
& cmake --build "$shared/build" --config Release --target energy_lut_build pbr_test material_sampling_test scene_boundary_test --parallel 8 2>&1 | Tee-Object "$out/build.txt"
if($LASTEXITCODE -ne 0){throw 'energy GPU targets failed'}
& "$PSScriptRoot/build/Release/energy_lut_build.exe" $out 2>&1 | Tee-Object "$out/lut-run.txt"
if($LASTEXITCODE -ne 0){throw 'energy LUT reference failed'}
& python "$PSScriptRoot/make_pbr.py" $out
if($LASTEXITCODE -ne 0){throw 'fixture failed'}
& node "$shared/validation/validate_import.cjs" "$out/pbr.gltf" "$out/validation.json" 2>&1 | Tee-Object "$out/validation.txt"
if($LASTEXITCODE -ne 0){throw 'glTF validation failed'}
& dxc -T lib_6_3 -HV 2021 -D PBR_ENERGY_BALANCED=1 -Fo "$out/pbr.dxil" "$PSScriptRoot/pbr_test.hlsl" 2>&1 | Tee-Object "$out/shader-build.txt"
if($LASTEXITCODE -ne 0){throw 'balanced shader failed'}
& dxc -T lib_6_3 -HV 2021 -Fo "$negative/pbr.dxil" "$PSScriptRoot/pbr_test.hlsl" 2>&1 | Tee-Object "$negative/shader-build.txt"
if($LASTEXITCODE -ne 0){throw 'baseline shader failed'}
& "$PSScriptRoot/build/Release/pbr_test.exe" "$out/pbr.gltf" "$out/pbr.dxil" $out "$out/energy-lut.bin" 2>&1 | Tee-Object "$out/run.txt"
if($LASTEXITCODE -ne 0){throw 'balanced GPU validation failed'}
& "$PSScriptRoot/build/Release/pbr_test.exe" "$out/pbr.gltf" "$negative/pbr.dxil" $negative 2>&1 | Tee-Object "$negative/run.txt"
if($LASTEXITCODE -ne 0){throw 'baseline negative control failed'}
# 根签名增加t7后，重跑真正受影响的D.3/D.4共享后端，不以只编译代替兼容性验证。
& "$shared/verify_sampling.ps1" 2>&1 | Tee-Object "$out/d03-regression.txt"
if($LASTEXITCODE -ne 0){throw 'D.3 regression failed'}
& "$shared/build/Release/scene_boundary_test.exe" "$shared/results/d03/material_rays.dxil" 2>&1 | Tee-Object "$out/d04-regression.txt"
if($LASTEXITCODE -ne 0){throw 'D.4 regression failed'}
