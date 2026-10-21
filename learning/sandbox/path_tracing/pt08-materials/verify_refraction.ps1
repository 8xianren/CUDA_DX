$ErrorActionPreference='Stop'
# 本节仅CPU方向数学；复用统一编译环境，不把sm_120编译说成GPU运行。
$out=Join-Path $PSScriptRoot 'results/refraction';New-Item -ItemType Directory -Force $out | Out-Null
Push-Location $PSScriptRoot
try {
 & "$PSScriptRoot/../../build.ps1" 'refraction_test.cu' -Arch sm_120 -NoRun 2>&1 | Tee-Object "$out/build.txt"
 if($LASTEXITCODE -ne 0){throw 'compile failed'}
 & "$PSScriptRoot/refraction_test.exe" $out 2>&1 | Tee-Object "$out/run.txt"
 if($LASTEXITCODE -ne 0){throw 'refraction math failed'}
} finally {Pop-Location}
