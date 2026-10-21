$ErrorActionPreference='Stop'
$dir=Join-Path $PSScriptRoot 'results/d02'
New-Item -ItemType Directory -Force $dir | Out-Null
if(-not(Test-Path "$PSScriptRoot/results/c04/trs.gltf")){ & "$PSScriptRoot/verify_hierarchy.ps1" }
if(-not(Test-Path "$PSScriptRoot/validation/node_modules/gltf-validator")){
 & npm ci --prefix "$PSScriptRoot/validation" --ignore-scripts --no-audit --no-fund
 if($LASTEXITCODE -ne 0){throw 'validator installation failed'}
}
& node "$PSScriptRoot/validation/validate_import.cjs" "$PSScriptRoot/results/c04/trs.gltf" "$dir/validation.json" 2>&1 | Tee-Object "$dir/validation.txt"
if($LASTEXITCODE -ne 0){throw 'C.6 source validation failed'}
# DXR shader采用现成DXC。光栅VS/PS在C++中由系统D3DCompiler编译，运行日志包含失败详情。
& dxc -T lib_6_3 -HV 2021 -Fo "$dir/instance_rays.dxil" "$PSScriptRoot/shaders/instance_rays.hlsl" 2>&1 | Tee-Object "$dir/shader-build.txt"
if($LASTEXITCODE -ne 0){throw 'DXR shader compilation failed'}
& "$PSScriptRoot/build/Release/instance_test.exe" "$PSScriptRoot/results/c04/trs.gltf" "$PSScriptRoot/shaders/instance_raster.hlsl" "$dir/instance_rays.dxil" $dir 2>&1 | Tee-Object "$dir/gpu.txt"
if($LASTEXITCODE -ne 0){throw 'D.2 GPU validation failed'}
Add-Type -AssemblyName System.Drawing
foreach($name in @('base','parent-moved','masked','camera-pan')){
 $bitmap=[Drawing.Bitmap]::new("$dir/$name-ray.bmp")
 try{$bitmap.Save("$dir/$name-ray.png",[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
}
'PASS: four stages CPU/raster/DXR identity comparison, shared BLAS/VB/IB, parent movement, mask, camera pan, singular rejection; see gpu.txt for edge exclusions and exact counts.' | Set-Content "$dir/summary.txt"
