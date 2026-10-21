# 目录迁移回归：每个课程组选择代表程序重编译；覆盖所有有相对资源依赖的入口。
# 不调用硬件性能计数器，不重跑历史长基准。脚本可从任意工作目录启动。
param()
$ErrorActionPreference = 'Stop'
$sandboxRoot = (Resolve-Path -LiteralPath "$PSScriptRoot/../sandbox").Path
$summary = [Collections.Generic.List[object]]::new()
$cases = @(
    @{Source='cuda/00-01-foundations/hello.cu'},
    @{Source='cuda/02-parallel-algorithms/parallel_reduce.cu'},
    @{Source='cuda/03-streams-profiling/async_timing.cu'},
    @{Source='cuda/04-custom-kernels/block_reduce_demo.cu'},
    @{Source='cuda/05-advanced-execution/cuda_graphs.cu'},
    @{Source='cuda/06-memory-access/texture_demo.cu'},
    @{Source='cuda/07-performance/divergence.cu'},
    @{Source='cuda/08-02-grid-sync/grid_sync.cu'},
    @{Source='cuda/08-05-blackwell/tma_2d_tile.cu'},
    @{Source='cuda/09-01-libraries/cublas_sgemm.cu';Libraries=@('cublas')},
    @{Source='cuda/09-01-libraries/cublaslt_relu.cu';Libraries=@('cublasLt')},
    @{Source='cuda/09-01-libraries/cufft_frequency.cu';Libraries=@('cufft')},
    @{Source='cuda/09-03-debugging/compute_sanitizer_demo.cu';Arguments=@('fixed')},
    @{Source='cuda/09-03-debugging/sanitizer_tools_demo.cu';Arguments=@('memcheck','fixed')},
    @{Source='cuda/09-03-debugging/device_assert_demo.cu';Arguments=@('fixed')},
    @{Source='cuda/09-04-numerics/mixed_precision_dot.cu'},
    @{Source='particles/09-02-interop/d3d12_cuda_luid.cu'},
    @{Source='particles/09-02-interop/d3d12_cuda_external_memory.cu'},
    @{Source='particles/09-02-interop/d3d12_cuda_external_semaphore.cu'},
    @{Source='particles/09-02-interop/d3d12_cuda_external_texture.cu'},
    @{Source='particles/p02-headless/d3d12_cuda_particles_headless.cu'},
    @{Source='particles/p03-simulation/particle_integrators.cu'},
    @{Source='particles/p03-simulation/particle_fixed_timestep.cu'},
    @{Source='particles/p03-simulation/particle_layout_benchmark.cu';Arguments=@('--verify-only')},
    @{Source='particles/p04-p05-renderer/d3d12_static_particles.cu';Arguments=@('--frames','12')},
    @{Source='particles/p04-p05-renderer/d3d12_cuda_particles.cu';Arguments=@('--frames','12','--vsync','0','--fixed-substeps','2')},
    @{Source='particles/p04-p05-renderer/d3d12_cuda_particles_double_buffered.cu';Arguments=@('--frames','12','--vsync','0','--fixed-substeps','2')}
)
foreach ($case in $cases) {
    $source = Join-Path $sandboxRoot $case.Source
    $directory = Split-Path -Parent $source
    $stem = [IO.Path]::GetFileNameWithoutExtension($source)
    $result = Join-Path $directory 'results/organization-check'
    New-Item -ItemType Directory -Path $result -Force | Out-Null
    $libraries = @($case.Libraries | Where-Object { $_ })
    if ($stem.StartsWith('d3d12_')) { $libraries = @('d3d12','dxgi','d3dcompiler','user32') }
    Write-Output "build/run $($case.Source)"
    & "$sandboxRoot/build.ps1" $source -Libraries $libraries -NoRun *> "$result/$stem-build.txt"
    if ($LASTEXITCODE -ne 0) { throw "编译失败：$source；参见 $result/$stem-build.txt" }
    $executable = [IO.Path]::ChangeExtension($source,'.exe')
    $arguments = @($case.Arguments | Where-Object { $_ })
    & $executable @arguments *> "$result/$stem-run.txt"
    if ($LASTEXITCODE -ne 0) { throw "运行失败：$source；参见 $result/$stem-run.txt" }
    $summary.Add([pscustomobject]@{source=$case.Source;status='pass';log="$result/$stem-run.txt"})
}
foreach ($special in @('cuda/08-03-04-driver/build.ps1','cuda/05-advanced-execution/build_dynamic.ps1')) {
    $script = Join-Path $sandboxRoot $special
    $result = Join-Path (Split-Path -Parent $script) 'results/organization-check'
    New-Item -ItemType Directory -Path $result -Force | Out-Null
    Write-Output "build/run $special"
    & $script *> "$result/special-build-run.txt"
    if ($LASTEXITCODE -ne 0) { throw "特殊构建失败：$script" }
    $summary.Add([pscustomobject]@{source=$special;status='pass';log="$result/special-build-run.txt"})
}
# Python 的 GPU 包兼容性不由迁移改变；这里只跑无外部依赖的布局示意和环境探针。
foreach ($relative in @('cuda/06-memory-access/swizzle_layout.py','cuda/06-memory-access/gob_swizzle.py','cuda/python-ecosystem/cudf_status.py')) {
    $script = Join-Path $sandboxRoot $relative
    $result = Join-Path (Split-Path -Parent $script) 'results/organization-check'
    New-Item -ItemType Directory -Path $result -Force | Out-Null
    $stem = [IO.Path]::GetFileNameWithoutExtension($script)
    & python $script *> "$result/$stem-run.txt"
    if ($LASTEXITCODE -ne 0) { throw "Python 探针失败：$script" }
    $summary.Add([pscustomobject]@{source=$relative;status='pass';log="$result/$stem-run.txt"})
}
$summaryDirectory = Join-Path $sandboxRoot 'cuda/results/organization-check'
New-Item -ItemType Directory -Path $summaryDirectory -Force | Out-Null
$summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$summaryDirectory/summary.json" -Encoding UTF8
Write-Output "PASS: $($summary.Count) build/run cases; detailed logs are in each lesson's results/organization-check."
