"""R.13.7离线显示：比较错误历史混合，并对同一PFM应用不同曝光/色调映射。"""
from pathlib import Path
import struct
from PIL import Image, ImageDraw, ImageFont

RESULTS=Path(__file__).resolve().parent/"results"/"r13-07"

def display(filename, exposure=1.0, curve="reinhard"):
    with (RESULTS/filename).open("rb") as stream:
        assert stream.readline().strip()==b"PF"
        width,height=map(int,stream.readline().split())
        assert float(stream.readline())==-1.0
        raw=struct.unpack(f"<{width*height*3}f",stream.read())
    rgb=bytearray()
    for row in range(height-1,-1,-1):
        for radiance in raw[row*width*3:(row+1)*width*3]:
            # 明确分三步：曝光乘法 -> 色调映射 -> sRGB编码。最后才量化为PNG字节。
            exposed=max(radiance,0)*exposure
            mapped=exposed/(1+exposed) if curve=="reinhard" else min(exposed,1)
            encoded=12.92*mapped if mapped<=.0031308 else 1.055*mapped**(1/2.4)-.055
            rgb.append(round(255*encoded))
    return Image.frombytes("RGB",(width,height),bytes(rgb)).crop((0,0,160,90))

font=ImageFont.truetype("C:/Windows/Fonts/arial.ttf",17)
heading=ImageFont.truetype("C:/Windows/Fonts/arial.ttf",22)
sheet=Image.new("RGB",(1032,548),"#111827");draw=ImageDraw.Draw(sheet)
draw.text((16,12),"R.13.7 | Actual DXR history: old camera samples contaminate the new view",font=heading,fill="white")
items=[("before-camera.pfm","Old view | 64 samples",1,"reinhard"),
       ("wrong-no-reset.pfm","WRONG | 64 old + 32 new samples",1,"reinhard"),
       ("correct-reset.pfm","RESET | same 32 new samples",1,"reinhard")]
for i,(file,label,e,t) in enumerate(items):
    x=16+i*340;draw.text((x,50),label,font=font,fill="#e5e7eb")
    sheet.paste(display(file,e,t).resize((320,180),Image.Resampling.NEAREST),(x,76))
draw.text((16,276),"Same clean HDR data below: display changes need no new rays or history reset",font=heading,fill="white")
for i,(label,e,t) in enumerate([("Exposure x1 | Reinhard",1,"reinhard"),("Exposure x2 (+1 EV) | Reinhard",2,"reinhard"),("Exposure x2 | clamp (diagnostic)",2,"clamp")]):
    x=16+i*340;draw.text((x,314),label,font=font,fill="#e5e7eb")
    sheet.paste(display("correct-reset.pfm",e,t).resize((320,180),Image.Resampling.NEAREST),(x,340))
draw.text((16,528),"PFM is linear, unexposed HDR. All panels apply sRGB encoding after their display transform.",font=font,fill="#9ca3af")
sheet.save(RESULTS/"history_comparison.png")
print(RESULTS/"history_comparison.png")
