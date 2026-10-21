param([switch]$FetchAssets)
$ErrorActionPreference='Stop'
if($FetchAssets){ & "$PSScriptRoot/fetch_assets.ps1" }
$out=Join-Path $PSScriptRoot 'results/h1'
$shared=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../gltf-scene'))
New-Item -ItemType Directory -Force $out | Out-Null
cmake -S $shared -B "$shared/build" -DH_CHARACTER=ON 2>&1 | Tee-Object "$out/configure.txt"
if($LASTEXITCODE -ne 0){throw 'configure failed'}
cmake --build "$shared/build" --config Release --target h_asset_probe import_scope_test --parallel 8 2>&1 | Tee-Object "$out/build.txt"
if($LASTEXITCODE -ne 0){throw 'build failed'}
& "$PSScriptRoot/build/Release/h_asset_probe.exe" "$PSScriptRoot/assets/runtime/character/character.gltf" "$PSScriptRoot/assets/runtime/animation.glb" $out 2>&1 | Tee-Object "$out/run.txt"
if($LASTEXITCODE -ne 0){throw 'asset probe failed'}
python "$PSScriptRoot/audit_gltf.py" 2>&1 | Tee-Object "$out/independent.txt"
if($LASTEXITCODE -ne 0){throw 'independent audit failed'}
# 明确检查失败路径：丢失文件必须返回非零，不能输出半构造场景。
& "$PSScriptRoot/build/Release/h_asset_probe.exe" "$out/missing.gltf" "$PSScriptRoot/assets/runtime/animation.glb" $out 2>&1 | Out-File "$out/missing-input.txt"
if($LASTEXITCODE -eq 0){throw 'missing input incorrectly accepted'}
& "$shared/build/Release/import_scope_test.exe" "$PSScriptRoot/assets/runtime/nature/rock_largeA.glb" 2>&1 | Tee-Object "$out/static-regression.txt"
if($LASTEXITCODE -ne 0){throw 'static import regression'}
& "$shared/build/Release/import_scope_test.exe" "$PSScriptRoot/assets/runtime/animation.glb" 2>&1 | Out-File "$out/static-reject-animation.txt"
if($LASTEXITCODE -eq 0){throw 'static importer silently accepted animation'}
Write-Output 'PASS H1 assets, independent bind equation, missing-input and static import boundaries'
# 最后一项故意要求原生程序失败；清除其退出码，避免上层把通过的负对照当成脚本失败。
$global:LASTEXITCODE=0
