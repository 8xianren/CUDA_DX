param([switch]$SkipFetch)
$ErrorActionPreference='Stop'
if(!$SkipFetch){
    python "$PSScriptRoot/fetch_nis.py"
    if($LASTEXITCODE -ne 0){throw 'NIS fetch failed'}
    & "$PSScriptRoot/fetch_sdks.ps1"
}
$shaders=Join-Path $PSScriptRoot 'build/shaders'
New-Item -ItemType Directory -Force $shaders | Out-Null
foreach($entry in @('CopyCS','FxaaCS','TaaCS','BilinearCS','BicubicCS','MotionCS','SharpenCS','UnjitterCS')){
    dxc -T cs_6_0 -E $entry -HV 2021 -Fo "$shaders/$entry.dxil" "$PSScriptRoot/shaders/post.hlsl"
    if($LASTEXITCODE -ne 0){throw "post shader $entry failed"}
}
foreach($item in @(@('vs_6_0','SceneVS','scene','scene_vs'),@('ps_6_0','ScenePS','scene','scene_ps'),@('vs_6_0','DisplayVS','display','display_vs'),@('ps_6_0','DisplayPS','display','display_ps'),@('cs_6_0','main','nis','NisCS'),@('cs_6_0','ReferenceCS','reference','ReferenceCS'))){
    dxc -T $item[0] -E $item[1] -HV 2021 -Fo "$shaders/$($item[3]).dxil" "$PSScriptRoot/shaders/$($item[2]).hlsl"
    if($LASTEXITCODE -ne 0){throw "shader $($item[3]) failed"}
}
cmake -S $PSScriptRoot -B "$PSScriptRoot/build" -A x64
if($LASTEXITCODE -ne 0){throw 'F configure failed'}
cmake --build "$PSScriptRoot/build" --config Release --parallel 8
if($LASTEXITCODE -ne 0){throw 'F build failed'}
