# C.6异常样本只写results/c06，不修改历史课程资产。独立进程区分正常拒绝与崩溃。
$ErrorActionPreference='Stop'
$dir=Join-Path $PSScriptRoot 'results/c06'
New-Item -ItemType Directory -Force $dir | Out-Null
$utf8=[Text.UTF8Encoding]::new($false)
if(-not(Test-Path "$PSScriptRoot/results/c03/u16.gltf")){ & "$PSScriptRoot/verify_layout.ps1" }
$source=Get-Content "$PSScriptRoot/results/c03/u16.gltf" -Raw
Copy-Item "$PSScriptRoot/results/c03/u16.bin" "$dir/u16.bin" -Force
$exe=Join-Path $PSScriptRoot 'build/Release/import_scope_test.exe'
$rows=@()
function Invoke-Case([string]$name,[string]$file,[string]$expected) {
 $start=[Diagnostics.ProcessStartInfo]::new($exe)
 $start.Arguments='"'+$file+'"';$start.UseShellExecute=$false;$start.CreateNoWindow=$true
 $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $p=[Diagnostics.Process]::Start($start)
 $o=$p.StandardOutput.ReadToEndAsync();$e=$p.StandardError.ReadToEndAsync()
 if(-not $p.WaitForExit(30000)){$p.Kill();throw "$name timed out"}
 $code=$p.ExitCode;$text=$o.Result+$e.Result;$p.Dispose()
 [IO.File]::WriteAllText("$dir/$name.txt","exit=$code`n$text",$utf8)
 # observe只用于明确暴露库验证能力的边界，不把接受畸形输入记成有效资产PASS。
 if($expected -eq 'accept'){if($code -ne 0){throw "$name unexpected failure: $text"}}
 elseif($expected -eq 'observe'){if($code -notin @(0,1)){throw "$name crashed: $code"}}
 elseif($code -ne 1 -or $text -notmatch $expected){throw "$name wrong failure: $code $text"}
 return "$name : exit=$code expectation=$expected"
}
foreach($kind in @('valid','bounds','component','misaligned','unknown-required','morph','animation','factor','depth')) {
 $a=$source|ConvertFrom-Json -AsHashtable
 $expected='accept'
 switch($kind) {
  'bounds' {$a.accessors[0].count=100000;$expected='\[read\]'}
  'component' {$a.accessors[4].componentType=9999;$expected='\[read\]'}
  'misaligned' {$a.accessors[0].byteOffset=1;$expected='observe'}
  'unknown-required' {$a.extensionsUsed=@('EXT_course_unknown');$a.extensionsRequired=@('EXT_course_unknown');$expected='observe'}
  'morph' {$a.meshes[0].primitives[0].targets=@(@{POSITION=0});$expected='unsupported morph'}
  'factor' {$a.materials=@(@{pbrMetallicRoughness=@{metallicFactor=2}});$a.meshes[0].primitives[0].material=0;$expected='outside'}
  'depth' {
   $a.nodes=@();for($i=0;$i -lt 140;$i++){if($i -lt 139){$a.nodes+=@{children=@($i+1)}}else{$a.nodes+=@{mesh=0}}}
   $expected='depth exceeds'
  }
  'animation' {
   # 向原buffer追加对齐的两个时间与两次平移，由库真正解析动画，不伪造aiScene。
   $ms=[IO.MemoryStream]::new();$w=[IO.BinaryWriter]::new($ms)
   try {
    $w.Write([IO.File]::ReadAllBytes("$dir/u16.bin"))
    while($ms.Position%4){$w.Write([byte]0)}
    $offset=[int]$ms.Position
    foreach($x in @(0,1, 0,0,0, 1,0,0)){$w.Write([single]$x)}
    $w.Flush();$bytes=$ms.ToArray()
   }finally{$w.Dispose();$ms.Dispose()}
   [IO.File]::WriteAllBytes("$dir/animation.bin",$bytes)
   $a.buffers[0].uri='animation.bin';$a.buffers[0].byteLength=$bytes.Length
   $a.bufferViews+=@{buffer=0;byteOffset=$offset;byteLength=8}
   $a.bufferViews+=@{buffer=0;byteOffset=($offset+8);byteLength=24}
   $a.accessors+=@{bufferView=2;componentType=5126;type='SCALAR';count=2;min=@(0);max=@(1)}
   $a.accessors+=@{bufferView=3;componentType=5126;type='VEC3';count=2}
   $a.animations=@(@{samplers=@(@{input=5;output=6;interpolation='LINEAR'});channels=@(@{sampler=0;target=@{node=0;path='translation'}})})
   $expected='unsupported animation'
  }
 }
 $file="$dir/$kind.gltf"
 [IO.File]::WriteAllText($file,($a|ConvertTo-Json -Depth 50),$utf8)
 $rows+=Invoke-Case $kind $file $expected
}
[IO.File]::WriteAllText("$dir/broken.gltf",'{not json',$utf8)
$rows+=Invoke-Case 'broken' "$dir/broken.gltf" '\[read\]'
$rows+=Invoke-Case 'camera-notice' "$PSScriptRoot/assets/c01-shared-mesh.gltf" 'accept'
$rows|Set-Content "$dir/summary.txt"
$rows
