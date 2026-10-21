"""逐帧展示跨独立run的方差；连续帧不作为独立样本混算。"""
from pathlib import Path
import csv
import json
import sys
lesson=Path(__file__).resolve().parent
sys.path.insert(0,str(lesson.parent/'cuda-path-tracer/build/python-deps'))
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
root=lesson/'results/reuse'
rows=list(csv.DictReader((root/'frames.csv').open(encoding='utf-8')))
fig,axes=plt.subplots(1,2,figsize=(11,4.2),constrained_layout=True)
for ax,scene in zip(axes,['open','blocked']):
 for mode in ['fresh','temporal','spatial','both']:
  r=[v for v in rows if v['scene']==scene and v['mode']==mode]
  assert len(r)==16 and all(int(v['failed_pixels'])==0 for v in r)
  ax.plot([int(v['frame'])+1 for v in r],[float(v['mean_variance']) for v in r],'.-',label=mode)
 ax.set(title=scene,xlabel='Frame',ylabel='Mean pixel luminance variance',yscale='log');ax.grid(alpha=.2);ax.legend()
fig.suptitle('Static reuse: 256 independent runs at each frame; no color-history averaging')
fig.savefig(root/'variance-curves.png',dpi=160);plt.close(fig)
rows=list(csv.DictReader((root/'pixels.csv').open(encoding='utf-8')))
def reference_luma(scene):
 return {int(r['pixel']):sum(float(r['ref_'+c])*k for c,k in zip('rgb',[.2126,.7152,.0722]))
         for r in rows if r['scene']==scene and r['mode']=='fresh'}
open_ref,blocked_ref=reference_luma('open'),reference_luma('blocked')
# 这是理想样本密度t/Z、归一化Z已知时的一次可见性估计方差，不是通用算法下界。
visibility_model=sum(blocked_ref[p]*(open_ref[p]-blocked_ref[p]) for p in open_ref)/len(open_ref)
(root/'visibility-model.json').write_text(json.dumps({'assumption':'one draw from exact unoccluded luminance target / Z; known Z; not universal variance lower bound',
 'mean_luminance_variance':visibility_model},indent=2),encoding='utf-8')
meta=dict(line.split('=',1) for line in (root/'checks.txt').read_text().splitlines())
w,h=int(meta['width']),int(meta['height'])
fig,axes=plt.subplots(2,5,figsize=(12,5),constrained_layout=True)
for a,scene in enumerate(['open','blocked']):
 for b,mode in enumerate(['reference','fresh','temporal','spatial','both']):
  selected=sorted((r for r in rows if r['scene']==scene and r['mode']==('fresh' if mode=='reference' else mode)),key=lambda r:int(r['pixel']))
  prefix='ref' if mode=='reference' else 'noisy'
  rgb=np.array([[float(r[prefix+'_'+c]) for c in 'rgb'] for r in selected]).reshape(h,w,3)
  assert np.all(np.isfinite(rgb)) and np.all(rgb>=0)
  mapped=rgb/(1+rgb);mapped=np.where(mapped<=.0031308,12.92*mapped,1.055*mapped**(1/2.4)-.055)
  ax=axes[a,b];ax.imshow(mapped,origin='lower',interpolation='nearest');ax.axis('off');ax.set_title(scene+' / '+mode,fontsize=9)
fig.suptitle('One run, frame 16; 8 fresh candidates per pixel per frame; same exposure')
fig.savefig(root/'frame16.png',dpi=160);plt.close(fig)
print('REUSE PLOTS PASS')
