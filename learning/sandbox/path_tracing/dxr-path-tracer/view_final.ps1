$ErrorActionPreference='Stop'
$out=Join-Path $PSScriptRoot 'results/pt10-final'
$exe=Join-Path $PSScriptRoot 'build/Release/path_final.exe'
if(!(Test-Path $exe) -or !(Test-Path "$out/dxr_display_ps.dxil")){throw 'Run verify_final.ps1 first'}
$previousPath=$env:PATH
try {
    $env:PATH="$(Join-Path $PSScriptRoot 'build/deps/oidn-2.5.0.x64.windows/bin');$previousPath"
    # 用户主动运行此脚本时显示交互窗口；不自动创建后台服务。只读取本窗口的按键消息。
    & $exe "$PSScriptRoot/results/pt08/gallery.gltf" $out "$PSScriptRoot/results/pt08/energy-lut.bin" "$out/interactive" interactive
    if($LASTEXITCODE -ne 0){throw 'interactive viewer failed'}
} finally {$env:PATH=$previousPath}
