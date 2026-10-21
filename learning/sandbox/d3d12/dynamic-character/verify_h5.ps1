$ErrorActionPreference='Stop'
$shared=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../gltf-scene'))
$pt=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../path_tracing/dxr-path-tracer'))
$out=Join-Path $PSScriptRoot 'results/h5'
$shaders=Join-Path $PSScriptRoot 'build/shaders'
New-Item -ItemType Directory -Force $out,$shaders | Out-Null
cmake -S $shared -B "$shared/build" -DH_CHARACTER=ON 2>&1 | Tee-Object "$out/configure.txt"
if($LASTEXITCODE -ne 0){throw 'configure failed'}
cmake --build "$shared/build" --config Release --target h_renderer_test --parallel 8 2>&1 | Tee-Object "$out/build.txt"
if($LASTEXITCODE -ne 0){throw 'build failed'}
dxc -T lib_6_3 -HV 2021 -Fo "$shaders/path.dxil" "$pt/path_integrator.hlsl" 2>&1 | Tee-Object "$out/ray-shader.txt"
if($LASTEXITCODE -ne 0){throw 'ray shader failed'}
dxc -T cs_6_0 -E Accumulate -HV 2021 -Fo "$shaders/accumulate.dxil" "$pt/path_accumulate.hlsl" 2>&1 | Tee-Object "$out/accumulate-shader.txt"
if($LASTEXITCODE -ne 0){throw 'accumulation shader failed'}
& "$PSScriptRoot/build/Release/h_renderer_test.exe" "$PSScriptRoot/assets/runtime" $shaders "$pt/results/pt08/energy-lut.bin" $out 2>&1 | Tee-Object "$out/run.txt"
if($LASTEXITCODE -ne 0){throw 'renderer verification failed'}
