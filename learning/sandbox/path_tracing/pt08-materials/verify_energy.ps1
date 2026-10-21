$ErrorActionPreference='Stop'
# 本节纯CPU double数学参考，用既有VS2022/CMake的Release优化构建；无CUDA kernel，也没有GPU提交。
$out=Join-Path $PSScriptRoot 'results/energy'
New-Item -ItemType Directory -Force $out | Out-Null
$shared=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../d3d12/gltf-scene'))
& cmake -S $shared -B "$shared/build" -G 'Visual Studio 17 2022' -A x64 2>&1 | Tee-Object "$out/configure.txt"
if($LASTEXITCODE -ne 0){throw 'configure failed'}
& cmake --build "$shared/build" --config Release --target energy_test --parallel 8 2>&1 | Tee-Object "$out/build.txt"
if($LASTEXITCODE -ne 0){throw 'energy build failed'}
& "$PSScriptRoot/build/Release/energy_test.exe" $out 2>&1 | Tee-Object "$out/run.txt"
if($LASTEXITCODE -ne 0){throw 'energy conservation/reference failed'}
