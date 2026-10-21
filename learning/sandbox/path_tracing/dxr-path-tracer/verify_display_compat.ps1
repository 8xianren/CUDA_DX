param([string]$OutputDirectory='')
$ErrorActionPreference='Stop'
$out=if($OutputDirectory){[IO.Path]::GetFullPath($OutputDirectory)}else{Join-Path $PSScriptRoot 'results/pt10-display/r13-regression'}
New-Item -ItemType Directory -Force $out | Out-Null
$lesson=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../d3d12/r13-renderer'))
$sandbox=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
# 旧宿主仍用课程build.ps1/nvcc sm_120；没有新增CUDA kernel，仅重新编译共享窗口头的使用者。
& "$sandbox/build.ps1" "$lesson/dxr_view_pipeline.cu" -NoRun 2>&1 | Tee-Object "$out/build.txt"
if($LASTEXITCODE -ne 0){throw 'R.13 compatibility build failed'}
& dxc -T lib_6_3 -D ENABLE_DIRECT_LIGHT=1 -D ENABLE_PROGRESSIVE=1 -D ENABLE_HISTORY=1 -Fo "$out/dxr_history.dxil" "$lesson/dxr_view.hlsl" 2>&1 | Tee-Object "$out/ray-shader.txt"
if($LASTEXITCODE -ne 0){throw 'R.13 history shader failed'}
& dxc -T vs_6_0 -E VSMain -Fo "$out/dxr_display_vs.dxil" "$lesson/dxr_display.hlsl" 2>&1 | Tee-Object "$out/vs-shader.txt"
if($LASTEXITCODE -ne 0){throw 'R.13 display VS failed'}
& dxc -T ps_6_0 -E PSMain -Fo "$out/dxr_display_ps.dxil" "$lesson/dxr_display.hlsl" 2>&1 | Tee-Object "$out/ps-shader.txt"
if($LASTEXITCODE -ne 0){throw 'R.13 display PS failed'}
# DXIL目录作为旧宿主的输出基准，新增回归图像/日志归PT.10，不覆盖R.13历史结果。
foreach($mode in @('window','resize')){
    & "$lesson/dxr_view_pipeline.exe" "$out/dxr_history.dxil" $mode 2>&1 | Tee-Object "$out/$mode.txt"
    if($LASTEXITCODE -ne 0){throw "R.13 $mode regression failed"}
}
