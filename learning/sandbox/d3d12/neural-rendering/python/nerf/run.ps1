param([int]$Steps = 1800, [switch]$SkipTraining)
$ErrorActionPreference = 'Stop'
$course = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$python = Join-Path $course '.venv/Scripts/python.exe'
if (-not (Test-Path -LiteralPath $python)) { throw '请先运行 python/nerf/setup.ps1' }
& $python (Join-Path $course 'tests/nerf/contracts.py')
if ($LASTEXITCODE -ne 0) { throw 'G4 数值契约失败' }
if (-not $SkipTraining) {
    & $python (Join-Path $PSScriptRoot 'train.py') --steps $Steps
    if ($LASTEXITCODE -ne 0) { throw 'G4 真实训练/过拟合验收失败' }
}
& $python (Join-Path $PSScriptRoot 'benchmark.py')
if ($LASTEXITCODE -ne 0) { throw 'G5 烘焙与MLP对照失败' }
& $python (Join-Path $PSScriptRoot 'benchmark.py') --export-only --width 320 --height 240 --output (Join-Path $course 'results/g5/resize-320x240')
if ($LASTEXITCODE -ne 0) { throw 'G10 resize NeRF 输出失败' }
& $python (Join-Path $course 'tests/nerf/exports.py')
if ($LASTEXITCODE -ne 0) { throw 'G10 NeRF 浮点文件、相机与遮挡契约失败' }
