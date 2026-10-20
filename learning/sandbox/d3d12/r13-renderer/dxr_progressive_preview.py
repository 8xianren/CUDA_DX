"""R.13.6离线预览：只读GPU生成的PFM；不参与射线、采样、累积或数值验收。"""
from pathlib import Path
import struct
from PIL import Image, ImageDraw, ImageFont

RESULTS = Path(__file__).resolve().parent / "results" / "r13-06"

def preview(name):
    with (RESULTS / name).open("rb") as stream:
        assert stream.readline().strip() == b"PF"
        width, height = map(int, stream.readline().split())
        assert float(stream.readline()) == -1.0
        values = struct.unpack(f"<{width*height*3}f", stream.read())
    pixels = bytearray()
    # PFM底部行优先；固定曝光1，先Reinhard，再sRGB，仅改变预览数据。
    for row in range(height-1, -1, -1):
        for value in values[row*width*3:(row+1)*width*3]:
            linear = max(value, 0) / (1 + max(value, 0))
            encoded = 12.92*linear if linear <= .0031308 else 1.055*linear**(1/2.4)-.055
            pixels.append(round(255*encoded))
    return Image.frombytes("RGB", (width,height), bytes(pixels)).crop((0,0,160,90))

font=ImageFont.truetype("C:/Windows/Fonts/arial.ttf",17)
title=ImageFont.truetype("C:/Windows/Fonts/arial.ttf",22)
sheet=Image.new("RGB",(1032,496),"#111827")
draw=ImageDraw.Draw(sheet)
draw.text((16,12),"R.13.6 | Actual GPU linear accumulation | 1 light sample per camera sample",font=title,fill="white")
items=[("seed0_1spp.pfm","Pixel jitter | 1 spp"),
       ("seed0_16spp.pfm","Pixel jitter | 16 spp"),
       ("seed0_256spp.pfm","Pixel jitter | 256 spp"),
       ("center_256spp.pfm","Fixed pixel center | 256 light samples"),
       ("frozen_16spp.pfm","Frozen sample | repeated 16 times"),
       ("reference_2048spp.pfm","Independent reference | 2048 spp")]
for i,(name,label) in enumerate(items):
    x,y=16+(i%3)*340,50+(i//3)*212
    draw.text((x,y),label,font=font,fill="#e5e7eb")
    sheet.paste(preview(name).resize((320,180),Image.Resampling.NEAREST),(x,y+24))
draw.text((16,478),"Same display transform for all panels. PFM retains linear HDR; reference is finite-sample, not exact truth.",font=font,fill="#9ca3af")
sheet.save(RESULTS/"comparison.png")
# 对同一蓝色板轮廓做最近邻放大，便于观察像素覆盖率而非插值产生的视觉平滑。
zoom=Image.new("RGB",(600,320),"#111827");d=ImageDraw.Draw(zoom)
for i,(file,label) in enumerate([("center_256spp.pfm","Fixed center"),("seed0_256spp.pfm","Pixel-area average")]):
    x=12+i*300;d.text((x,8),label,font=title,fill="white")
    zoom.paste(preview(file).crop((86,16,118,46)).resize((256,240),Image.Resampling.NEAREST),(x,46))
zoom.save(RESULTS/"edge_comparison.png")
print(RESULTS/"comparison.png")
print(RESULTS/"edge_comparison.png")
