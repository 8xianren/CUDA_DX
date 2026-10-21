$ErrorActionPreference='Stop'
# 可以从任意目录调用；所有新产物定向到本课results/gpu，不污染调用者目录。
$out=Join-Path $PSScriptRoot 'results/gpu';New-Item -ItemType Directory -Force $out | Out-Null
$shared=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../d3d12/gltf-scene'))
& cmake -S $shared -B "$shared/build" -G 'Visual Studio 17 2022' -A x64 2>&1 | Tee-Object "$out/configure.txt"
if($LASTEXITCODE -ne 0){throw 'configure failed'}
& cmake --build "$shared/build" --config Release --target gpu_mis_test --parallel 8 2>&1 | Tee-Object "$out/build.txt"
if($LASTEXITCODE -ne 0){throw 'build failed'}
& dxc -T lib_6_3 -HV 2021 -Fo "$out/integrator.dxil" "$PSScriptRoot/gpu_integrator.hlsl" 2>&1 | Tee-Object "$out/shader-build.txt"
if($LASTEXITCODE -ne 0){throw 'shader failed'}
& python "$PSScriptRoot/make_fixture.py"
if($LASTEXITCODE -ne 0){throw 'fixture failed'}
foreach($case in @(@{name='small';h=.25},@{name='large';h=4})){
 $dir=Join-Path $out $case.name;New-Item -ItemType Directory -Force $dir | Out-Null
 $fixture=Join-Path $PSScriptRoot "results/$($case.name)/scene.gltf"
 & node "$shared/validation/validate_import.cjs" $fixture "$dir/validation.json" 2>&1 | Tee-Object "$dir/validation.txt"
 if($LASTEXITCODE -ne 0){throw 'glTF validation failed'}
 & "$PSScriptRoot/build/Release/gpu_mis_test.exe" $fixture "$out/integrator.dxil" $dir $case.h 2>&1 | Tee-Object "$dir/gpu.txt"
 if($LASTEXITCODE -ne 0){throw "GPU MIS failed: $($case.name)"}
}
