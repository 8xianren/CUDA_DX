$ErrorActionPreference='Stop'
$out=Join-Path $PSScriptRoot 'results/pt10-display'
New-Item -ItemType Directory -Force $out | Out-Null
$shared=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../d3d12/gltf-scene'))
$common=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../d3d12/common'))
$data=Join-Path $PSScriptRoot 'results/pt08'
foreach($file in @('gallery.gltf','gallery.bin','energy-lut.bin')){
    if(!(Test-Path (Join-Path $data $file))){throw "Missing PT.8 prerequisite: $file"}
}
& cmake -S $shared -B "$shared/build" -G 'Visual Studio 17 2022' -A x64 2>&1 | Tee-Object "$out/configure.txt"
if($LASTEXITCODE -ne 0){throw 'configure failed'}
& cmake --build "$shared/build" --config Release --target path_viewer path_history_test --parallel 8 2>&1 | Tee-Object "$out/build.txt"
if($LASTEXITCODE -ne 0){throw 'viewer build failed'}
& dxc -T lib_6_3 -HV 2021 -Fo "$out/path.dxil" "$PSScriptRoot/path_integrator.hlsl" 2>&1 | Tee-Object "$out/path-shader.txt"
if($LASTEXITCODE -ne 0){throw 'path shader failed'}
& dxc -T cs_6_0 -HV 2021 -E Accumulate -Fo "$out/accumulate.dxil" "$PSScriptRoot/path_accumulate.hlsl" 2>&1 | Tee-Object "$out/accumulate-shader.txt"
if($LASTEXITCODE -ne 0){throw 'accumulation shader failed'}
& dxc -T vs_6_0 -HV 2021 -E VSMain -Fo "$out/dxr_display_vs.dxil" "$common/hdr_display.hlsl" 2>&1 | Tee-Object "$out/vs-shader.txt"
if($LASTEXITCODE -ne 0){throw 'display VS failed'}
& dxc -T ps_6_0 -HV 2021 -E PSMain -Fo "$out/dxr_display_ps.dxil" "$common/hdr_display.hlsl" 2>&1 | Tee-Object "$out/ps-shader.txt"
if($LASTEXITCODE -ne 0){throw 'display PS failed'}
& "$PSScriptRoot/build/Release/path_viewer.exe" "$data/gallery.gltf" $out "$data/energy-lut.bin" $out verify 2>&1 | Tee-Object "$out/run.txt"
if($LASTEXITCODE -ne 0){throw 'GPU display verification failed'}
# SubmitWait增加Present回调后的无回调路径，也必须保持原GPU历史验收。
& "$PSScriptRoot/build/Release/path_history_test.exe" "$data/gallery.gltf" "$out/path.dxil" "$out/accumulate.dxil" "$data/energy-lut.bin" "$out/history-regression" 2>&1 | Tee-Object "$out/history-regression.txt"
if($LASTEXITCODE -ne 0){throw 'history regression failed'}
& python "$PSScriptRoot/analyze_display.py"
if($LASTEXITCODE -ne 0){throw 'display analysis failed'}
& "$PSScriptRoot/verify_display_compat.ps1"
