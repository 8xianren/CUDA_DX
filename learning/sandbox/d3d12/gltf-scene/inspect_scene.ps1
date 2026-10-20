# C.1：对象引用探针，不是完整glTF解析器。JSON语法交给PowerShell标准库，今天只检查对象关系。
# 无CUDA/D3D12提交；不解码顶点、不计算World Matrix、不创建材质/BLAS。后续C/D再实现这些层。
# 输入与结果均以本脚本目录定位。整个JSON对象由PowerShell管理，不把文件索引当GPU地址。
$ErrorActionPreference = 'Stop'
$assetPath = Join-Path $PSScriptRoot 'assets/c01-shared-mesh.gltf'
$resultDir = Join-Path $PSScriptRoot 'results/c01'
New-Item -ItemType Directory -Force $resultDir | Out-Null
$doc = Get-Content -LiteralPath $assetPath -Raw | ConvertFrom-Json
$report = [System.Collections.Generic.List[string]]::new()
function Record([string]$Text) { $report.Add($Text); Write-Output $Text }
function Require([bool]$Condition, [string]$Message) { if (-not $Condition) {throw $Message} }
function Ref([object[]]$Items, $Index, [string]$Label) {
    # 引用0合法，不能用if($Index)判断是否存在。这里检查非负整数与数组边界。
    Require ($null -ne $Index -and $Index -is [ValueType]) "$Label missing/non-numeric index"
    Require ([double]$Index -eq [Math]::Floor([double]$Index) -and $Index -ge 0 -and $Index -lt $Items.Count) "$Label out of range"
    return $Items[[int]$Index]
}
Require ($doc.asset.version -eq '2.0') 'Fixture must use glTF 2.0'
Record "asset.version=$($doc.asset.version) defaultScene=$($doc.scene)"
$scene = Ref @($doc.scenes) $doc.scene 'scene'
$stats = @{ nodes=0; meshInstances=0; primitiveInstances=0; cameras=0 }
$seen = [System.Collections.Generic.HashSet[int]]::new()
function Visit([int]$Index, [string]$Indent) {
    # 防止本课场景出现环/重复节点引用；两个不同node引用同一mesh完全合法，不在这里去重mesh。
    Require ($seen.Add($Index)) 'Repeated node or cycle in selected scene'
    $node = Ref @($doc.nodes) $Index 'node'
    ++$stats.nodes
    Record "$Indent node[$Index] name=$($node.name)"
    if ($null -ne $node.mesh) {
        $mesh = Ref @($doc.meshes) $node.mesh 'mesh'; ++$stats.meshInstances
        Record "$Indent   -> mesh[$($node.mesh)] primitives=$(@($mesh.primitives).Count)"
        $pi = 0
        foreach ($primitive in $mesh.primitives) {
            ++$stats.primitiveInstances
            $material = Ref @($doc.materials) $primitive.material 'material'
            Require ($primitive.mode -eq 4) 'This fixture uses TRIANGLES only'
            Record "$Indent     primitive[$pi] -> material[$($primitive.material)] $($material.name)"
            foreach ($semantic in @('POSITION','indices')) {
                $ai = if ($semantic -eq 'POSITION') {$primitive.attributes.POSITION} else {$primitive.indices}
                $accessor = Ref @($doc.accessors) $ai 'accessor'
                $view = Ref @($doc.bufferViews) $accessor.bufferView 'bufferView'
                $buffer = Ref @($doc.buffers) $view.buffer 'buffer'
                Record "$Indent       $semantic -> accessor[$ai] $($accessor.type) count=$($accessor.count) -> bufferView[$($accessor.bufferView)] -> buffer[$($view.buffer)] $($buffer.uri)"
            }
            ++$pi
        }
    }
    if ($null -ne $node.camera) {
        $camera = Ref @($doc.cameras) $node.camera 'camera'; ++$stats.cameras
        Record "$Indent   -> camera[$($node.camera)] $($camera.type)"
    }
    foreach ($child in @($node.children)) { if ($null -ne $child) { Visit $child "$Indent  " } }
}
foreach ($root in $scene.nodes) { Visit $root '' }
# 本节只验证配套字节存在且长度相符，不把这一步声称为accessor解码或完整规范验证。
$binary = Join-Path (Split-Path $assetPath) 'c01-shared-mesh.bin'
Require ((Get-Item -LiteralPath $binary).Length -eq $doc.buffers[0].byteLength) 'Fixture binary length mismatch'
Require ($stats.nodes -eq 4 -and $stats.meshInstances -eq 2 -and $stats.primitiveInstances -eq 4 -and $stats.cameras -eq 1) 'Unexpected object graph'
Require (@($doc.meshes).Count -eq 1 -and @($doc.meshes[0].primitives).Count -eq 2) 'Fixture definitions changed'
Require ($doc.nodes[1].mesh -eq $doc.nodes[2].mesh) 'Mesh sharing lost'
Record 'definitions: mesh=1 primitive=2 material=2 accessor=3 bufferView=2 buffer=1'
Record "selected scene: nodes=$($stats.nodes) meshInstances=$($stats.meshInstances) primitiveInstances=$($stats.primitiveInstances) cameras=$($stats.cameras)"
Record 'binary bytes=60; GPU allocations=0; vertex decoding=not performed'
Record 'C.1 object graph PASS'
$report | Set-Content -LiteralPath (Join-Path $resultDir 'object_graph.txt') -Encoding utf8
