$ErrorActionPreference='Stop'
$nsys='C:/Program Files/NVIDIA Corporation/Nsight Systems 2026.3.1/target-windows-x64/nsys.exe'
$out=Join-Path $PSScriptRoot 'results/e3'
$exe=Join-Path $PSScriptRoot 'build/Release/buffer_bench.exe'
$shader=Join-Path $PSScriptRoot 'shaders/instances.hlsl'
$model=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../gltf-scene/results/c04/trs.gltf'))
# CUDA+NVTX+DX12同一捕获时钟，batch GPU区间用于判断跨API重叠。计时结论另用无分析器运行。
# 不请求Compute硬件计数器，不改变用户驱动权限。
foreach($slots in @(1,2,3)){
    & $nsys profile --trace=cuda,nvtx,dx12 --dx12-gpu-workload=batch --dx12-wait-calls=true --sample=none --cpuctxsw=none --capture-range=cudaProfilerApi --capture-range-end=stop --force-overwrite=true --output="$out/nsys-$slots" $exe $model $shader "$out/profile-$slots" $slots balanced profile 2>&1 | Tee-Object "$out/nsys-$slots.txt"
    if($LASTEXITCODE -ne 0){throw "Nsight Systems slots=$slots failed"}
    & $nsys export --type=sqlite --force-overwrite=true --output="$out/nsys-$slots.sqlite" "$out/nsys-$slots.nsys-rep" 2>&1 | Tee-Object "$out/nsys-$slots-export.txt"
    if($LASTEXITCODE -ne 0){throw 'Nsight export failed'}
}
