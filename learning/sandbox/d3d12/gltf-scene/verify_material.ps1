$ErrorActionPreference='Stop'
$dir=Join-Path $PSScriptRoot 'results/c05'
New-Item -ItemType Directory -Force $dir | Out-Null
$utf8=[Text.UTF8Encoding]::new($false)
# 复用C.3的有UV三角形，不复制整套几何实现。缺少样本时按原脚本生成。
if(-not(Test-Path "$PSScriptRoot/results/c03/u16.gltf")){ & "$PSScriptRoot/verify_layout.ps1" }
$source=Get-Content "$PSScriptRoot/results/c03/u16.gltf" -Raw
Copy-Item "$PSScriptRoot/results/c03/u16.bin" "$dir/u16.bin" -Force
# 用系统图像编码器生成2x2测试PNG；不手写PNG解析器。D阶段才解码和验证像素方向。
Add-Type -AssemblyName System.Drawing
$bitmap=[Drawing.Bitmap]::new(2,2)
try {
 $bitmap.SetPixel(0,0,[Drawing.Color]::FromArgb(128,128,64,192))
 $bitmap.SetPixel(1,0,[Drawing.Color]::Red)
 $bitmap.SetPixel(0,1,[Drawing.Color]::Green)
 $bitmap.SetPixel(1,1,[Drawing.Color]::Blue)
 $bitmap.Save("$dir/shared.png",[Drawing.Imaging.ImageFormat]::Png)
}finally{$bitmap.Dispose()}
$png=[IO.File]::ReadAllBytes("$dir/shared.png")
$exe=Join-Path $PSScriptRoot 'build/Release/material_test.exe'
foreach($kind in @('defaults','OPAQUE','MASK','BLEND','embedded','missing')) {
 $asset=$source|ConvertFrom-Json -AsHashtable
 $asset.meshes[0].primitives[0].material=0
 $asset.materials=@(@{})
 $mode=$kind
 if($kind -ne 'defaults') {
  $mode=if($kind -in @('embedded','missing')){'OPAQUE'}else{$kind}
  $asset.materials=@(@{name='CorePBR';pbrMetallicRoughness=@{baseColorFactor=@(.8,.4,.2,.6);metallicFactor=.7;roughnessFactor=.3;baseColorTexture=@{index=0};metallicRoughnessTexture=@{index=0}};normalTexture=@{index=0;scale=.5};occlusionTexture=@{index=0;strength=.4};emissiveTexture=@{index=0};emissiveFactor=@(.1,.2,.3);alphaMode=$mode;alphaCutoff=.45;doubleSided=$true})
  $uri=if($kind -eq 'embedded'){'data:image/png;base64,'+[Convert]::ToBase64String($png)}elseif($kind -eq 'missing'){'intentionally-missing.png'}else{'shared.png'}
  $asset.images=@(@{uri=$uri})
  $asset.textures=@(@{source=0;sampler=0})
  $asset.samplers=@(@{wrapS=33071;wrapT=33648;minFilter=9987;magFilter=9729})
 }
 [IO.File]::WriteAllText("$dir/$kind.gltf",($asset|ConvertTo-Json -Depth 30),$utf8)
 # Process异步读取两条流，预期失败的stderr也能正常保存，不触发PowerShell错误升级。
 $start=[Diagnostics.ProcessStartInfo]::new($exe)
 $start.Arguments='"'+"$dir/$kind.gltf"+'" '+$mode
 $start.UseShellExecute=$false;$start.CreateNoWindow=$true
 $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $proc=[Diagnostics.Process]::Start($start)
 $stdout=$proc.StandardOutput.ReadToEndAsync();$stderr=$proc.StandardError.ReadToEndAsync()
 if(-not $proc.WaitForExit(30000)){$proc.Kill();throw 'material test timeout'}
 $code=$proc.ExitCode;$log=$stdout.Result+$stderr.Result;$proc.Dispose()
 [IO.File]::WriteAllText("$dir/$kind.txt","exit=$code`n$log",$utf8)
 if($kind -eq 'missing') {
  if($code -ne 1 -or $log -notmatch 'missing referenced image'){throw "expected image failure: $log"}
 }elseif($code -ne 0){throw "$kind failed: $log"}
 Write-Output "$kind : exit=$code $log"
}
'PASS: defaults, OPAQUE/MASK/BLEND metadata, shared external PNG, embedded PNG bytes, sampler and missing image rejection. CPU only; encoded bytes not pixel data.'|Set-Content "$dir/summary.txt"
