$ErrorActionPreference='Stop'
$out=Join-Path $PSScriptRoot 'results/pt10-history'
New-Item -ItemType Directory -Force $out | Out-Null
$shared=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../d3d12/gltf-scene'))
$inputData=Join-Path $PSScriptRoot 'results/pt08'
foreach($file in @('gallery.gltf','gallery.bin','energy-lut.bin')){
    if(!(Test-Path (Join-Path $inputData $file))){throw "Missing PT.8 prerequisite $file; run verify_path.ps1 first"}
}
& cmake -S $shared -B "$shared/build" -G 'Visual Studio 17 2022' -A x64 2>&1 | Tee-Object "$out/configure.txt"
if($LASTEXITCODE -ne 0){throw 'configure failed'}
& cmake --build "$shared/build" --config Release --target path_history_test path_render pbr_test scene_boundary_test --parallel 8 2>&1 | Tee-Object "$out/build.txt"
if($LASTEXITCODE -ne 0){throw 'history build failed'}
& dxc -T lib_6_3 -HV 2021 -Fo "$out/path.dxil" "$PSScriptRoot/path_integrator.hlsl" 2>&1 | Tee-Object "$out/ray-shader.txt"
if($LASTEXITCODE -ne 0){throw 'ray shader failed'}
& dxc -T cs_6_0 -E Accumulate -HV 2021 -Fo "$out/accumulate.dxil" "$PSScriptRoot/path_accumulate.hlsl" 2>&1 | Tee-Object "$out/accumulate-shader.txt"
if($LASTEXITCODE -ne 0){throw 'accumulation shader failed'}
& "$PSScriptRoot/build/Release/path_history_test.exe" "$inputData/gallery.gltf" "$out/path.dxil" "$out/accumulate.dxil" "$inputData/energy-lut.bin" $out 2>&1 | Tee-Object "$out/run.txt"
if($LASTEXITCODE -ne 0){throw 'history validation failed'}
# 共享Dispatch录制重构后，保留同步调用者必须继续工作。回归使用前课已验收的固定资产。
& "$PSScriptRoot/build/Release/path_render.exe" "$inputData/gallery.gltf" "$out/path.dxil" "$inputData/energy-lut.bin" "$out/pt08-primary-regression" 384 192 16 0 1 0 0 12 2>&1 | Tee-Object "$out/pt08-primary-regression.txt"
if($LASTEXITCODE -ne 0){throw 'PT.8 primary regression failed'}
& "$PSScriptRoot/../pt08-materials/build/Release/pbr_test.exe" "$PSScriptRoot/../pt08-materials/results/energy-gpu/pbr.gltf" "$inputData/pbr-regression.dxil" "$out/pbr-regression" "$inputData/energy-lut.bin" 2>&1 | Tee-Object "$out/pbr-regression.txt"
if($LASTEXITCODE -ne 0){throw 'PBR regression failed'}
& dxc -T lib_6_3 -HV 2021 -Fo "$out/d04-material.dxil" "$shared/shaders/material_rays.hlsl" 2>&1 | Tee-Object "$out/d04-shader.txt"
if($LASTEXITCODE -ne 0){throw 'D.4 regression shader failed'}
& "$shared/build/Release/scene_boundary_test.exe" "$out/d04-material.dxil" 2>&1 | Tee-Object "$out/d04-regression.txt"
if($LASTEXITCODE -ne 0){throw 'D.4 regression failed'}
& python "$PSScriptRoot/analyze_history.py"
if($LASTEXITCODE -ne 0){throw 'history image analysis failed'}
