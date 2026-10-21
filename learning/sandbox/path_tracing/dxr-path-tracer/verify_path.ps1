$ErrorActionPreference='Stop'
$out=Join-Path $PSScriptRoot 'results/pt08'
New-Item -ItemType Directory -Force $out | Out-Null
$shared=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../d3d12/gltf-scene'))
& cmake -S $shared -B "$shared/build" -G 'Visual Studio 17 2022' -A x64 2>&1 | Tee-Object "$out/configure.txt"
if($LASTEXITCODE -ne 0){throw 'configure failed'}
& cmake --build "$shared/build" --config Release --target path_render energy_lut_build pbr_test --parallel 8 2>&1 | Tee-Object "$out/build.txt"
if($LASTEXITCODE -ne 0){throw 'path renderer build failed'}
& "$PSScriptRoot/../pt08-materials/build/Release/energy_lut_build.exe" $out 2>&1 | Tee-Object "$out/lut-run.txt"
if($LASTEXITCODE -ne 0){throw 'energy table failed'}
& python "$PSScriptRoot/make_gallery.py"
if($LASTEXITCODE -ne 0){throw 'gallery generation failed'}
& node "$shared/validation/validate_import.cjs" "$out/gallery.gltf" "$out/validation.json" 2>&1 | Tee-Object "$out/validation.txt"
if($LASTEXITCODE -ne 0){throw 'gallery validator failed'}
& dxc -T lib_6_3 -HV 2021 -Fo "$out/path.dxil" "$PSScriptRoot/path_integrator.hlsl" 2>&1 | Tee-Object "$out/shader-build.txt"
if($LASTEXITCODE -ne 0){throw 'path shader failed'}
$cases=@(
    @{name='primary';spp=16;depth=0;mode=1;seed=0;rr=0;light=12},
    @{name='direct';spp=256;depth=1;mode=1;seed=0;rr=0;light=12},
    @{name='mis';spp=256;depth=8;mode=1;seed=0;rr=0;light=12},
    @{name='bsdf';spp=256;depth=8;mode=0;seed=0;rr=0;light=12},
    @{name='double';spp=256;depth=8;mode=2;seed=0;rr=0;light=12},
    @{name='rr';spp=256;depth=8;mode=1;seed=0;rr=1;light=12},
    @{name='reference';spp=1024;depth=8;mode=1;seed=17;rr=0;light=12},
    @{name='no-light';spp=128;depth=8;mode=1;seed=0;rr=0;light=0}
)
foreach($case in $cases){
    $dest=Join-Path $out $case.name;New-Item -ItemType Directory -Force $dest | Out-Null
    & "$PSScriptRoot/build/Release/path_render.exe" "$out/gallery.gltf" "$out/path.dxil" "$out/energy-lut.bin" $dest 384 192 $case.spp $case.depth $case.mode $case.seed $case.rr $case.light 2>&1 | Tee-Object "$dest/run.txt"
    if($LASTEXITCODE -ne 0){throw "path case failed: $($case.name)"}
}
# 新增可选IOR和Surface字段后重跑原GPU材质验收；输出归本节，保留前课历史。
& dxc -T lib_6_3 -HV 2021 -D PBR_ENERGY_BALANCED=1 -Fo "$out/pbr-regression.dxil" "$PSScriptRoot/../pt08-materials/pbr_test.hlsl"
if($LASTEXITCODE -ne 0){throw 'PBR regression shader failed'}
& "$PSScriptRoot/../pt08-materials/build/Release/pbr_test.exe" "$PSScriptRoot/../pt08-materials/results/energy-gpu/pbr.gltf" "$out/pbr-regression.dxil" "$out/pbr-regression" "$out/energy-lut.bin" 2>&1 | Tee-Object "$out/pbr-regression.txt"
if($LASTEXITCODE -ne 0){throw 'PBR regression failed'}
& python "$PSScriptRoot/analyze_gallery.py"
if($LASTEXITCODE -ne 0){throw 'gallery image/statistical validation failed'}
