$ErrorActionPreference='Stop'
# 结果路径按脚本定位；编译由共享入口初始化VS2022并指定sm_120。本程序执行CPU参考。
$out=Join-Path $PSScriptRoot 'results';New-Item -ItemType Directory -Force $out | Out-Null
Push-Location $PSScriptRoot
try {
 & "$PSScriptRoot/../../build.ps1" 'throughput_test.cu' -Arch sm_120 -NoRun 2>&1 | Tee-Object "$out/build.txt"
 if($LASTEXITCODE -ne 0){throw 'compile failed'}
 & "$PSScriptRoot/throughput_test.exe" $out 2>&1 | Tee-Object "$out/run.txt"
 if($LASTEXITCODE -ne 0){throw 'throughput test failed'}
} finally {Pop-Location}
