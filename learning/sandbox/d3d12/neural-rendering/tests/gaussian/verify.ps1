param([switch]$Build,[switch]$Sanitizer,[switch]$Counters)
$ErrorActionPreference='Stop'
$course=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if($Build){& "$PSScriptRoot/build.ps1" -NoRun;if($LASTEXITCODE -ne 0){throw 'Build failed'}}
$exe=Join-Path $course 'build/gaussian/verify_gaussian.exe'
& $exe "$course/results"
if($LASTEXITCODE -ne 0){throw 'Gaussian validation failed'}
if($Sanitizer){
    foreach($tool in @('memcheck','synccheck')){
        & compute-sanitizer --tool $tool --error-exitcode 99 --log-file "$course/results/g8/$tool.log" $exe "$course/results" --check-only
        if($LASTEXITCODE -ne 0){throw "compute-sanitizer $tool failed"}
    }
}
# 2026-10-22 实际尝试被驱动 ERR_NVGPUCTRPERM 拒绝，用户已授权本轮跳过；默认不重试权限设置。
# 未来启用 GPU counters 后，可显式 -Counters 重放，不把静态 shared 大小冒充硬件 occupancy 测量。
if($Counters){
    & ncu --target-processes all --kernel-name 'regex:.*splatKernel.*' --launch-count 1 --section LaunchStats --section Occupancy --section MemoryWorkloadAnalysis --section SourceCounters --csv --log-file "$course/results/g8/ncu.csv" $exe "$course/results" --profile
    if($LASTEXITCODE -ne 0){throw 'Nsight Compute counters unavailable; inspect results/g8/ncu.csv'}
}
