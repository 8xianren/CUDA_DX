"""展示均值及跨独立试验的标准误；错误算法的期望也由确定性求积给出。"""
from pathlib import Path
import csv
import sys
lesson=Path(__file__).resolve().parent
sys.path.insert(0,str(lesson.parent/'cuda-path-tracer/build/python-deps'))
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
root=lesson/'results/gi'
with (root/'statistics.csv').open(encoding='utf-8') as f:
    rows=list(csv.DictReader(f))
fig,axes=plt.subplots(1,3,figsize=(12,4),constrained_layout=True)
for k,ax in enumerate(axes):
    r=[v for v in rows if int(v['destination'])==k]
    ax.errorbar(range(5),[float(v['mean']) for v in r],yerr=[6*float(v['se']) for v in r],fmt='o',label='MC mean +/- 6 SE')
    ax.scatter(range(5),[float(v['method_expectation']) for v in r],marker='x',color='black',label='Method expectation')
    ax.axhline(float(r[0]['reference']),color='green',linestyle='--',label='Physical reference')
    ax.set_xticks(range(5),['Area16','J','Area reuse','No J','1/J'],rotation=30)
    ax.set(title=f'Receiver z = {k*.5:g}',ylabel='Two-scattering radiance')
    ax.grid(alpha=.2)
axes[0].legend(fontsize=8)
fig.suptitle('GI reconnection: 100,000 independent trials per receiver')
fig.savefig(root/'jacobian-comparison.png',dpi=160)
plt.close(fig)
print('GI PLOT PASS')
