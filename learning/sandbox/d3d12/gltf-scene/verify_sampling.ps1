# D.3的固定诊断资产与官方样例；解析仍走Validator/Assimp，脚本只生成已知测试输入。
$ErrorActionPreference='Stop'
$dir=Join-Path $PSScriptRoot 'results/d03'
New-Item -ItemType Directory -Force $dir | Out-Null
if(-not(Test-Path "$PSScriptRoot/results/d01/multi.gltf")){ & "$PSScriptRoot/verify_upload.ps1" }
$asset=Get-Content "$PSScriptRoot/results/d01/multi.gltf" -Raw | ConvertFrom-Json -AsHashtable
$bytes=[IO.File]::ReadAllBytes("$PSScriptRoot/results/d01/multi.bin")
$uv=@(@(-.75,-.75),@(2.25,-.75),@(-.75,2.25))
for($i=0;$i -lt 6;$i++){for($k=0;$k -lt 2;$k++){
 [BitConverter]::GetBytes([single]$uv[$i%3][$k]).CopyTo($bytes,$i*20+12+$k*4)
}}
[IO.File]::WriteAllBytes("$dir/multi.bin",$bytes)
Copy-Item "$PSScriptRoot/results/d01/shared.png" "$dir/shared.png" -Force
$asset.asset.generator='D.3 sampler fixture'
$asset.materials[0].pbrMetallicRoughness.baseColorFactor=@(1,1,1,.75)
$asset | ConvertTo-Json -Depth 30 | Set-Content -Encoding utf8 "$dir/multi.gltf"
# 固定上游提交，保存license/来源和文件hash。缓存只属于课程结果，不全局安装资产。
$commit='15cd02d304e54cb42a4db4eefe719f76190f4b68'
$base="https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Assets/$commit/Models/BoxTextured"
$official=Join-Path $dir 'BoxTextured';New-Item -ItemType Directory -Force $official | Out-Null
foreach($name in @('BoxTextured.gltf','BoxTextured0.bin','CesiumLogoFlat.png')){
 if(-not(Test-Path "$official/$name")){Invoke-WebRequest "$base/glTF/$name" -OutFile "$official/$name"}
}
if(-not(Test-Path "$official/LICENSE.md")){Invoke-WebRequest "$base/LICENSE.md" -OutFile "$official/LICENSE.md"}
"Source: $base`nCommit: $commit" | Set-Content "$official/source.txt"
Get-FileHash "$official/BoxTextured.gltf","$official/BoxTextured0.bin","$official/CesiumLogoFlat.png" | Format-Table -AutoSize | Out-String -Width 250 | Set-Content "$official/sha256.txt"
& dxc -T lib_6_3 -HV 2021 -Fo "$dir/material_rays.dxil" "$PSScriptRoot/shaders/material_rays.hlsl" 2>&1 | Tee-Object "$dir/shader-build.txt"
if($LASTEXITCODE -ne 0){throw 'D.3 shader compilation failed'}
foreach($case in @(@{name='fixture';path="$dir/multi.gltf"},@{name='official';path="$official/BoxTextured.gltf"})){
 $out=Join-Path $dir $case.name;New-Item -ItemType Directory -Force $out | Out-Null
 & node "$PSScriptRoot/validation/validate_import.cjs" $case.path "$out/validation.json" 2>&1 | Tee-Object "$out/validation.txt"
 if($LASTEXITCODE -ne 0){throw 'source validation failed'}
 & "$PSScriptRoot/build/Release/material_sampling_test.exe" $case.path "$dir/material_rays.dxil" $out $case.name 2>&1 | Tee-Object "$out/gpu.txt"
 if($LASTEXITCODE -ne 0){throw "D.3 $($case.name) failed"}
}
'PASS D.3: fixture and official BoxTextured, each 3 address modes x 2 filters; ClosestHit RGBA vs independent CPU reference. See per-case GPU logs.' | Set-Content "$dir/summary.txt"
