"""读取真实DXR线性HDR结果，检验模式统计并生成预览与比较图。
这里的Reinhard+sRGB仅用于看图，原始PFM和MSE始终使用线性浮点；PT.10再系统处理显示。
"""
from pathlib import Path
import json, math, sys
root=Path(__file__).resolve().parent;out=root/'results/pt08'
sys.path.insert(0,str(root/'../pt08-materials/results/ggx/plot_packages'))
import numpy as np
from PIL import Image
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.font_manager import FontProperties
font=FontProperties(fname='C:/Windows/Fonts/msyh.ttc')
plt.rcParams.update({'font.family':font.get_name(),'font.size':10,'axes.unicode_minus':False})
def image(name):
    with (out/name/'radiance.pfm').open('rb') as f:
        assert f.readline()==b'PF\n';w,h=map(int,f.readline().split());assert float(f.readline())==-1
        a=np.frombuffer(f.read(),dtype='<f4').reshape(h,w,3)[::-1].copy()
    assert np.isfinite(a).all() and (a>=0).all()
    return a
def display(a):
    t=a/(1+a)
    srgb=np.where(t<=.0031308,12.92*t,1.055*np.maximum(t,0)**(1/2.4)-.055)
    return np.clip(np.rint(srgb*255),0,255).astype(np.uint8)
names=['primary','direct','mis','bsdf','double','rr','reference','no-light']
summaries={n:json.loads((out/n/'summary.json').read_text()) for n in names}
images={n:image(n) for n in names}
for n,a in images.items():Image.fromarray(display(a)).save(out/n/'preview.png')
weights=np.array([.2126,.7152,.0722])
def luminance(s):return float(np.dot(s['mean_rgb'],weights))
for n,s in summaries.items():
    assert s['invalid']==0 and s['nonfinite']==0 and s['primary_audits']==64
    if n!='primary':assert s['delta']>0 and s['transmissions']>0
# 不把像素间的空间亮度变化当作噪声。SE来自每像素路径的一阶/二阶矩再合并。
for n in ['mis','bsdf','rr']:
    s,r=summaries[n],summaries['reference']
    diff=abs(luminance(s)-luminance(r));se=math.hypot(s['mean_luminance_se'],r['mean_luminance_se'])
    assert diff<6*se+.0005,(n,diff,se)
assert luminance(summaries['double'])>luminance(summaries['mis'])+.02,'missing double-counting negative control'
assert luminance(summaries['mis'])>luminance(summaries['direct'])+.005,'indirect transport missing'
assert luminance(summaries['no-light'])<luminance(summaries['mis'])*.1,'light disable did not remove light energy'
assert summaries['rr']['rays']<summaries['mis']['rays'] and summaries['rr']['rr_killed']>0
metrics={}
for n in ['direct','mis','bsdf','double','rr']:
    delta=images[n].astype(np.float64)-images['reference']
    metrics[n]={'linear_rgb_mse':float(np.mean(delta*delta)),'mean_luminance':luminance(summaries[n]),'mean_luminance_se':summaries[n]['mean_luminance_se'],'rays':summaries[n]['rays']}
(out/'comparison.json').write_text(json.dumps(metrics,indent=2),encoding='utf-8')
fig,axs=plt.subplots(2,2,figsize=(15,8.3),layout='constrained')
for ax,name,title in zip(axs.flat,['direct','mis','bsdf','double'],['K=1：直接光与一次散射','K=8：NEE + Power MIS','K=8：仅BSDF采样','反例：NEE与命中灯重复计数']):
    ax.imshow(display(images[name]));ax.set_title(title);ax.axis('off')
fig.suptitle('PT.8 真实DXR：粗糙度扫描、镜面与封闭玻璃（每图256 spp）',fontsize=16)
fig.savefig(out/'gallery-comparison.png',dpi=150);fig.savefig(out/'gallery-comparison.svg')
fig2,ax=plt.subplots(figsize=(14,7),layout='constrained');ax.imshow(display(images['reference']));ax.axis('off')
ax.set_title('上排：金属；下排：非金属；两侧：IOR 1.5玻璃\n从左到右 r = 0 / 0.02 / 0.08 / 0.2 / 0.4 / 0.7 / 1；1024 spp，K=8',fontsize=14)
fig2.savefig(out/'gallery-reference.png',dpi=160)
print('GALLERY PASS:',json.dumps(metrics))
