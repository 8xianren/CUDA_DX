"""固定曝光展示CPU几何场景的线性RGB结果；不在显示码值上计算误差。"""
from pathlib import Path
import csv
import sys
lesson = Path(__file__).resolve().parent
# 复用PT.9已经安装并验证的绘图依赖，不下载或更改全局Python环境。
sys.path.insert(0, str(lesson.parent/'cuda-path-tracer/build/python-deps'))
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
root = lesson/'results/direct'
rows = list(csv.DictReader((root/'pixels.csv').open(encoding='utf-8')))
meta = dict(line.split('=',1) for line in (root/'checks.txt').read_text().splitlines())
w,h = int(meta['width']),int(meta['height'])
def frame(scene,method,prefix):
    group=sorted((r for r in rows if r['scene']==scene and r['method']==method),key=lambda r:int(r['pixel']))
    assert len(group)==w*h
    value=np.array([[float(r[prefix+'_'+c]) for c in 'rgb'] for r in group]).reshape(h,w,3)
    assert np.all(np.isfinite(value)) and np.all(value>=0)
    # 固定Reinhard加一次sRGB，仅用于展示；所有数值验收用原始线性CSV。
    value=value/(1+value)
    return np.where(value<=.0031308,12.92*value,1.055*value**(1/2.4)-.055)
for mode in ['noisy','mean']:
    fig,axes=plt.subplots(2,5,figsize=(13,5.2),constrained_layout=True)
    for a,scene in enumerate(['open','blocked']):
        for b,method in enumerate(['reference','NEE1','MIS2','RIS8','wrong-no-visibility']):
            data=frame(scene,'NEE1','ref') if method=='reference' else frame(scene,method,mode)
            ax=axes[a,b];ax.imshow(data,origin='lower',interpolation='nearest');ax.axis('off')
            ax.set_title(scene+' / '+method,fontsize=9)
    fig.suptitle('Direct lighting: '+('one trial' if mode=='noisy' else '4096-trial means')+'; shared exposure\nMIS: 2 techniques; RIS: 8 cheap candidates, 1 final visibility; CPU analytic geometry',fontsize=10)
    fig.savefig(root/f'{mode}-comparison.png',dpi=160);plt.close(fig)
print('DIRECT LIGHTING PLOTS PASS: finite RGB, complete grids, shared exposure')
