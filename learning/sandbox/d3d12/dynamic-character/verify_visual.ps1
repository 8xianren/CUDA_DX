param([switch]$SkipBuild)
$ErrorActionPreference='Stop'
if(!$SkipBuild){& "$PSScriptRoot/build.ps1"}
$pt=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../path_tracing/dxr-path-tracer'))
$out=Join-Path $PSScriptRoot 'results/visual'
New-Item -ItemType Directory -Force $out | Out-Null
python "$PSScriptRoot/audit_sky.py" 2>&1 | Tee-Object "$out/sky-audit.txt"
if($LASTEXITCODE -ne 0){throw 'sky numerical audit failed'}
& "$PSScriptRoot/build/Release/h_visual_test.exe" "$PSScriptRoot/assets/runtime" "$PSScriptRoot/build/shaders" "$pt/results/pt08/energy-lut.bin" $out 2>&1 | Tee-Object "$out/run.txt"
if($LASTEXITCODE -ne 0){throw 'visual verification failed'}
& "$PSScriptRoot/build/Release/h_performance_test.exe" "$PSScriptRoot/assets/runtime" "$PSScriptRoot/build/shaders" "$pt/results/pt08/energy-lut.bin" $out presentation 2>&1 | Tee-Object "$out/performance-run.txt"
if($LASTEXITCODE -ne 0){throw 'visual performance failed'}
# PPM是直接渲染结果；Pillow仅无损转换成便于查看的PNG，不进行锐化/放大或修图。
python -c "from pathlib import Path; from PIL import Image; p=Path(r'$out'); [Image.open(f).save(f.with_suffix('.png')) for f in p.glob('*.ppm')]"
if($LASTEXITCODE -ne 0){throw 'PNG conversion failed (Pillow required)'}
