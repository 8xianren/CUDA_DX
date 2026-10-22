param([switch]$SkipBuild,[switch]$SkipTraining,[switch]$IntegrationOnly)
$ErrorActionPreference='Stop'
if(!$SkipBuild){& "$PSScriptRoot/build.ps1"}
if(!$IntegrationOnly){
    & "$PSScriptRoot/tests/volume/verify-volume.ps1" -SkipProfiler
    & "$PSScriptRoot/tests/gaussian/verify.ps1" -Build -Sanitizer
    & "$PSScriptRoot/python/nerf/run.ps1" -SkipTraining:$SkipTraining
    python "$PSScriptRoot/python/assets/fetch_reference.py"
    if($LASTEXITCODE -ne 0){throw 'Reference fetch failed'}
    python "$PSScriptRoot/python/assets/convert_ply.py"
    if($LASTEXITCODE -ne 0){throw 'Reference import failed'}
    python "$PSScriptRoot/tests/assets/test_import.py"
    if($LASTEXITCODE -ne 0){throw 'Asset tests failed'}
    python "$PSScriptRoot/python/assets/reference_camera.py"
    if($LASTEXITCODE -ne 0){throw 'Paired camera import failed'}
    & "$PSScriptRoot/tests/assets/reference_build.ps1"
    python "$PSScriptRoot/python/assets/reference_preview.py"
    if($LASTEXITCODE -ne 0){throw 'Paired reference preview report failed'}
}
$exe="$PSScriptRoot/build/Release/g_demo.exe"
& $exe --root $PSScriptRoot
if($LASTEXITCODE -ne 0){throw 'G10 validation failed'}
& $exe --root $PSScriptRoot --asset "$PSScriptRoot/downloads/reference/train-7000.gsbin"
if($LASTEXITCODE -ne 0){throw 'G10 reference asset failed'}
& $exe --root $PSScriptRoot --performance
if($LASTEXITCODE -ne 0){throw 'G10 repeated timing failed'}
foreach($kind in @('memcheck','synccheck')){
    & compute-sanitizer --tool $kind --error-exitcode 99 --log-file "$PSScriptRoot/results/g10/$kind.log" $exe --root $PSScriptRoot
    if($LASTEXITCODE -ne 0){throw "G10 $kind failed"}
}
python "$PSScriptRoot/tests/report.py"
if($LASTEXITCODE -ne 0){throw 'Final evidence audit failed'}
