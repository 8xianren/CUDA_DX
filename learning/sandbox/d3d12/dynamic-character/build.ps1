$ErrorActionPreference='Stop'
$shared=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../gltf-scene'))
$pt=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../path_tracing/dxr-path-tracer'))
$shaders=Join-Path $PSScriptRoot 'build/shaders'
New-Item -ItemType Directory -Force $shaders | Out-Null
cmake -S $shared -B "$shared/build" -DH_CHARACTER=ON
if($LASTEXITCODE -ne 0){throw 'configure failed'}
cmake --build "$shared/build" --config Release --target character_demo h_asset_probe h_animation_test h_controller_test h_input_test h_renderer_test h_temporal_test h_performance_test h_visual_test energy_lut_build --parallel 8
if($LASTEXITCODE -ne 0){throw 'build failed'}
# PT材质能量补偿查找表可重建；首次运行不能依赖前面课堂遗留的二进制文件。
if(!(Test-Path "$pt/results/pt08/energy-lut.bin")){
    New-Item -ItemType Directory -Force "$pt/results/pt08" | Out-Null
    & "$pt/../pt08-materials/build/Release/energy_lut_build.exe" "$pt/results/pt08"
    if($LASTEXITCODE -ne 0){throw 'energy LUT build failed'}
}
foreach($item in @(
    @('lib_6_3','',"$pt/path_integrator.hlsl",'path'),
    @('cs_6_0','Accumulate',"$pt/path_accumulate.hlsl",'accumulate'),
    @('lib_6_3','',"$PSScriptRoot/shaders/motion_guides.hlsl",'guides'),
    @('cs_6_0','Filter',"$PSScriptRoot/shaders/temporal.hlsl",'temporal'),
    @('vs_6_0','VSMain',"$PSScriptRoot/../r13-renderer/dxr_display.hlsl",'dxr_display_vs'),
    @('ps_6_0','PSMain',"$PSScriptRoot/../r13-renderer/dxr_display.hlsl",'dxr_display_ps'))){
    $arguments=@('-T',$item[0],'-HV','2021','-Fo',"$shaders/$($item[3]).dxil",$item[2]);if($item[1]){$arguments+=@('-E',$item[1])}
    dxc @arguments
    if($LASTEXITCODE -ne 0){throw "shader failed: $($item[3])"}
}
