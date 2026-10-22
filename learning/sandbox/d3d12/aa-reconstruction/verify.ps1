param([switch]$SkipBuild,[switch]$SkipFrameGeneration,[switch]$SkipBenchmark)
$ErrorActionPreference='Stop'
if(!$SkipBuild){& "$PSScriptRoot/build.ps1";if(!$?){throw 'F build failed'}}
$exe=Join-Path $PSScriptRoot 'build/Release/f_lessons.exe'
$out=Join-Path $PSScriptRoot 'results/verification'
New-Item -ItemType Directory -Force $out | Out-Null
function Run-Lesson([string]$label,[string[]]$arguments){
    Write-Host "运行 F 验收：$label"
    & $exe @arguments 2>&1 | Tee-Object (Join-Path $out "$label.txt")
    if($LASTEXITCODE -ne 0){throw "F verification failed: $label"}
}
Run-Lesson 'suite' @('suite')
python "$PSScriptRoot/audit_temporal.py" --emit-fixtures
if($LASTEXITCODE -ne 0){throw 'CPU contracts/fixture generation failed'}
Run-Lesson 'oracle' @('oracle')
python "$PSScriptRoot/audit_temporal.py" --gpu-oracle-root "$PSScriptRoot/results/f5/oracle-input"
if($LASTEXITCODE -ne 0){throw 'GPU oracle failed'}
python "$PSScriptRoot/verify_sdk_contracts.py"
if($LASTEXITCODE -ne 0){throw 'SDK mapping contracts failed'}
& "$PSScriptRoot/build/Release/f_sdk_probe.exe" "$PSScriptRoot/build/deps" "$PSScriptRoot/results/f7/sdk-probe.json" 2>&1 | Tee-Object "$out/sdk-probe.txt"
if($LASTEXITCODE -ne 0){throw 'SDK initialization/resize lifecycle failed'}
Run-Lesson 'sdk-missing-fallback' @('sequence','fsr-unavailable','8')
Run-Lesson 'sdk-dynamic' @('sequence','fsr-dynamic','16')
Run-Lesson 'sdk-resize' @('sdk-resize')
# 每种模式单独启动，确保上下文/历史完全独立；同一time=frame/60、frame60相机切换。
$methods=@('reference','noaa','msaa4','fxaa','taa','taa-no-reprojection','taa-no-rejection','taa-no-clamp','bilinear','bicubic','nis','fsr-native','fsr-quality','fsr-balanced','fsr-performance','xess-native','xess-quality','xess-balanced','xess-performance')
foreach($method in $methods){
    Run-Lesson "sequence-$method" @('sequence',$method,'120')
    $summary=Get-Content -LiteralPath "$PSScriptRoot/results/f10/sequences/$method/summary.json" -Raw | ConvertFrom-Json
    if(!$summary.pass -or $summary.frames -ne 120 -or $summary.fallback){throw "Required method failed/fell back: $method"}
}
python "$PSScriptRoot/analyze_sequences.py" --self-test
if($LASTEXITCODE -ne 0){throw 'F10 analysis math/coverage contracts failed'}
python "$PSScriptRoot/analyze_sequences.py"
if($LASTEXITCODE -ne 0){throw 'F10 quality analysis failed'}
if(!$SkipBenchmark){foreach($method in $methods){Run-Lesson "benchmark-$method" @('bench',$method,'40')}}
if(!$SkipFrameGeneration){
    & "$PSScriptRoot/build_framegen.ps1"
    if(!$?){throw 'frame generation build failed'}
    python "$PSScriptRoot/verify_framegen.py"
    if($LASTEXITCODE -ne 0){throw 'frame generation verification failed'}
}
if(!$SkipBenchmark){
    python "$PSScriptRoot/summarize_verification.py"
    if($LASTEXITCODE -ne 0){throw 'Final F evidence incomplete'}
}
Write-Host 'F 验收命令全部成功；固定场景的性能不是H人物Demo的端到端FPS。'
