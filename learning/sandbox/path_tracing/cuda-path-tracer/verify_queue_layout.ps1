$ErrorActionPreference='Stop'
$out=Join-Path $PSScriptRoot 'results/queue-layout'
New-Item -ItemType Directory -Force $out | Out-Null
$sandbox=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
& "$sandbox/build.ps1" "$PSScriptRoot/queue_layout_audit.cu" -NoRun 2>&1 | Tee-Object "$out/build.txt"
if($LASTEXITCODE -ne 0){throw 'queue layout build failed'}
$exe=Join-Path $PSScriptRoot 'queue_layout_audit.exe'
$mesh=Join-Path $PSScriptRoot 'results/bvh/gallery.meshbin'
# 此程序逐阶段读回诊断，故不输出GPU性能结论；full保留实际队列，empty检验零长度路径。
foreach($scene in @('gallery','empty')){
    & $exe $mesh "$out/$scene" $scene full 2>&1 | Tee-Object "$out/$scene-run.txt"
    if($LASTEXITCODE -ne 0){throw "queue layout $scene failed"}
}
& compute-sanitizer --tool memcheck --leak-check full --error-exitcode 1 $exe $mesh "$out/sanitizer" gallery quick 2>&1 | Tee-Object "$out/memcheck.txt"
if($LASTEXITCODE -ne 0){throw 'queue layout memcheck failed'}
python "$PSScriptRoot/analyze_queue_layout.py"
if($LASTEXITCODE -ne 0){throw 'queue layout analysis failed'}
