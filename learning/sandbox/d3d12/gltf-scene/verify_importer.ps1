# 在独立进程中读取每个资产：检查退出码、结构摘要和失败诊断；结果直接写本课目录。
$ErrorActionPreference = 'Stop'
$exe = Join-Path $PSScriptRoot 'build/Release/scene_import_probe.exe'
$resultDir = Join-Path $PSScriptRoot 'results/c02'
New-Item -ItemType Directory -Force $resultDir | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)
function Invoke-Probe([string]$Name, [string[]]$Arguments, [bool]$ShouldPass = $true) {
    # 用 Process 捕获 stderr，避免 PowerShell 将预期失败的诊断变成脚本终止异常。
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $exe
    $start.Arguments = ($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) { $process.Kill(); throw "$Name timed out" }
    $stdout = $outTask.Result
    $stderr = $errTask.Result
    $code = $process.ExitCode
    $process.Dispose()
    [IO.File]::WriteAllText("$resultDir/$Name.txt", "exit=$code`n$stdout$stderr", $utf8)
    if ($ShouldPass -and $code -ne 0) { throw "$Name failed: $stderr" }
    if (-not $ShouldPass -and ($code -ne 1 -or $stderr -notmatch 'IMPORT_ERROR')) {
        throw "$Name did not fail cleanly: exit=$code $stderr"
    }
    return $stdout
}
if (-not (Test-Path $exe)) { throw 'Run build_importer.ps1 first' }
$gltf = Join-Path $PSScriptRoot 'assets/c01-shared-mesh.gltf'
$glb = Join-Path $resultDir 'equivalent.glb'
$original = Invoke-Probe 'gltf' @($gltf, '--export-glb', $glb)
$roundtrip = Invoke-Probe 'glb' @($glb)
# 6.0.2 GLB 导出器不保留本样例相机对象。单独锁定此已知限制，其他打印属性严格比较。
# 不将相机丢失伪装成完整场景等价；View 节点及其变换仍须保留。
if ($roundtrip -notmatch 'cameras=0') { throw 'Exporter camera behavior changed; review expectation' }
if (($original -replace 'cameras=1','cameras=0') -ne $roundtrip) { throw 'glTF/GLB geometry/node/baseColor summaries differ; inspect logs' }
if ($original -notmatch 'SUMMARY meshes=2 instances=4 triangles=2 cameras=1') { throw 'Unexpected glTF counts' }
# 独立于导出回环，按原始 fixture 的六个角点顺序、索引和颜色建立已知答案。
$actualGeometry = (($original -split '\r?\n') | Where-Object { $_ -match '^(v |triangle)' }) -join ';'
$expectedGeometry = 'v -0.5 -0.5 0;v 0.5 -0.5 0;v 0.5 0.5 0;triangle 0 1 2;v -0.5 -0.5 0;v 0.5 0.5 0;v -0.5 0.5 0;triangle 0 1 2'
if ($actualGeometry -ne $expectedGeometry) { throw 'Known fixture geometry mismatch' }
foreach ($entry in @(@(0,0.8,0.1,0.1,1), @(1,0.1,0.1,0.8,1))) {
    $line = ($original -split '\r?\n') | Where-Object { $_ -match "^baseColor $($entry[0]) " }
    if (-not $line) { throw 'Missing baseColor' }
    $parts = $line -split ' '
    for ($i=1; $i -le 4; $i++) {
        $value = [double]::Parse($parts[$i+1], [Globalization.CultureInfo]::InvariantCulture)
        if ([Math]::Abs($value - $entry[$i]) -gt 1e-6) { throw 'Known baseColor mismatch' }
    }
}
if ($original -notmatch 'node Left meshes 0 1 local 1 0 0 -2' -or $original -notmatch 'node Right meshes 0 1 local 1 0 0 2') {
    throw 'Shared references or local translations changed'
}
# 自编 OBJ 四边形：验证库的三角化，而非只使用已三角化输入。
[IO.File]::WriteAllText("$resultDir/quad.obj", "o Quad`nv -0.5 -0.5 0`nv 0.5 -0.5 0`nv 0.5 0.5 0`nv -0.5 0.5 0`nf 1 2 3 4`n", $utf8)
$obj = Invoke-Probe 'obj' @("$resultDir/quad.obj")
if ($obj -notmatch 'SUMMARY meshes=1 instances=1 triangles=2') { throw 'OBJ triangulation mismatch' }
# FBX 使用固定 Assimp 提交自带样本；不自行编写 FBX 文件或复制无来源资产。
$fbx = Join-Path $PSScriptRoot 'build/_deps/assimp-src/test/models/FBX/box.fbx'
$fbxOutput = Invoke-Probe 'fbx' @($fbx)
if ($fbxOutput -notmatch 'triangles=12') { throw 'FBX box triangle count mismatch' }
# 损坏资产全部写入 results；不覆盖原始课程资产。BinaryWriter/解析器都不需要自己实现。
$bytes = [IO.File]::ReadAllBytes($glb)
$badMagic = [byte[]]$bytes.Clone(); $badMagic[0] = 0
[IO.File]::WriteAllBytes("$resultDir/bad-magic.glb", $badMagic)
[IO.File]::WriteAllBytes("$resultDir/truncated.glb", [byte[]]$bytes[0..19])
$badChunk = [byte[]]$bytes.Clone()
[Array]::Copy([BitConverter]::GetBytes([uint32]2147483647), 0, $badChunk, 12, 4)
[IO.File]::WriteAllBytes("$resultDir/bad-chunk.glb", $badChunk)
$null = Invoke-Probe 'bad-magic' @("$resultDir/bad-magic.glb") $false
$null = Invoke-Probe 'truncated' @("$resultDir/truncated.glb") $false
$null = Invoke-Probe 'bad-chunk' @("$resultDir/bad-chunk.glb") $false
$missing = (Get-Content $gltf -Raw).Replace('c01-shared-mesh.bin', 'intentionally-missing.bin')
[IO.File]::WriteAllText("$resultDir/missing-buffer.gltf", $missing, $utf8)
$null = Invoke-Probe 'missing-buffer' @("$resultDir/missing-buffer.gltf") $false
$summary = "PASS: glTF/GLB geometry, node transforms and baseColor equality; shared mesh references; OBJ triangulation; FBX box; bad magic; truncated GLB; invalid chunk length; missing buffer.`nKNOWN LIMIT: Assimp 6.0.2 GLB export drops camera object (1 -> 0); View node remains.`nCPU only; no GPU upload or full material/animation compatibility claim."
[IO.File]::WriteAllText("$resultDir/summary.txt", $summary, $utf8)
Write-Output $summary
