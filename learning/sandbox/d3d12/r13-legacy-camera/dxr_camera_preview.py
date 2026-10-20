"""把R.13实际GPU读回生成的PPM转为PNG，并排展示三类诊断数据。

本脚本不重新渲染场景，不计算光照，不修补像素；图片来自dxr_camera_pipeline.exe。
各像素直接保留原始诊断码值。白色边距和英文标签仅用于排版，不属于GPU输出。
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

root = Path(__file__).resolve().parent
columns = [("ids", "Instance ID"), ("normals", "World geometric normal"),
           ("distance", "Ray distance (near = bright)")]
font = ImageFont.truetype("C:/Windows/Fonts/arial.ttf", 17)
sheet = Image.new("RGB", (1008, 585), "white")
draw = ImageDraw.Draw(sheet)
for row, (mode, caption, top) in enumerate([
    ("wide", "320 x 180 | vertical FOV 60 deg | eye (0, 1, 5)", 12),
    ("square", "257 x 257 | vertical FOV 50 deg | eye (2, 1.8, 5)", 262),
]):
    draw.text((12, top), caption, font=font, fill="black")
    for col, (suffix, label) in enumerate(columns):
        path = root / f"dxr_camera_{mode}_{suffix}.ppm"
        with Image.open(path) as source:
            image = source.convert("RGB")
            image.save(path.with_suffix(".png"))
            x = 12 + col * 332
            draw.text((x, top + 27), label, font=font, fill="black")
            # 保持原分辨率，不插值、不缩放；较窄的方图在320px列中居中。
            sheet.paste(image, (x + (320-image.width)//2, top + 54))
sheet.save(root / "dxr_camera_diagnostics.png")
print(root / "dxr_camera_diagnostics.png")
