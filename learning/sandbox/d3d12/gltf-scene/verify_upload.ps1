# D.1固定资产生成+GPU验收；不解析任意glTF，解析始终交给Validator/Assimp。
$ErrorActionPreference='Stop'
$dir=Join-Path $PSScriptRoot 'results/d01'
New-Item -ItemType Directory -Force $dir | Out-Null
if(-not(Test-Path "$PSScriptRoot/results/c05/OPAQUE.gltf")){ & "$PSScriptRoot/verify_material.ps1" }
$utf8=[Text.UTF8Encoding]::new($false)
Copy-Item "$PSScriptRoot/results/c05/shared.png" "$dir/shared.png" -Force
# 两个primitive使用各自0/1/2局部索引，逼出“忘记BaseVertex/BLAS顶点地址偏移”的错误。
$stream=[IO.MemoryStream]::new();$writer=[IO.BinaryWriter]::new($stream)
try{
 foreach($position in @(@(0,0,0),@(1,0,0),@(0,1,0),@(2,0,0),@(3,0,0),@(2,1,0))) {
  foreach($v in $position){$writer.Write([single]$v)}
  $writer.Write([single]0.25);$writer.Write([single]0.25) # 固定UV采样PNG左上，便于独立颜色锚点验证。
 }
 foreach($v in @(0,1,2,0,1,2)){$writer.Write([uint16]$v)}
 $writer.Flush();$bytes=$stream.ToArray()
}finally{$writer.Dispose();$stream.Dispose()}
[IO.File]::WriteAllBytes("$dir/multi.bin",$bytes)
$asset=@{
 asset=@{version='2.0';generator='D.1 upload fixture'}
 scene=0;scenes=@(@{nodes=@(0)});nodes=@(@{mesh=0})
 buffers=@(@{uri='multi.bin';byteLength=132})
 bufferViews=@(@{buffer=0;byteOffset=0;byteLength=120;byteStride=20;target=34962},@{buffer=0;byteOffset=120;byteLength=12;target=34963})
 accessors=@(
  @{bufferView=0;byteOffset=0;componentType=5126;count=3;type='VEC3';min=@(0,0,0);max=@(1,1,0)},
  @{bufferView=0;byteOffset=12;componentType=5126;count=3;type='VEC2'},
  @{bufferView=1;byteOffset=0;componentType=5123;count=3;type='SCALAR'},
  @{bufferView=0;byteOffset=60;componentType=5126;count=3;type='VEC3';min=@(2,0,0);max=@(3,1,0)},
  @{bufferView=0;byteOffset=72;componentType=5126;count=3;type='VEC2'},
  @{bufferView=1;byteOffset=6;componentType=5123;count=3;type='SCALAR'})
 meshes=@(@{primitives=@(@{attributes=@{POSITION=0;TEXCOORD_0=1};indices=2;material=0},@{attributes=@{POSITION=3;TEXCOORD_0=4};indices=5;material=1})})
 images=@(@{uri='shared.png'});textures=@(@{source=0})
 materials=@(@{pbrMetallicRoughness=@{baseColorTexture=@{index=0};baseColorFactor=@(1,1,1,1)}},@{pbrMetallicRoughness=@{baseColorTexture=@{index=0};baseColorFactor=@(.25,1,.25,1)}})
}
[IO.File]::WriteAllText("$dir/multi.gltf",($asset|ConvertTo-Json -Depth 30),$utf8)
$cases=@(
 @{name='defaults';input="$PSScriptRoot/results/c05/defaults.gltf"},
 @{name='textured';input="$PSScriptRoot/results/c05/OPAQUE.gltf"},
 @{name='multi';input="$dir/multi.gltf"})
foreach($case in $cases) {
 $out=Join-Path $dir $case.name;New-Item -ItemType Directory -Force $out | Out-Null
 & node "$PSScriptRoot/validation/validate_import.cjs" $case.input "$out/validation.json" 2>&1 | Tee-Object "$out/validation.txt"
 if($LASTEXITCODE -ne 0){throw "source validation failed: $($case.name)"}
 & "$PSScriptRoot/build/Release/gpu_upload_test.exe" $case.input "$PSScriptRoot/shaders/upload_preview.hlsl" $out 2>&1 | Tee-Object "$out/gpu.txt"
 if($LASTEXITCODE -ne 0){throw "GPU failed: $($case.name)"}
}
# CPU独立锚点：已知PNG编码值，先sRGB解码，乘线性材质因子，再编码。
function Decode([double]$x) {if($x -le .04045){return $x/12.92};return [Math]::Pow(($x+.055)/1.055,2.4)}
function Encode([double]$x) {if($x -le .0031308){return 12.92*$x};return 1.055*[Math]::Pow($x,1/2.4)-.055}
Add-Type -AssemblyName System.Drawing
$bitmap=[Drawing.Bitmap]::new("$dir/multi/preview.bmp")
try {
 foreach($test in @(@{x=45;factor=@(1,1,1)},@{x=180;factor=@(.25,1,.25)})) {
  $color=$bitmap.GetPixel($test.x,140);$actual=@($color.R,$color.G,$color.B);$encoded=@(128,64,192)
  for($k=0;$k -lt 3;$k++){
   $expected=[Math]::Round(255*(Encode ((Decode ($encoded[$k]/255.0))*$test.factor[$k])))
   if([Math]::Abs($actual[$k]-$expected) -gt 1){throw "pixel mismatch x=$($test.x) channel=$k actual=$($actual[$k]) expected=$expected"}
  }
 }
 # 保存PNG仅作预览格式转换；图像来源仍是GPU读回。
 $bitmap.Save("$dir/multi/preview.png",[Drawing.Imaging.ImageFormat]::Png)
}finally{$bitmap.Dispose()}
'PASS 3 GPU cases; buffer/texture exact readback; BLAS builds; 2-primitive local indices and material/sRGB pixel anchors <=1 code; Debug/GPU validation clean.' | Set-Content "$dir/summary.txt"
Get-Content "$dir/summary.txt"
