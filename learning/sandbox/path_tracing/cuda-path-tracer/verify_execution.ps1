$ErrorActionPreference='Stop'
$out=Join-Path $PSScriptRoot 'results/execution'
New-Item -ItemType Directory -Force $out | Out-Null
$sandbox=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
& "$sandbox/build.ps1" "$PSScriptRoot/execution_bench.cu" -NoRun 2>&1 | Tee-Object "$out/build.txt"
if($LASTEXITCODE -ne 0){throw 'execution build failed'}
foreach($scene in @('cornell','gallery','empty')){
    & "$PSScriptRoot/execution_bench.exe" "$PSScriptRoot/results/bvh/gallery.meshbin" "$out/$scene" $scene bench all 2>&1 | Tee-Object "$out/$scene-run.txt"
    if($LASTEXITCODE -ne 0){throw "execution $scene failed"}
}
& compute-sanitizer --tool memcheck --leak-check full --error-exitcode 1 "$PSScriptRoot/execution_bench.exe" "$PSScriptRoot/results/bvh/gallery.meshbin" "$out/sanitizer" cornell quick all 2>&1 | Tee-Object "$out/memcheck.txt"
if($LASTEXITCODE -ne 0){throw 'execution memcheck failed'}
