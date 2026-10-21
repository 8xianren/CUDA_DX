param([switch]$SkipBuild,[switch]$SkipSanitizer,[switch]$ValidationOnly)
$ErrorActionPreference='Stop'
$out=Join-Path $PSScriptRoot 'results/e3'
$shared=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../gltf-scene'))
New-Item -ItemType Directory -Force $out | Out-Null
if(!$SkipBuild){
    & cmake -S $shared -B "$shared/build" -DE_INTEROP=ON 2>&1 | Tee-Object "$out/configure.txt"
    if($LASTEXITCODE -ne 0){throw 'E.3 configure failed'}
    & cmake --build "$shared/build" --config Release --target buffer_bench interop_test --parallel 8 2>&1 | Tee-Object "$out/build.txt"
    if($LASTEXITCODE -ne 0){throw 'E.3 build failed'}
}
$exe=Join-Path $PSScriptRoot 'build/Release/buffer_bench.exe'
$shader=Join-Path $PSScriptRoot 'shaders/instances.hlsl'
$model=Join-Path $shared 'results/c04/trs.gltf'
& nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader | Set-Content "$out/hardware.txt"
& nvcc --version | Set-Content "$out/nvcc.txt"
Get-FileHash $model,"$shared/results/c04/c01-shared-mesh.bin",$shader,$exe | ConvertTo-Json | Set-Content "$out/input-hashes.json"
@{cpu=(Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors);
  os=(Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber);
  ram_bytes=(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory;
  build='VS2022 MSVC 14.44; Release /O2; C++17; CUDA 13.3 sm_120; HLSL vs_5_1/ps_5_1 D3DCompile strict';
  presentation='1024x1024 offscreen, no swapchain, no Present, VSync not applicable';
  workload='16384 independent scalar recurrences plus four real glTF instance updates and mesh0 deformation; synthetic pixel ALU loop';
  measurement='48 fixed frames; 2 warmup batches and 5 measured batches per process; 3 rotated slot-order passes; no profiler';
  limitations='No clock lock, no hardware counters, finite pre-recorded batches; CUDA events include intervening scheduling delays.'
} | ConvertTo-Json -Depth 4 | Set-Content "$out/environment.json"
foreach($slots in @(1,2,3)){
    & $exe $model $shader "$out/validate-$slots" $slots balanced validate 2>&1 | Tee-Object "$out/validate-$slots.txt"
    if($LASTEXITCODE -ne 0){throw "validation slots=$slots failed"}
}
if(!$SkipSanitizer){
    & compute-sanitizer --tool memcheck --leak-check full --error-exitcode 1 $exe $model $shader "$out/sanitizer" 3 balanced validate 2>&1 | Tee-Object "$out/memcheck.txt"
    if($LASTEXITCODE -ne 0){throw 'E.3 memcheck failed'}
}
if(!$ValidationOnly){
    # 三轮改变槽位运行顺序；每进程2次预热+5次测量，避免把固定启动顺序误当槽位收益。
    for($pass=0;$pass -lt 3;$pass++){
        foreach($workload in @('cuda-heavy','graphics-heavy','balanced')){
            for($i=0;$i -lt 3;$i++){
                $slots=1+(($i+$pass)%3)
                & $exe $model $shader "$out/perf-$workload-$slots-$pass" $slots $workload perf 2>&1 | Tee-Object "$out/perf-$workload-$slots-$pass.txt"
                if($LASTEXITCODE -ne 0){throw "benchmark $workload slots=$slots pass=$pass failed"}
            }
        }
    }
}
