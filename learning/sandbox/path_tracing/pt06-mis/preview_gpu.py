"""从GPU读回的线性CSV绘图，同一行统一曝光；不以显示码值计算误差。"""
from pathlib import Path
import csv
from PIL import Image, ImageDraw, ImageFont
root = Path(__file__).resolve().parent / 'results/gpu'
canvas = Image.new('RGB', (1040, 520), (245, 246, 248))
draw = ImageDraw.Draw(canvas)
font = ImageFont.truetype('C:/Windows/Fonts/arial.ttf', 17)
for row, (case, exposure) in enumerate([('small', 16), ('large', 1)]):
    y = 35 + row * 255
    draw.text((15, y - 25), f'{case.upper()} | GPU orthographic camera | 128 directions/estimator | exposure x{exposure}', font=font, fill='black')
    reference = list(csv.DictReader((root/case/'reference.csv').open()))
    samples = list(csv.DictReader((root/case/'seed0.csv').open()))
    for col, (label, key) in enumerate([('Reference', 'linear_radiance'), ('BSDF', 'bsdf'), ('NEE', 'nee'), ('Balance', 'balance'), ('Power', 'power')]):
        x = 15 + col * 205
        for item in (reference if col == 0 else samples):
            v = max(0, min(1, float(item[key]) * exposure))
            v = 12.92*v if v <= .0031308 else 1.055*v**(1/2.4)-.055
            b = round(255*v)
            # GPU图像已规定y向下，不像上一节的表面点网格再做上下翻转。
            px, py = int(item['x']), int(item['y'])
            draw.rectangle((x+6*px, y+6*py, x+6*px+5, y+6*py+5), fill=(b,b,b))
        draw.text((x, y+200), label, font=font, fill='black')
canvas.save(root/'comparison.png')
print(root/'comparison.png')
