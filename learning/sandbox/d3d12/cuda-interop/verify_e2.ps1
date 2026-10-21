param([switch]$SkipBuild,[switch]$SkipSanitizer)
$ErrorActionPreference='Stop'
$out=Join-Path $PSScriptRoot 'results/e2'
$shared=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../gltf-scene'))
New-Item -ItemType Directory -Force $out | Out-Null
if(!$SkipBuild){
    & cmake -S $shared -B "$shared/build" -DE_INTEROP=ON 2>&1 | Tee-Object "$out/configure.txt"
    if($LASTEXITCODE -ne 0){throw 'configure failed'}
    & cmake --build "$shared/build" --config Release --target interop_test --parallel 8 2>&1 | Tee-Object "$out/build.txt"
    if($LASTEXITCODE -ne 0){throw 'build failed'}
}
$exe=Join-Path $PSScriptRoot 'build/Release/interop_test.exe'
$shader=Join-Path $PSScriptRoot 'shaders/instances.hlsl'
foreach($mode in @('e2','e2-stale')){
    & $exe "$shared/results/c04/trs.gltf" $shader "$out/$mode" $mode 2>&1 | Tee-Object "$out/$mode.txt"
    if($LASTEXITCODE -ne 0){throw "$mode failed"}
}
if(!$SkipSanitizer){
    & compute-sanitizer --tool memcheck --leak-check full --error-exitcode 1 $exe "$shared/results/c04/trs.gltf" $shader "$out/sanitizer" e2 2>&1 | Tee-Object "$out/memcheck.txt"
    if($LASTEXITCODE -ne 0){throw 'E.2 memcheck failed'}
}
Add-Type -AssemblyName System.Drawing
foreach($f in @(0,23)){
    $bitmap=[Drawing.Bitmap]::new("$out/e2/frame-$f.bmp")
    try{$bitmap.Save("$out/e2/frame-$f.png",[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
}
