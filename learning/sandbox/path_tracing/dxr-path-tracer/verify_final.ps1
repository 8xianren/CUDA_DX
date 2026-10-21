param([switch]$SkipBenchmark,[switch]$SkipRegression)
$ErrorActionPreference='Stop'
$out=Join-Path $PSScriptRoot 'results/pt10-final'
New-Item -ItemType Directory -Force $out | Out-Null
& "$PSScriptRoot/setup_oidn.ps1"
$previousPath=$env:PATH
try {
    $env:PATH="$(Join-Path $PSScriptRoot 'build/deps/oidn-2.5.0.x64.windows/bin');$previousPath"
    $shared=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../d3d12/gltf-scene'))
    $common=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../d3d12/common'))
    & cmake -S $shared -B "$shared/build" -G 'Visual Studio 17 2022' -A x64 -DPT10_INTEROP=ON 2>&1 | Tee-Object "$out/configure.txt"
    if($LASTEXITCODE -ne 0){throw 'final configure failed'}
    & cmake --build "$shared/build" --config Release --target path_final path_viewer path_interop_test path_history_test --parallel 8 2>&1 | Tee-Object "$out/build.txt"
    if($LASTEXITCODE -ne 0){throw 'final build failed'}
    & dxc -T lib_6_3 -HV 2021 -Fo "$out/path.dxil" "$PSScriptRoot/path_integrator.hlsl"
    if($LASTEXITCODE -ne 0){throw 'path shader failed'}
    & dxc -T cs_6_0 -E Accumulate -HV 2021 -Fo "$out/accumulate.dxil" "$PSScriptRoot/path_accumulate.hlsl"
    if($LASTEXITCODE -ne 0){throw 'accumulate shader failed'}
    & dxc -T cs_6_0 -E Pack -HV 2021 -Fo "$out/pack.dxil" "$PSScriptRoot/path_pack.hlsl"
    if($LASTEXITCODE -ne 0){throw 'pack shader failed'}
    & dxc -T vs_6_0 -E VSMain -HV 2021 -Fo "$out/dxr_display_vs.dxil" "$common/hdr_display.hlsl"
    if($LASTEXITCODE -ne 0){throw 'display VS failed'}
    & dxc -T ps_6_0 -E PSMain -HV 2021 -Fo "$out/dxr_display_ps.dxil" "$common/hdr_display.hlsl"
    if($LASTEXITCODE -ne 0){throw 'display PS failed'}
    $inputData=Join-Path $PSScriptRoot 'results/pt08'
    $exe=Join-Path $PSScriptRoot 'build/Release/path_final.exe'
    & nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv | Set-Content "$out/hardware-gpu.txt"
    & nvidia-smi --version | Set-Content "$out/driver-api-version.txt"
    & nvcc --version | Set-Content "$out/toolkit.txt"
    Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors | ConvertTo-Json | Set-Content "$out/hardware-cpu.json"
    & $exe "$inputData/gallery.gltf" $out "$inputData/energy-lut.bin" "$out/window" verify 2>&1 | Tee-Object "$out/window-run.txt"
    if($LASTEXITCODE -ne 0){throw 'final window failed'}
    & compute-sanitizer --tool memcheck --leak-check full --error-exitcode 1 $exe "$inputData/gallery.gltf" $out "$inputData/energy-lut.bin" "$out/sanitizer" verify 2>&1 | Tee-Object "$out/memcheck.txt"
    if($LASTEXITCODE -ne 0){throw 'final CUDA sanitizer failed'}
    if(!$SkipBenchmark){
        # 单独进程关闭Debug/GBV；相同shader/场景/同步路径。窗口Present/VSync不参与这组离屏计时。
        & $exe "$inputData/gallery.gltf" $out "$inputData/energy-lut.bin" "$out/benchmark" benchmark 2>&1 | Tee-Object "$out/benchmark-run.txt"
        if($LASTEXITCODE -ne 0){throw 'final benchmark failed'}
        & python "$PSScriptRoot/analyze_final.py" 2>&1 | Tee-Object "$out/analysis.txt"
        if($LASTEXITCODE -ne 0){throw 'final analysis failed'}
    }
    if(!$SkipRegression){
        & "$PSScriptRoot/build/Release/path_viewer.exe" "$inputData/gallery.gltf" $out "$inputData/energy-lut.bin" "$out/display-regression" verify 2>&1 | Tee-Object "$out/display-regression.txt"
        if($LASTEXITCODE -ne 0){throw 'legacy display regression failed'}
        & "$PSScriptRoot/build/Release/path_interop_test.exe" "$inputData/gallery.gltf" $out "$inputData/energy-lut.bin" "$out/interop-regression" quick 2>&1 | Tee-Object "$out/interop-regression.txt"
        if($LASTEXITCODE -ne 0){throw 'interop regression failed'}
        & "$PSScriptRoot/build/Release/path_history_test.exe" "$inputData/gallery.gltf" "$out/path.dxil" "$out/accumulate.dxil" "$inputData/energy-lut.bin" "$out/history-regression" 2>&1 | Tee-Object "$out/history-regression.txt"
        if($LASTEXITCODE -ne 0){throw 'history regression failed'}
        & "$PSScriptRoot/verify_display_compat.ps1" -OutputDirectory "$out/r13-regression"
    }
} finally {$env:PATH=$previousPath}
