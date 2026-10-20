# 一次性迁移：按课程归档现有文件，保留路径映射；重复执行不会再移动已归档的文件。
# 仅使用PowerShell文件操作；移动前验证全部绝对路径仍在本仓库sandbox范围内。
$ErrorActionPreference='Stop'
$sandboxRoot=[System.IO.Path]::GetFullPath($PSScriptRoot)
$repoRoot=[System.IO.Path]::GetFullPath((Join-Path $sandboxRoot '../..'))
$rules=[ordered]@{
 'd3d12_window_clear'='window-basics'
 'd3d12_mesh_input_layout'='r01-r08-mesh'
 'dxr_capability'='r08a-capability'
 'dxr_blas'='r09-blas'
 'dxr_tlas'='r10-tlas'
 'dxr_minimal'='r11-01-minimal'
 'dxr_local_root'='r11-02-local-root'
 'dxr_window'='r11-03-window'
 'dxr_geometry_raytype'='r11-04-geometry-raytype'
 'dxr_shadow'='r12-01-shadow'
 'dxr_area'='r12-02-area'
 'dxr_camera'='r13-legacy-camera'
 'r13_camera_math'='r13-01-02-camera-math'
 'dxr_view'='r13-renderer'
 'dxr_surface'='r13-renderer'
 'dxr_direct_light'='r13-renderer'
 'dxr_lighting'='r13-renderer'
}
$moves=@()
foreach($track in @('d3d12','path_tracing')) {
 foreach($file in Get-ChildItem -LiteralPath (Join-Path $sandboxRoot $track) -File) {
  if($file.Name -eq 'README.md'){continue}
  $lesson=$null
  if($track -eq 'd3d12'){
   foreach($prefix in $rules.Keys){if($file.Name.StartsWith($prefix)){$lesson=$rules[$prefix];break}}
  } elseif($file.Name -match '^pt([1-5])_') {
   $lesson=@{'1'='pt01-radiometry';'2'='pt02-ray-geometry';'3'='pt03-monte-carlo';'4'='pt04-lambert';'5'='pt05-direct-lighting'}[$Matches[1]]
  }
  if(!$lesson){throw "Unmapped file: $($file.FullName)"}
  $relative="$track/$lesson/$($file.Name)"
  # R.13主线共用源码，结果再按实际小节分开，防止图像淹没源码。
  if($lesson -eq 'r13-renderer' -and $file.Extension -in @('.png','.ppm','.pfm','.txt')){
   $section=if($file.Name.StartsWith('dxr_lighting')){'r13-05'}else{'r13-04'}
   $relative="$track/$lesson/results/$section/$($file.Name)"
  }
  $destination=[System.IO.Path]::GetFullPath((Join-Path $sandboxRoot $relative))
  $boundary=$sandboxRoot+[System.IO.Path]::DirectorySeparatorChar
  if(!$file.FullName.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or !$destination.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase)){throw 'Move escaped sandbox'}
  if(Test-Path -LiteralPath $destination){throw "Destination exists: $destination"}
  $moves+= [pscustomobject]@{old="$track/$($file.Name)";new=$relative;source=$file.FullName;destination=$destination;lesson=$lesson}
 }
}
if(!$moves.Count){Write-Output 'Nothing to move';exit 0}
foreach($entry in $moves){
 [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($entry.destination))|Out-Null
 Move-Item -LiteralPath $entry.source -Destination $entry.destination
}
# 同步文档、编译示例和代码中的显式路径，正/反斜杠都处理；不改二进制产物。
$textFiles=@(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'learning'),(Join-Path $repoRoot '.agents'),(Join-Path $repoRoot '.cursor') -Recurse -File | Where-Object {$_.Extension -in @('.md','.cu','.h','.hlsl','.hlsli','.py','.ps1','.json') -and $_.FullName -ne $PSCommandPath})
$textFiles+=Get-Item -LiteralPath (Join-Path $repoRoot 'AGENTS.md'),(Join-Path $repoRoot 'CUDA_DX.md')
$updated=0
foreach($file in $textFiles){
 $before=[System.IO.File]::ReadAllText($file.FullName);$after=$before
 foreach($entry in $moves){$after=$after.Replace($entry.old,$entry.new).Replace($entry.old.Replace('/','\'),$entry.new.Replace('/','\'))}
 if($after -cne $before){[System.IO.File]::WriteAllText($file.FullName,$after,[System.Text.UTF8Encoding]::new($false));$updated++}
}
$moves|Select-Object old,new|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $sandboxRoot 'lesson-path-map.json') -Encoding utf8
Write-Output "Moved $($moves.Count) files; updated $updated text files."
