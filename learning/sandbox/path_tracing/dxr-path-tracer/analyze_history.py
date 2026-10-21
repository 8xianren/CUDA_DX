"""检查真实GPU历史的线性HDR收敛，绘图只作显示，不改变验收数据。
单次随机序列的误差不必逐帧单调；这里记录固定checkpoint和独立seed的有限样本参考。
"""
from pathlib import Path
import csv, json, sys
root=Path(__file__).resolve().parent
out=root/'results/pt10-history'
sys.path.insert(0,str(root/'../pt08-materials/results/ggx/plot_packages'))
import numpy as np
from PIL import Image
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.font_manager import FontProperties
font=FontProperties(fname='C:/Windows/Fonts/msyh.ttc')
plt.rcParams.update({'font.family':font.get_name(),'axes.unicode_minus':False})

def read(name):
    with (out/(name+'.pfm')).open('rb') as f:
        assert f.readline()==b'PF\n'
        w,h=map(int,f.readline().split());assert float(f.readline())==-1
        image=np.frombuffer(f.read(),'<f4').reshape(h,w,3)[::-1].copy()
    assert np.isfinite(image).all() and (image>=0).all()
    return image

def preview(image):
    t=image/(1+image)
    s=np.where(t<=.0031308,12.92*t,1.055*np.maximum(t,0)**(1/2.4)-.055)
    return np.clip(np.rint(s*255),0,255).astype(np.uint8)

reference=read('reference1024').astype(np.float64)
samples=[1,4,16,64,256]
records=[]
fig,axes=plt.subplots(2,3,figsize=(12,5.4),layout='constrained')
for ax,spp in zip(axes.flat,samples):
    image=read('spp'+str(spp));mse=float(np.mean((image.astype(np.float64)-reference)**2))
    records.append({'spp':spp,'linear_rgb_mse':mse})
    pixels=preview(image);Image.fromarray(pixels).save(out/f'spp{spp}.png')
    ax.imshow(pixels);ax.set_title(f'{spp} spp / 线性 MSE {mse:.5g}');ax.axis('off')
axes.flat[-1].imshow(preview(reference));axes.flat[-1].set_title('独立 seed：1024 spp 参考');axes.flat[-1].axis('off')
fig.suptitle('PT.10 持久 GPU 线性历史：相同目标、连续样本编号、无降噪')
fig.savefig(out/'history-convergence.png',dpi=160);fig.savefig(out/'history-convergence.svg');plt.close(fig)
# 检查明显收敛趋势，避免把“每增加一条样本误差都必须下降”误当作MC定理。
assert records[-1]['linear_rgb_mse']<records[0]['linear_rgb_mse']*.15
assert records[-1]['linear_rgb_mse']<records[-2]['linear_rgb_mse']
with (out/'history.csv').open() as f: resets=list(csv.DictReader(f))
assert {r['case'] for r in resets}=={'partition_2_5_6','camera','resize','material','scene','light','seed','poison_reset'}
assert all(int(r['count'])==13 and float(r['normalized_error'])<2e-5 for r in resets)
for name in ['camera','resize','material','scene','light']:
    Image.fromarray(preview(read(name))).save(out/(name+'.png'))
(out/'analysis.json').write_text(json.dumps({'convergence':records,'reset_cases':resets},indent=2),encoding='utf-8')
print('HISTORY ANALYSIS PASS',json.dumps(records))
