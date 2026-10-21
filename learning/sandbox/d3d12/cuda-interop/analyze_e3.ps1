$ErrorActionPreference='Stop'
$python=Join-Path $PSScriptRoot 'build/analysis-env/Scripts/python.exe'
if(-not(Test-Path $python)){
    & python -m venv "$PSScriptRoot/build/analysis-env"
    if($LASTEXITCODE -ne 0){throw 'analysis venv failed'}
}
& $python -c 'import matplotlib' 2>$null
if($LASTEXITCODE -ne 0){
    & $python -m pip install matplotlib==3.10.7
    if($LASTEXITCODE -ne 0){throw 'plot dependencies failed'}
}
& $python "$PSScriptRoot/analyze_e3.py" 2>&1 | Tee-Object "$PSScriptRoot/results/e3/analysis.txt"
if($LASTEXITCODE -ne 0){throw 'E.3 analysis failed'}
& $python -m pip freeze | Set-Content "$PSScriptRoot/results/e3/analysis-packages.txt"
