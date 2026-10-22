param([switch]$SkipShaders)
$ErrorActionPreference='Stop'
$shaders=Join-Path $PSScriptRoot 'build/shaders'
New-Item -ItemType Directory -Force $shaders | Out-Null
if(!$SkipShaders){
    foreach($item in @(@('MeshVS','vs_6_0'),@('MeshPS','ps_6_0'),@('FullVS','vs_6_0'),@('CompositePS','ps_6_0'))){
        dxc -T $item[1] -E $item[0] -HV 2021 -Fo "$shaders/$($item[0]).dxil" "$PSScriptRoot/shaders/passes.hlsl"
        if($LASTEXITCODE -ne 0){throw "G shader failed: $($item[0])"}
    }
}
cmake -S $PSScriptRoot -B "$PSScriptRoot/build" -A x64 -T 'cuda=C:/Program Files/NVIDIA GPU Computing Toolkit/CUDA/v13.3'
if($LASTEXITCODE -ne 0){throw 'G configure failed'}
cmake --build "$PSScriptRoot/build" --config Release --parallel 6
if($LASTEXITCODE -ne 0){throw 'G build failed'}
