param([switch]$SkipSanitizer)
$ErrorActionPreference='Stop'
$out=Join-Path $PSScriptRoot 'results/e1'
$shared=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../gltf-scene'))
New-Item -ItemType Directory -Force $out | Out-Null
if(-not(Test-Path "$shared/results/c04/trs.gltf")){ & "$shared/verify_hierarchy.ps1" }
# 共享CMake工程已负责VS2022和nvcc集成；CUDA目标固定sm_120，Release，C++17，UTF-8。
& cmake -S $shared -B "$shared/build" -G 'Visual Studio 17 2022' -A x64 -DE_INTEROP=ON 2>&1 | Tee-Object "$out/configure.txt"
if($LASTEXITCODE -ne 0){throw 'configure failed'}
& cmake --build "$shared/build" --config Release --target interop_test --parallel 8 2>&1 | Tee-Object "$out/build.txt"
if($LASTEXITCODE -ne 0){throw 'build failed'}
$exe=Join-Path $PSScriptRoot 'build/Release/interop_test.exe'
$shader=Join-Path $PSScriptRoot 'shaders/instances.hlsl'
& $exe "$shared/results/c04/trs.gltf" $shader $out 2>&1 | Tee-Object "$out/run.txt"
if($LASTEXITCODE -ne 0){throw 'E.1 validation failed'}
# 对日志做独立状态机重放；零CPU中间等待来自实际提交代码，不把GPU等待也算成零。
$rows=Import-Csv "$out/fences.csv"
for($i=0;$i -lt $rows.Count;$i++){
    $r=$rows[$i]
    if([int]$r.frame -ne $i -or [int]$r.slot -ne 0 -or [int]$r.cuda_wait_consumed -ne $i -or
       [int]$r.cuda_signal_ready -ne ($i+1) -or [int]$r.d3d_wait_ready -ne ($i+1) -or
       [int]$r.d3d_signal_consumed -ne ($i+1)){throw "Fence replay failed at $i"}
}
"PASS: $($rows.Count) frame dependency chains replayed; GPU completion values checked by executable." | Set-Content "$out/replay.txt"
if(!$SkipSanitizer){
    & compute-sanitizer --tool memcheck --leak-check full --error-exitcode 1 $exe "$shared/results/c04/trs.gltf" $shader "$out/sanitizer" 2>&1 | Tee-Object "$out/memcheck.txt"
    if($LASTEXITCODE -ne 0){throw 'memcheck failed'}
}
Add-Type -AssemblyName System.Drawing
foreach($f in @(0,23)){
    $bitmap=[Drawing.Bitmap]::new("$out/frame-$f.bmp")
    try{$bitmap.Save("$out/frame-$f.png",[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
}
