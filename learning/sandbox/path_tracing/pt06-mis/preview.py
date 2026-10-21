"""直接从线性数值CSV绘制对照图；所有方法同一场景使用相同曝光，不自动拉伸。"""
from pathlib import Path
import csv,math
from PIL import Image,ImageDraw,ImageFont
root=Path(__file__).resolve().parent/'results'
font=ImageFont.truetype('C:/Windows/Fonts/arial.ttf',18)
small=ImageFont.truetype('C:/Windows/Fonts/arial.ttf',14)
names=['reference','bsdf-seed0','nee-seed0','balance-seed0','power-seed0']
labels=['Reference','BSDF only','NEE only','Balance MIS','Power MIS']
canvas=Image.new('RGB',(940,470),(245,246,248));draw=ImageDraw.Draw(canvas)
for row,(case,exposure) in enumerate([('small',16),('large',1)]):
    y=25+row*225
    draw.text((15,y-20),f'{case.upper()} light | exposure x{exposure} | 128 direction samples/pixel | seed 0',font=small,fill='black')
    for col,(name,label) in enumerate(zip(names,labels)):
        x=15+col*185
        records=list(csv.DictReader((root/case/(name+'.csv')).open()))
        for item in records:
            v=max(0,min(1,float(item['linear_radiance'])*exposure))
            v=12.92*v if v<=.0031308 else 1.055*v**(1/2.4)-.055
            b=round(v*255);px=int(item['x']);py=int(item['y'])
            # y朝上，显示时翻转网格；这只改变图表坐标展示，不改变数值或误差计算。
            draw.rectangle((x+px*7,y+(23-py)*7,x+px*7+6,y+(23-py)*7+6),fill=(b,b,b))
        draw.text((x,y+174),label,font=font,fill='black')
canvas.save(root/'comparison.png')
print(root/'comparison.png')
