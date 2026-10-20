# R.13.8a：只给C++已算好的BMP加标题、转成PNG，供讲义显示；不做曝光/色调映射/采样。
# 所有GDI+对象归本脚本所有，finally释放，避免图片文件被锁定。位置基于脚本而非工作目录。
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$resultDir = Join-Path $PSScriptRoot 'results/r13-08a'
$source = $null; $sheet = $null; $graphics = $null; $font = $null
try {
    $source = [System.Drawing.Image]::FromFile((Join-Path $resultDir 'display_comparison.bmp'))
    $pw = [int](($source.Width - 32) / 3)
    $ph = [int](($source.Height - 24) / 2)
    $sheet = [System.Drawing.Bitmap]::new($source.Width, ($ph + 42) * 2 + 8)
    $graphics = [System.Drawing.Graphics]::FromImage($sheet)
    $graphics.Clear([System.Drawing.Color]::FromArgb(20, 25, 35))
    $font = [System.Drawing.Font]::new('Arial', 16)
    $labels = @('WRONG: missing sRGB', 'Correct: one sRGB encode', 'WRONG: double sRGB',
        'Correct encoding | EV -1', 'Correct encoding | EV 0', 'Correct encoding | EV +1')
    for ($panel = 0; $panel -lt 6; ++$panel) {
        $col = $panel % 3; $row = [int][Math]::Floor($panel / 3)
        $x = 8 + $col * ($pw + 8); $y = 8 + $row * ($ph + 42)
        $graphics.DrawString($labels[$panel], $font, [System.Drawing.Brushes]::White, $x, $y)
        $dest = [System.Drawing.Rectangle]::new($x, $y + 30, $pw, $ph)
        $src = [System.Drawing.Rectangle]::new($x, (8 + $row * ($ph + 8)), $pw, $ph)
        $graphics.DrawImage($source, $dest, $src, [System.Drawing.GraphicsUnit]::Pixel)
    }
    $sheet.Save((Join-Path $resultDir 'display_comparison.png'), [System.Drawing.Imaging.ImageFormat]::Png)
} finally {
    foreach ($item in @($graphics, $font, $sheet, $source)) { if ($null -ne $item) { $item.Dispose() } }
}
Write-Output (Join-Path $resultDir 'display_comparison.png')
