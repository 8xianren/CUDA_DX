param([switch]$Run)
$ErrorActionPreference = 'Stop'
# F.9 与 F.7/F.8 共用固定版本 SDK；第三方 DLL/头文件只放被忽略的 build/deps。
$source = Join-Path $PSScriptRoot 'build/deps/fidelityfx-source'
$candidates = @(Get-ChildItem -LiteralPath $source -Directory -ErrorAction SilentlyContinue)
if (Test-Path (Join-Path $source 'Kits/FidelityFX/api/include/ffx_api.h')) { $sdk = $source }
else { $sdk = ($candidates | Where-Object { Test-Path (Join-Path $_.FullName 'Kits/FidelityFX/api/include/ffx_api.h') } | Select-Object -First 1).FullName }
if (!$sdk) { throw '请先运行本课 fetch_sdks.ps1，恢复 FidelityFX SDK 源码头文件。' }
$build = Join-Path $PSScriptRoot 'build/framegen'
cmake -S (Join-Path $PSScriptRoot 'framegen') -B $build -A x64 "-DFFX_ROOT=$sdk"
if ($LASTEXITCODE -ne 0) { throw 'F.9 CMake 配置失败' }
cmake --build $build --config Release --parallel 4
if ($LASTEXITCODE -ne 0) { throw 'F.9 编译失败' }
$bin = Join-Path $build 'Release'
$dllRoot = Join-Path $PSScriptRoot 'build/deps/fidelityfx/Samples/Upscalers/FidelityFX_FSR/dx12/x64/Release'
foreach ($name in @('amd_fidelityfx_loader_dx12.dll','amd_fidelityfx_framegeneration_dx12.dll')) {
    Copy-Item -LiteralPath (Join-Path $dllRoot $name) -Destination $bin -Force
}
if ($Run) {
    python (Join-Path $PSScriptRoot 'verify_framegen.py')
    if ($LASTEXITCODE -ne 0) { throw 'F.9 帧生成验收失败' }
}
