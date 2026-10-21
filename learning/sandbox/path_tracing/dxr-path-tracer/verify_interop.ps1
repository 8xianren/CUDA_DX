param([switch]$SkipSanitizer)
$ErrorActionPreference='Stop'
$out=Join-Path $PSScriptRoot 'results/pt10-interop'
New-Item -ItemType Directory -Force $out | Out-Null
& "$PSScriptRoot/setup_oidn.ps1"
$oidn=Join-Path $PSScriptRoot 'build/deps/oidn-2.5.0.x64.windows/bin'
$previousPath=$env:PATH
try {
    # 进程范围DLL搜索路径；退出恢复原PATH，不更改系统环境。
    $env:PATH="$oidn;$previousPath"
    & "$oidn/oidnDenoise.exe" --list_devices 2>&1 | Tee-Object "$out/oidn-devices.txt"
    if($LASTEXITCODE -ne 0){throw 'OIDN device probe failed'}
    $shared=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../d3d12/gltf-scene'))
    & cmake -S $shared -B "$shared/build" -G 'Visual Studio 17 2022' -A x64 -DPT10_INTEROP=ON 2>&1 | Tee-Object "$out/configure.txt"
    if($LASTEXITCODE -ne 0){throw 'interop configure failed'}
    & cmake --build "$shared/build" --config Release --target path_interop_test path_history_test path_render --parallel 8 2>&1 | Tee-Object "$out/build.txt"
    if($LASTEXITCODE -ne 0){throw 'interop build failed'}
    & dxc -T lib_6_3 -HV 2021 -Fo "$out/path.dxil" "$PSScriptRoot/path_integrator.hlsl"
    if($LASTEXITCODE -ne 0){throw 'path DXIL failed'}
    & dxc -T cs_6_0 -E Accumulate -HV 2021 -Fo "$out/accumulate.dxil" "$PSScriptRoot/path_accumulate.hlsl"
    if($LASTEXITCODE -ne 0){throw 'accumulate DXIL failed'}
    & dxc -T cs_6_0 -E Pack -HV 2021 -Fo "$out/pack.dxil" "$PSScriptRoot/path_pack.hlsl"
    if($LASTEXITCODE -ne 0){throw 'pack DXIL failed'}
    $inputData=Join-Path $PSScriptRoot 'results/pt08'
    $exe=Join-Path $PSScriptRoot 'build/Release/path_interop_test.exe'
    & $exe "$inputData/gallery.gltf" $out "$inputData/energy-lut.bin" $out full 2>&1 | Tee-Object "$out/run.txt"
    if($LASTEXITCODE -ne 0){throw 'interop GPU verification failed'}
    if(!$SkipSanitizer){
        & compute-sanitizer --tool memcheck --leak-check full --error-exitcode 1 $exe "$inputData/gallery.gltf" $out "$inputData/energy-lut.bin" "$out/sanitizer" quick 2>&1 | Tee-Object "$out/memcheck.txt"
        if($LASTEXITCODE -ne 0){throw 'CUDA memcheck failed'}
    }
    & "$PSScriptRoot/build/Release/path_history_test.exe" "$inputData/gallery.gltf" "$out/path.dxil" "$out/accumulate.dxil" "$inputData/energy-lut.bin" "$out/history-regression" 2>&1 | Tee-Object "$out/history-regression.txt"
    if($LASTEXITCODE -ne 0){throw 'history regression failed'}
    & "$PSScriptRoot/build/Release/path_render.exe" "$inputData/gallery.gltf" "$out/path.dxil" "$inputData/energy-lut.bin" "$out/pt08-regression" 384 192 16 0 1 0 0 12 2>&1 | Tee-Object "$out/pt08-regression.txt"
    if($LASTEXITCODE -ne 0){throw 'PT.8 primary regression failed'}
    & python "$PSScriptRoot/analyze_interop.py" 2>&1 | Tee-Object "$out/analysis.txt"
    if($LASTEXITCODE -ne 0){throw 'interop analysis failed'}
} finally {$env:PATH=$previousPath}
