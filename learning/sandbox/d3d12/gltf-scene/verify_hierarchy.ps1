# 生成已知场景变体，文件读取与 TRS/拓扑转换仍由 Assimp 处理。
$ErrorActionPreference='Stop'
$dir=Join-Path $PSScriptRoot 'results/c04'
New-Item -ItemType Directory -Force $dir | Out-Null
$utf8=[Text.UTF8Encoding]::new($false)
$source=Get-Content "$PSScriptRoot/assets/c01-shared-mesh.gltf" -Raw
$bytes=[IO.File]::ReadAllBytes("$PSScriptRoot/assets/c01-shared-mesh.bin")
Copy-Item "$PSScriptRoot/assets/c01-shared-mesh.bin" "$dir/c01-shared-mesh.bin" -Force
$exe=Join-Path $PSScriptRoot 'build/Release/scene_hierarchy_test.exe'
foreach($kind in @('trs','matrix','strip','fan')) {
    $asset=$source | ConvertFrom-Json -AsHashtable
    $mode='hierarchy'
    if($kind -eq 'trs') {
        $asset.nodes[0].translation=@(10,1,0)
        $asset.nodes[0].rotation=@(0,0,[Math]::Sqrt(0.5),[Math]::Sqrt(0.5)) # glTF四元数 x/y/z/w，绕Z正转90度。
        $asset.nodes[0].scale=@(2,3,1)
    } elseif($kind -eq 'matrix') {
        # glTF JSON矩阵按列展平；它表达T*R*S，不是本课CPU的按行内存顺序。
        $asset.nodes[0].matrix=@(0,2,0,0, -3,0,0,0, 0,0,1,0, 10,1,0,1)
    } else {
        $mode='topology'
        $primitive=$asset.meshes[0].primitives[0]
        $primitive.mode=if($kind -eq 'strip'){5}else{6}
        $asset.meshes[0].primitives=@($primitive)
        $asset.accessors=@($asset.accessors[0],$asset.accessors[1])
        $asset.accessors[1].count=4
        $asset.bufferViews[1].byteLength=8
        $asset.buffers[0].byteLength=56
        $asset.buffers[0].uri="$kind.bin"
        $output=[byte[]]::new(56)
        [Array]::Copy($bytes,$output,48)
        # square的顶点按逆时针0/1/2/3排列；strip需要0/1/3/2，fan使用0/1/2/3。
        $indices=if($kind -eq 'strip'){@(0,1,3,2)}else{@(0,1,2,3)}
        for($i=0;$i -lt 4;$i++) { [Array]::Copy([BitConverter]::GetBytes([uint16]$indices[$i]),0,$output,48+2*$i,2) }
        [IO.File]::WriteAllBytes("$dir/$kind.bin",$output)
    }
    [IO.File]::WriteAllText("$dir/$kind.gltf",($asset | ConvertTo-Json -Depth 30),$utf8)
    & $exe "$dir/$kind.gltf" $mode 2>&1 | Tee-Object "$dir/$kind.txt"
    if($LASTEXITCODE -ne 0) { throw "$kind failed" }
}
'PASS: TRS and equivalent matrix; shared definitions; parent update; unchanged local vertices; strip/fan triangle area and winding.' | Set-Content "$dir/summary.txt"
