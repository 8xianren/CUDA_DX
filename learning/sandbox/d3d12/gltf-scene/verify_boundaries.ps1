# D.4边界验收：先检查构建依赖，再运行不依赖导入库的GPU测试及受影响课程回归。
$ErrorActionPreference='Stop'
$out=Join-Path $PSScriptRoot 'results/d04';New-Item -ItemType Directory -Force $out | Out-Null
# VS项目的Release链接依赖包含静态库传递闭包，因此比只搜索DLL导入表更适合检查静态Assimp。
[xml]$project=Get-Content "$PSScriptRoot/build/scene_boundary_test.vcxproj"
$ns=[Xml.XmlNamespaceManager]::new($project.NameTable);$ns.AddNamespace('m','http://schemas.microsoft.com/developer/msbuild/2003')
$deps=$project.SelectNodes('//m:Link/m:AdditionalDependencies',$ns) | ForEach-Object {$_.InnerText}
$deps | Set-Content "$out/boundary-link-dependencies.txt"
if(($deps -join ' ') -match 'assimp|scene_import'){throw 'boundary test unexpectedly links importer'}
if(($deps -join ' ') -notmatch 'scene_model.lib'){throw 'model library missing from link dependencies'}
& dxc -T lib_6_3 -HV 2021 -Fo "$out/material_rays.dxil" "$PSScriptRoot/shaders/material_rays.hlsl" 2>&1 | Tee-Object "$out/shader-build.txt"
if($LASTEXITCODE -ne 0){throw 'DXC failed'}
& "$PSScriptRoot/build/Release/scene_boundary_test.exe" "$out/material_rays.dxil" 2>&1 | Tee-Object "$out/boundary-gpu.txt"
if($LASTEXITCODE -ne 0){throw 'boundary GPU test failed'}
# 修改了共同编译单元，CPU布局/层级/材质/失败输入与D.1–D.3都属于本次回归范围。
foreach($name in @('verify_layout','verify_hierarchy','verify_material','verify_scope','verify_validation','verify_upload','verify_instances','verify_sampling')){
 & "$PSScriptRoot/$name.ps1" 2>&1 | Tee-Object "$out/$name.txt"
 if(-not $?){throw "$name failed"}
}
& python "$PSScriptRoot/preview_sampling.py" 2>&1 | Tee-Object "$out/preview.txt"
if($LASTEXITCODE -ne 0){throw 'preview conversion failed'}
& python "$PSScriptRoot/verify_official_orientation.py" 2>&1 | Tee-Object "$out/orientation.txt"
if($LASTEXITCODE -ne 0){throw 'official orientation regression failed'}
'PASS D.4: importer-free link closure; procedural scene; destroyed source CpuScene; invalid sampler rejection; C.3-C.6 and D.1-D.3 regression. Original per-lesson outputs remain in their own result folders; this folder contains D.4 run logs.' | Set-Content "$out/summary.txt"
