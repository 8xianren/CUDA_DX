param([switch]$SkipBuild,[switch]$SkipProfiler)
$ErrorActionPreference='Stop'
$course=(Resolve-Path "$PSScriptRoot/../..").Path
if(!$SkipBuild){& "$PSScriptRoot/build-volume.ps1" -NoRun}
$exe="$course/build/volume/volume_validate.exe"
& $exe "$course/results" all
if($LASTEXITCODE -ne 0){throw 'volume correctness/performance failed'}
foreach($tool in @('memcheck','synccheck')){
    $extra=@()
    if($tool -eq 'memcheck'){$extra=@('--leak-check','full')}
    & compute-sanitizer --tool $tool @extra --error-exitcode 2 --log-file "$course/results/g2/sanitizer_$tool.log" $exe "$course/results" quick
    if($LASTEXITCODE -ne 0){throw "volume $tool failed"}
}
if(!$SkipProfiler){
    & ncu --target-processes all --set basic --launch-count 1 --csv --log-file "$course/results/g3/ncu_basic.csv" $exe "$course/results" profile
    # 保留实际权限错误；2026-10-22用户授权本轮略过硬件counter，不把失败写成取得了指标。
    if($LASTEXITCODE -ne 0){Write-Warning 'NCU未取得指标；本轮已获用户授权略过，日志仍保留。'}
}
python "$PSScriptRoot/report-volume.py"
if($LASTEXITCODE -ne 0){throw 'volume report generation failed'}
