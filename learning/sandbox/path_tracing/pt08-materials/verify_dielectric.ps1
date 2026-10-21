$ErrorActionPreference='Stop'
# 仅CPU界面采样验证；统一nvcc/sm_120构建，不代表GPU执行。
$out=Join-Path $PSScriptRoot 'results/dielectric';New-Item -ItemType Directory -Force $out | Out-Null
Push-Location $PSScriptRoot
try {
 & "$PSScriptRoot/../../build.ps1" 'dielectric_test.cu' -Arch sm_120 -NoRun 2>&1 | Tee-Object "$out/build.txt"
 if($LASTEXITCODE -ne 0){throw 'compile failed'}
 & "$PSScriptRoot/dielectric_test.exe" $out 2>&1 | Tee-Object "$out/run.txt"
 if($LASTEXITCODE -ne 0){throw 'dielectric failed'}
} finally {Pop-Location}
