$ErrorActionPreference='Stop'
# 数学参考和白炉均在CPU执行。统一sm_120构建，不据此宣称已经运行GPU GGX。
$out=Join-Path $PSScriptRoot 'results/ggx'
New-Item -ItemType Directory -Force $out | Out-Null
Push-Location $PSScriptRoot
try {
    & "$PSScriptRoot/../../build.ps1" 'ggx_test.cu' -Arch sm_120 -NoRun 2>&1 | Tee-Object "$out/build.txt"
    if($LASTEXITCODE -ne 0){throw 'GGX compile failed'}
    & "$PSScriptRoot/ggx_test.exe" $out 2>&1 | Tee-Object "$out/run.txt"
    if($LASTEXITCODE -ne 0){throw 'GGX math/white furnace failed'}
} finally {Pop-Location}
