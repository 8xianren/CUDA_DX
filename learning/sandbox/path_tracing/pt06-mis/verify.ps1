$ErrorActionPreference='Stop'
$out=Join-Path $PSScriptRoot 'results';New-Item -ItemType Directory -Force $out | Out-Null
$shared=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../d3d12/gltf-scene'))
& cmake -S $shared -B "$shared/build" -G 'Visual Studio 17 2022' -A x64 2>&1 | Tee-Object "$out/configure.txt"
if($LASTEXITCODE -ne 0){throw 'configure failed'}
& cmake --build "$shared/build" --config Release --target mis_test import_scope_test --parallel 8 2>&1 | Tee-Object "$out/build.txt"
if($LASTEXITCODE -ne 0){throw 'build failed'}
& dxc -T lib_6_3 -HV 2021 -Fo "$out/visibility.dxil" "$PSScriptRoot/visibility.hlsl" 2>&1 | Tee-Object "$out/shader-build.txt"
if($LASTEXITCODE -ne 0){throw 'shader failed'}
& python "$PSScriptRoot/make_fixture.py"
if($LASTEXITCODE -ne 0){throw 'fixture failed'}
foreach($case in @(@{name='small';h=.25},@{name='large';h=4})){
 $dir=Join-Path $out $case.name
 & node "$shared/validation/validate_import.cjs" "$dir/scene.gltf" "$dir/validation.json" 2>&1 | Tee-Object "$dir/validation.txt"
 if($LASTEXITCODE -ne 0){throw 'glTF validation failed'}
 & "$PSScriptRoot/build/Release/mis_test.exe" "$dir/scene.gltf" "$out/visibility.dxil" $dir $case.h 2>&1 | Tee-Object "$dir/gpu.txt"
 if($LASTEXITCODE -ne 0){throw "MIS failed: $($case.name)"}
}
