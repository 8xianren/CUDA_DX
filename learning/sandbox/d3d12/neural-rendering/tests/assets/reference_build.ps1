param([switch]$NoRun)
$ErrorActionPreference='Stop'
$course=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build=Join-Path $course 'build/reference'
New-Item -ItemType Directory -Force $build | Out-Null
$library=Join-Path $course 'build/Release/g_gaussian.lib'
if(-not (Test-Path -LiteralPath $library)){throw '请先构建本课共享g_gaussian库'}
$vcvars='C:/Program Files/Microsoft Visual Studio/2022/Community/VC/Auxiliary/Build/vcvars64.bat'
$source=Join-Path $PSScriptRoot 'reference_render.cpp'
$command='"'+$vcvars+'" >nul && nvcc -arch=sm_120 -std=c++17 -O2 -Xcompiler /MD -Xcompiler /utf-8 -Xcompiler /Zc:preprocessor "'+$source+'" "'+$library+'" -o "'+$build+'/reference_render.exe"'
Push-Location $build
try {cmd /c $command; if($LASTEXITCODE -ne 0){throw 'Reference preview build failed'}} finally {Pop-Location}
if(-not $NoRun){& "$build/reference_render.exe" $course; if($LASTEXITCODE -ne 0){throw 'Reference preview render failed'}}
