param([ValidateSet('Systems','Compute','All')][string]$Tool='Systems')
$ErrorActionPreference='Stop'
$nsys='C:/Program Files/NVIDIA Corporation/Nsight Systems 2026.3.1/target-windows-x64/nsys.exe'
$ncu='C:/Program Files/NVIDIA Corporation/Nsight Compute 2026.2.0/ncu.bat'
$out=Join-Path $PSScriptRoot 'results/execution'
$exe=Join-Path $PSScriptRoot 'execution_bench.exe'
$mesh=Join-Path $PSScriptRoot 'results/bvh/gallery.meshbin'
if(-not (Test-Path $exe)){throw 'Run verify_execution.ps1 first to build and validate the program'}
# 只分析此课程子进程的cudaProfilerStart/Stop范围；不修改驱动权限、时钟或全局设置。
# Compute若返回ERR_NVGPUCTRPERM，需要用户在管理员终端运行本脚本，或通过NVIDIA App授予访问。
foreach($backend in @('pixel','sample','wave')){
    if($Tool -in @('Systems','All')){
        & $nsys profile --trace=cuda --sample=none --cpuctxsw=none --capture-range=cudaProfilerApi --capture-range-end=stop --force-overwrite=true --output="$out/nsys-$backend" $exe $mesh "$out/nsys-$backend-run" gallery profile $backend 2>&1 | Tee-Object "$out/nsys-$backend.txt"
        if($LASTEXITCODE -ne 0){throw "Nsight Systems $backend failed"}
        & $nsys export --type=sqlite --force-overwrite=true --output="$out/nsys-$backend.sqlite" "$out/nsys-$backend.nsys-rep" 2>&1 | Tee-Object "$out/nsys-$backend-export.txt"
        if($LASTEXITCODE -ne 0){throw "Nsight Systems export $backend failed"}
    }
    if($Tool -in @('Compute','All')){
        & $ncu --profile-from-start off --set full --force-overwrite --export "$out/ncu-$backend" $exe $mesh "$out/ncu-$backend-run" gallery profile $backend 2>&1 | Tee-Object "$out/ncu-$backend.txt"
        if($LASTEXITCODE -ne 0){throw "Nsight Compute $backend failed; inspect the log for ERR_NVGPUCTRPERM or collection errors"}
        & $ncu --import "$out/ncu-$backend.ncu-rep" --page raw --csv --log-file "$out/ncu-$backend-raw.csv"
        if($LASTEXITCODE -ne 0){throw "Nsight Compute export $backend failed"}
    }
}
