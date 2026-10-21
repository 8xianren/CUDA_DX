param([switch]$SkipSanitizer)
$ErrorActionPreference='Stop'
$shared=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../gltf-scene'))
$out=Join-Path $PSScriptRoot 'results/h2'
New-Item -ItemType Directory -Force $out | Out-Null
cmake -S $shared -B "$shared/build" -DH_CHARACTER=ON 2>&1 | Tee-Object "$out/configure.txt"
if($LASTEXITCODE -ne 0){throw 'configure failed'}
cmake --build "$shared/build" --config Release --target h_animation_test --parallel 8 2>&1 | Tee-Object "$out/build.txt"
if($LASTEXITCODE -ne 0){throw 'build failed'}
$exe=Join-Path $PSScriptRoot 'build/Release/h_animation_test.exe'
$asset=Join-Path $PSScriptRoot 'assets/runtime/animation.glb'
& $exe $asset $out 2>&1 | Tee-Object "$out/run.txt"
if($LASTEXITCODE -ne 0){throw 'animation test failed'}
python "$PSScriptRoot/audit_animation.py" 2>&1 | Tee-Object "$out/independent.txt"
if($LASTEXITCODE -ne 0){throw 'independent reference failed'}
if(!$SkipSanitizer){
    compute-sanitizer --tool memcheck --leak-check full --error-exitcode 1 $exe $asset "$out/sanitizer" 2>&1 | Tee-Object "$out/memcheck.txt"
    if($LASTEXITCODE -ne 0){throw 'memcheck failed'}
}
