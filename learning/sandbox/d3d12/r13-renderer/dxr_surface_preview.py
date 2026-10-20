"""把R.13.4真实GPU读回的六类PPM排成诊断图；不重算几何或修补像素。

输入PPM由dxr_view_pipeline生成。PNG保持字节码值，黑色视口外区域也保留。
本脚本只转换格式并加图名；这些伪彩色不是照明结果或HDR显示管线。
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

root = Path(__file__).resolve().parent / "results" / "r13-04"
columns = [
    ("ids", "Instance ID"),
    ("normals", "World geometric normal"),
    ("wrong_normals", "WRONG: ordinary vector transform"),
    ("barycentric", "Barycentric weights (A, B, C)"),
    ("distance", "Ray distance: clamp((10 - t) / 10)"),
    ("depth", "Reversed-Z depth: display gain x20"),
]
font = ImageFont.truetype("C:/Windows/Fonts/arial.ttf", 16)
title_font = ImageFont.truetype("C:/Windows/Fonts/arial.ttf", 19)
for serial, label in [(1, "Baseline camera"), (3, "Rotated camera")]:
    sheet = Image.new("RGB", (1200, 638), "white")
    draw = ImageDraw.Draw(sheet)
    draw.text((12, 10), f"R.13.4 | {label} | actual DXR readback | 384 x 256 canvas, 320 x 180 view", font=title_font, fill="black")
    for index, (suffix, caption) in enumerate(columns):
        source = root / f"dxr_view_surface_{serial}_{suffix}.ppm"
        with Image.open(source) as im:
            rgb = im.convert("RGB")
            if rgb.size != (384, 256):
                raise ValueError(f"Unexpected image size: {source}")
            rgb.save(source.with_suffix(".png"))
            x = 12 + (index % 3) * 396
            y = 47 + (index // 3) * 292
            draw.text((x, y), caption, font=font, fill="black")
            sheet.paste(rgb, (x, y + 25))  # 原始分辨率，不插值或缩放。
    out = root / f"dxr_surface_diagnostics_{serial}.png"
    sheet.save(out)
    print(out)
