param([switch]$NoRun)
$ErrorActionPreference='Stop'
$course = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build = Join-Path $course 'build/gaussian'
New-Item -ItemType Directory -Force $build | Out-Null
$vcvars='C:/Program Files/Microsoft Visual Studio/2022/Community/VC/Auxiliary/Build/vcvars64.bat'
$sources=@("$course/src/gaussian/gaussian.cu","$course/src/gaussian/gaussian_cpu.cpp","$PSScriptRoot/verify_gaussian.cpp")
$quoted=($sources | ForEach-Object {'"'+$_+'"'}) -join ' '
$command='"'+$vcvars+'" >nul && nvcc -arch=sm_120 -std=c++17 -O2 --extended-lambda -Xcompiler /utf-8 -Xcompiler /Zc:preprocessor '+$quoted+' -o "'+$build+'/verify_gaussian.exe"'
Push-Location $build
try { cmd /c $command; if($LASTEXITCODE -ne 0){throw 'Gaussian build failed'} } finally { Pop-Location }
if(-not $NoRun){& "$build/verify_gaussian.exe" "$course/results";if($LASTEXITCODE -ne 0){throw 'Gaussian validation failed'}}
