# 仅将实际Back Buffer读回的P6 RGB8结果转PNG并加标题，不计算光照/曝光或进行颜色变换。
# 支持本课程三行头部P6；-Resize展示.8c的不同尺寸，默认保留.8b的预览。
# 图像只为排版缩放，PPM原始尺寸/字节才是验收依据。所有对象在finally释放。
param([switch]$Resize)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$resultDir = Join-Path $PSScriptRoot $(if ($Resize) {'results/r13-08c'} else {'results/r13-08b'})
$columns = if ($Resize) {2} else {3}
$rows = if ($Resize) {2} else {1}
$sheet = [System.Drawing.Bitmap]::new(($columns*488+8), ($rows*312+8))
$graphics = [System.Drawing.Graphics]::FromImage($sheet)
$font = [System.Drawing.Font]::new('Arial', 16)
try {
    $graphics.Clear([System.Drawing.Color]::FromArgb(20, 25, 35))
    $files = if ($Resize) {@('initial','odd-size','portrait','wide-new-view')} else {@('frame-32','frame-64','frame-96')}
    $labels = if ($Resize) {@('480x270 | initial view','641x359 | same HDR target','321x481 | portrait + black bars','800x200 | new 120x90 ViewRect')} else {@('32 spp | EV 0','64 spp | EV +1','96 spp | EV -1')}
    for ($panel = 0; $panel -lt $files.Length; ++$panel) {
        $data = [System.IO.File]::ReadAllBytes((Join-Path $resultDir "$($files[$panel]).ppm"))
        $offset = 0; $lines = 0
        while ($offset -lt $data.Length -and $lines -lt 3) { if ($data[$offset++] -eq 10) { ++$lines } }
        $header = [System.Text.Encoding]::ASCII.GetString($data,0,$offset).Trim() -split '\s+'
        if ($header.Length -ne 4 -or $header[0] -ne 'P6' -or $header[3] -ne '255') {throw 'Unsupported PPM header'}
        $width=[int]$header[1];$height=[int]$header[2]
        if ($lines -ne 3 -or $data.Length - $offset -ne $width*$height*3) { throw 'Unexpected PPM layout' }
        $bitmap = [System.Drawing.Bitmap]::new($width,$height)
        try {
            for ($y = 0; $y -lt $height; ++$y) { for ($x = 0; $x -lt $width; ++$x) {
                $i = $offset + ($y*$width+$x)*3
                $bitmap.SetPixel($x,$y,[System.Drawing.Color]::FromArgb($data[$i],$data[$i+1],$data[$i+2]))
            } }
            $x0 = 8+($panel%$columns)*488;$y0=8+[int][Math]::Floor($panel/$columns)*312
            $graphics.DrawString($labels[$panel],$font,[System.Drawing.Brushes]::White,$x0,$y0)
            if ($Resize) {
                $scale=[Math]::Min(480.0/$width,270.0/$height)
                $targetW=[int]($width*$scale);$targetH=[int]($height*$scale)
                $dest=[System.Drawing.Rectangle]::new(($x0+[int]((480-$targetW)/2)),($y0+32),$targetW,$targetH)
                $graphics.DrawImage($bitmap,$dest)
            } else { $graphics.DrawImageUnscaled($bitmap,$x0,$y0+32) }
        } finally { $bitmap.Dispose() }
    }
    $sheet.Save((Join-Path $resultDir 'gpu_display.png'),[System.Drawing.Imaging.ImageFormat]::Png)
} finally { $graphics.Dispose();$font.Dispose();$sheet.Dispose() }
Write-Output (Join-Path $resultDir 'gpu_display.png')
