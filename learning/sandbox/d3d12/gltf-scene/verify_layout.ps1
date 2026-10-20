# 自编固定测试资产的生成器，不是 glTF 解码器；读取与解码始终由 Assimp 完成。
# 用 16 字节前缀、40 字节交错步长、非零 accessor 偏移检测常见布局错误。
$ErrorActionPreference = 'Stop'
$resultDir = Join-Path $PSScriptRoot 'results/c03'
New-Item -ItemType Directory -Force $resultDir | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)
$exe = Join-Path $PSScriptRoot 'build/Release/mesh_layout_test.exe'
if (-not (Test-Path $exe)) { throw 'Run build_importer.ps1 first' }
$positions = @(@(0,0,0),@(1,0,0),@(0,1,0))
$uvs = @(@(0,0.25),@(1,0.5),@(0.25,1))
$colors = @(@(255,128,0,255),@(0,255,64,255),@(32,0,255,128))
foreach($kind in @('u8','u16','u32','none')) {
    $stream = [IO.MemoryStream]::new()
    $writer = [IO.BinaryWriter]::new($stream)
    try {
        $writer.Write([byte[]]::new(16))
        for($i=0;$i -lt 3;$i++) {
            foreach($x in $positions[$i]) { $writer.Write([single]$x) }
            foreach($x in @(0,0,1)) { $writer.Write([single]$x) }
            foreach($x in $uvs[$i]) { $writer.Write([single]$x) }
            $writer.Write([byte[]]$colors[$i])
            $writer.Write([uint32]0) # 每顶点最后 4B 是 padding，不能作为属性读入。
        }
        $component = 0; $width = 0
        switch($kind) { 'u8' { $component=5121; $width=1 }; 'u16' { $component=5123; $width=2 }; 'u32' { $component=5125; $width=4 } }
        if($width) {
            $writer.Write([uint32]0) # 索引 accessor 在第二个 bufferView 内偏移 4B。
            foreach($index in @(0,1,2)) {
                switch($width) { 1 {$writer.Write([byte]$index)}; 2 {$writer.Write([uint16]$index)}; 4 {$writer.Write([uint32]$index)} }
            }
        }
        $writer.Flush()
        $bytes=$stream.ToArray()
    } finally { $writer.Dispose(); $stream.Dispose() }
    [IO.File]::WriteAllBytes("$resultDir/$kind.bin",$bytes)
    $accessors = @(
        @{bufferView=0;byteOffset=0;componentType=5126;type='VEC3';count=3;min=@(0,0,0);max=@(1,1,0)},
        @{bufferView=0;byteOffset=12;componentType=5126;type='VEC3';count=3},
        @{bufferView=0;byteOffset=24;componentType=5126;type='VEC2';count=3},
        @{bufferView=0;byteOffset=32;componentType=5121;type='VEC4';count=3;normalized=$true}
    )
    $views = @(@{buffer=0;byteOffset=16;byteLength=120;byteStride=40;target=34962})
    $primitive = @{attributes=@{POSITION=0;NORMAL=1;TEXCOORD_0=2;COLOR_0=3};mode=4}
    if($width) {
        $views += @{buffer=0;byteOffset=136;byteLength=(4+3*$width);target=34963}
        $accessors += @{bufferView=1;byteOffset=4;componentType=$component;type='SCALAR';count=3}
        $primitive.indices=4
    }
    $asset = @{asset=@{version='2.0';generator='CUDA_DX C.3 fixed fixture'};scene=0;scenes=@(@{nodes=@(0)});nodes=@(@{mesh=0});meshes=@(@{primitives=@($primitive)});buffers=@(@{uri="$kind.bin";byteLength=$bytes.Length});bufferViews=$views;accessors=$accessors}
    [IO.File]::WriteAllText("$resultDir/$kind.gltf",($asset | ConvertTo-Json -Depth 20),$utf8)
    # 不重写通用 accessor 解码；已知答案直接来自上面的数学顶点/颜色，C++ 逐项比较。
    & $exe "$resultDir/$kind.gltf" full 2>&1 | Tee-Object "$resultDir/$kind.txt"
    if($LASTEXITCODE -ne 0) { throw "$kind failed" }
}
& $exe "$PSScriptRoot/assets/c01-shared-mesh.gltf" defaults 2>&1 | Tee-Object "$resultDir/defaults.txt"
if($LASTEXITCODE -ne 0) { throw 'Missing attribute defaults failed' }
@'
PASS 5 cases: uint8/uint16/uint32/nonindexed + missing attributes.
Known answers: positions, normals, UV (Assimp v=1-sourceV), UNORM8 RGBA, uint32 indices.
Source: viewOffset=16 stride=40 count=3; positionOffset=0 normalOffset=12 uvOffset=24 colorOffset=32.
Index source: viewOffset=136 accessorOffset=4, widths=1/2/4; nonindexed case has no index accessor.
Owned output: Vertex stride=48 offsets=0/12/24/32, uint32 indices; Importer already destroyed.
No GPU resources or node/material adaptation in this lesson.
'@ | Set-Content "$resultDir/summary.txt"
