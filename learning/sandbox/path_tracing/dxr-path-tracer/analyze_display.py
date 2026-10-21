"""展示实际交换链Back Buffer读回；不重新算曝光/色调映射来冒充GPU结果。
所有PPM已经含最终sRGB码值，这里转PNG保持原字节，只有拼图展示会做最近邻尺寸排版。
"""
from pathlib import Path
import csv, json, sys
root=Path(__file__).resolve().parent;out=root/'results/pt10-display'
sys.path.insert(0,str(root/'../pt08-materials/results/ggx/plot_packages'))
import numpy as np
from PIL import Image
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.font_manager import FontProperties
font=FontProperties(fname='C:/Windows/Fonts/msyh.ttc')
plt.rcParams.update({'font.family':font.get_name(),'axes.unicode_minus':False})
with (out/'display.csv').open() as f: records={r['stage']:r for r in csv.DictReader(f)}
assert len(records)==16
images={}
for name,r in records.items():
    with Image.open(out/(name+'.ppm')) as image:
        pixels=np.array(image);assert pixels.shape==(int(r['height']),int(r['width']),3)
        image.save(out/(name+'.png'))
    assert int(r['max_byte_error'])<=1
    images[name]=pixels
for name in ['ev-minus2','ev-zero','ev-plus2','omit-srgb','double-srgb','hard-clip','odd-window','portrait-window']:
    assert records[name]['spp']=='64' and records[name]['generation']=='1'
assert records['continued-68spp']['spp']=='68'
assert records['camera-reset']['generation']=='2' and records['camera-reset']['spp']=='4'
assert records['internal-resize']['generation']=='3' and records['internal-resize']['source_width']=='160'

def inside(name):
    r=records[name];x,y,w,h=[int(r[k]) for k in ['dest_x','dest_y','dest_width','dest_height']]
    return images[name][y:y+h,x:x+w].astype(np.float64)

means={n:float(inside(n).mean()) for n in ['ev-minus2','ev-zero','ev-plus2','omit-srgb','double-srgb','hard-clip']}
assert means['ev-minus2']<means['ev-zero']<means['ev-plus2']
assert means['omit-srgb']<means['ev-zero']<means['double-srgb']
# HDR=1是标尺第8列，第一行是灰度。对应Reinhard后的.5，检查真实Back Buffer码值。
anchors={}
for name in ['probe-normal','probe-omit','probe-double','probe-clip']:
    r=records[name];x,y,w,h=[int(r[k]) for k in ['dest_x','dest_y','dest_width','dest_height']]
    px=x+int((8+.5)*w/14);py=y+int(.5*h/3)
    anchors[name]=int(images[name][py,px,0])
assert abs(anchors['probe-normal']-188)<=1
assert abs(anchors['probe-omit']-128)<=1
assert abs(anchors['probe-double']-223)<=1
assert anchors['probe-clip']==255
panels=[('ev-minus2','同一份64 spp / EV −2'),('ev-zero','同一份64 spp / EV 0'),('ev-plus2','同一份64 spp / EV +2'),
        ('omit-srgb','负对照：漏掉sRGB编码'),('double-srgb','负对照：重复sRGB编码'),('hard-clip','对照：硬截断高光')]
fig,axes=plt.subplots(2,3,figsize=(12,5.6),layout='constrained')
for ax,(name,title) in zip(axes.flat,panels):ax.imshow(images[name]);ax.set_title(title);ax.axis('off')
fig.suptitle('PT.10 实际Back Buffer读回：显示改变，线性历史逐字节不变')
fig.savefig(out/'display-comparison.png',dpi=160);fig.savefig(out/'display-comparison.svg');plt.close(fig)
(out/'analysis.json').write_text(json.dumps({'mean_display_codes':means,'hdr_one_anchors':anchors,'verified_frames':len(records)},indent=2),encoding='utf-8')
print('DISPLAY ANALYSIS PASS',json.dumps({'means':means,'HDR1':anchors}))
