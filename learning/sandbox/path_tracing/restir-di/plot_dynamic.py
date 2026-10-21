"""显示同一当前帧的亮度参考、正确均值与使用旧遮挡几何的错误均值。"""
from pathlib import Path
import csv
import sys
lesson = Path(__file__).resolve().parent
sys.path.insert(0, str(lesson.parent / 'cuda-path-tracer/build/python-deps'))
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
root = lesson / 'results/dynamic'
with (root / 'pixels.csv').open(encoding='utf-8') as f:
    rows = [r for r in csv.DictReader(f) if int(r['frame']) == 3]
with (root / 'stale-visibility.csv').open(encoding='utf-8') as f:
    stale = sorted(csv.DictReader(f), key=lambda r: int(r['pixel']))
rows.sort(key=lambda r: int(r['pixel']))
assert len(rows) == len(stale) == 96
# 所有格子共用线性亮度范围，禁止每幅自动曝光掩盖错误；统计量来自独立run。
weights = [.2126, .7152, .0722]
arrays = [np.array([sum(float(r[p+'_'+c])*w for c,w in zip('rgb',weights))
                   for r in rows]).reshape(8,12) for p in ['ref','mean']]
arrays.append(np.array([float(r['stale_mean']) for r in stale]).reshape(8,12))
assert all(np.isfinite(a).all() and (a >= 0).all() for a in arrays)
fig, axes = plt.subplots(1,3,figsize=(11,3.8),constrained_layout=True)
for ax,a,title in zip(axes,arrays,['Current reference','Current visibility / 256 runs','OLD visibility / 256 runs']):
    im=ax.imshow(a,origin='lower',interpolation='nearest',vmin=0,vmax=max(v.max() for v in arrays),cmap='magma')
    ax.set_title(title,fontsize=10); ax.set(xlabel='Pixel x',ylabel='Pixel y')
fig.colorbar(im,ax=axes,label='Linear luminance',shrink=.8)
fig.suptitle('Frame index 3: blocker moved; all 96 temporal histories accepted')
fig.savefig(root/'visibility-comparison.png',dpi=160)
plt.close(fig)
print('DYNAMIC PLOT PASS')
