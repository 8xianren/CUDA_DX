$ErrorActionPreference='Stop'
$shared=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../gltf-scene'))
cmake -S $shared -B "$shared/build" -DH_CHARACTER=ON
if($LASTEXITCODE -ne 0){throw 'configure failed'}
cmake --build "$shared/build" --config Release --target h_controller_test h_input_test --parallel 8
if($LASTEXITCODE -ne 0){throw 'build failed'}
foreach($entry in @(@('h3','h_controller_test'),@('h4','h_input_test'))){
    $out=Join-Path $PSScriptRoot "results/$($entry[0])";New-Item -ItemType Directory -Force $out | Out-Null
    & "$PSScriptRoot/build/Release/$($entry[1]).exe" $out 2>&1 | Tee-Object "$out/run.txt"
    if($LASTEXITCODE -ne 0){throw "$($entry[0]) failed"}
}
