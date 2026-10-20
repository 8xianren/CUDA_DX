# 完整入口与底层探针分开验证：校验器通过后才运行CPU导入，不能用底层接受代替规范通过。
$ErrorActionPreference='Stop'
$dir=Join-Path $PSScriptRoot 'results/c06'
if(-not(Test-Path "$PSScriptRoot/validation/node_modules/gltf-validator")) {
 & npm ci --prefix "$PSScriptRoot/validation" --ignore-scripts --no-audit --no-fund
 if($LASTEXITCODE -ne 0){throw 'Validator dependency install failed'}
}
$known=Get-Content "$dir/valid.gltf" -Raw|ConvertFrom-Json -AsHashtable
$known.extensionsUsed=@('KHR_materials_unlit')
$known.materials=@(@{extensions=@{KHR_materials_unlit=@{}}})
$known.meshes[0].primitives[0].material=0
[IO.File]::WriteAllText("$dir/known-extension.gltf",($known|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
$rows=@()
$cases=@(
 @('valid',"$dir/valid.gltf",0,'ACCEPTED_CPU'),
 @('glb',"$PSScriptRoot/build/_deps/assimp-src/test/models/glTF2/BoxTextured-glTF-Binary/BoxTextured.glb",0,'ACCEPTED_CPU'),
 # C.2导出文件附加了FB_ngon_encoding等扩展；保守策略拒绝，不误称GLB容器损坏。
 @('exported-glb',"$PSScriptRoot/results/c02/equivalent.glb",1,'\[validate\]'),
 @('misaligned',"$dir/misaligned.gltf",1,'\[validate\]'),
 @('unknown-required',"$dir/unknown-required.gltf",1,'\[validate\]'),
 @('known-extension',"$dir/known-extension.gltf",1,'\[scope\]'),
 @('animation',"$dir/animation.gltf",1,'\[scope\]'),
 @('morph',"$dir/morph.gltf",1,'\[scope\]')
)
foreach($case in $cases) {
 $name=$case[0];$start=[Diagnostics.ProcessStartInfo]::new((Get-Command node).Source)
 $start.ArgumentList.Add("$PSScriptRoot/validation/validate_import.cjs")
 $start.ArgumentList.Add($case[1]);$start.ArgumentList.Add("$dir/$name.report.json")
 $start.UseShellExecute=$false;$start.CreateNoWindow=$true
 $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $p=[Diagnostics.Process]::Start($start)
 $o=$p.StandardOutput.ReadToEndAsync();$e=$p.StandardError.ReadToEndAsync()
 if(-not $p.WaitForExit(30000)){$p.Kill();throw 'validator timeout'}
 $code=$p.ExitCode;$log=$o.Result+$e.Result;$p.Dispose()
 [IO.File]::WriteAllText("$dir/$name.pipeline.txt","exit=$code`n$log",[Text.UTF8Encoding]::new($false))
 if($code -ne $case[2] -or $log -notmatch $case[3]){throw "$name unexpected result: $code $log"}
 $rows+="PASS $name exit=$code expected=$($case[3])"
}
$rows|Set-Content "$dir/pipeline-summary.txt"
$rows
