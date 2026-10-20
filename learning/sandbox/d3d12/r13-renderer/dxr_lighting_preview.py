"""读取GPU真实PFM读回值；固定同一显示变换，不对每张图自动曝光。"""
from pathlib import Path
import struct
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent / "results" / "r13-05"

def load_pfm(path):
    # PFM为底部行优先的little-endian RGB float32；这里恢复到屏幕顶部行优先。
    with path.open("rb") as stream:
        assert stream.readline().strip() == b"PF"
        w, h = map(int, stream.readline().split())
        assert float(stream.readline()) == -1.0
        data = struct.unpack(f"<{w*h*3}f", stream.read())
    pixels = bytearray()
    for y in range(h-1, -1, -1):
        for v in data[y*w*3:(y+1)*w*3]:
            # 仅预览：固定曝光1，Reinhard后做sRGB编码；PFM保留原始线性值。
            t = max(v, 0) / (1 + max(v, 0))
            srgb = 12.92*t if t <= .0031308 else 1.055*t**(1/2.4)-.055
            pixels.append(round(255*srgb))
    return Image.frombytes("RGB", (w,h), bytes(pixels)).crop((0,0,320,180))

canvas = Image.new("RGB", (1008,700), "#111827")
draw = ImageDraw.Draw(canvas)
font = ImageFont.truetype("C:/Windows/Fonts/arial.ttf", 20)
small = ImageFont.truetype("C:/Windows/Fonts/arial.ttf", 16)
draw.text((20,14), "R.13.5 | Actual DXR readback | fixed camera pixel centers", fill="white", font=font)
items = [(1,"64 light samples / hit - visibility ON"), (2,"64 light samples / hit - visibility OFF"),
         (7,"1 light sample / hit - visibility ON"), (4,"Isolated white furnace - Li=1, V=1")]
for index,(serial,label) in enumerate(items):
    x,y=20+(index%2)*494,60+(index//2)*310
    draw.text((x,y),label,fill="#e5e7eb",font=small)
    pic=load_pfm(ROOT/f"dxr_lighting_direct_{serial}.pfm")
    canvas.paste(pic.resize((480,270),Image.Resampling.NEAREST),(x,y+26))
draw.text((20,680),"Same preview: exposure 1, Reinhard, sRGB | Linear RGB is preserved in PFM",fill="#9ca3af",font=small)
canvas.save(ROOT/"dxr_lighting_comparison.png")
print(ROOT/"dxr_lighting_comparison.png")
