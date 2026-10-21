"""分别画均值误差和方差，避免把平滑当正确；确定性格点控制组隔离更新噪声。"""
from pathlib import Path
import csv,json,sys
lesson=Path(__file__).resolve().parent
sys.path.insert(0,str(lesson.parent/'cuda-path-tracer/build/python-deps'))
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
root=lesson/'results/cache'
with (root/'statistics.csv').open(encoding='utf-8') as f: rows=list(csv.DictReader(f))
methods=['full-tail','cache3-trained','cache9-trained','cache3-exact-nodes','cache9-exact-nodes']
fig,axes=plt.subplots(1,3,figsize=(14,4.6),constrained_layout=True)
summary={}
for method in methods:
    r=[v for v in rows if v['method']==method];x=[float(v['x']) for v in r]
    style='--' if 'exact' in method else '-'
    axes[0].errorbar(x,[float(v['mean']) for v in r],yerr=[6*float(v['se']) for v in r],fmt=style+'o',label=method,markersize=3)
    axes[1].plot(x,[float(v['expected_bias']) for v in r],style+'o',label=method,markersize=3)
    axes[2].plot(x,[float(v['variance']) for v in r],style+'o',label=method,markersize=3)
    # 样本方差乘(N-1)/N再加经验均值误差平方，得到同批样本对参考的平均平方误差。
    summary[method]={'mean_variance':sum(float(v['variance']) for v in r)/5,
        'empirical_mse':sum(float(v['variance'])*4095/4096+float(v['empirical_bias'])**2 for v in r)/5,
        'expected_bias_rms':(sum(float(v['expected_bias'])**2 for v in r)/5)**.5}
r=[v for v in rows if v['method']=='full-tail']
axes[0].plot([float(v['x']) for v in r],[float(v['physical_reference']) for v in r],'k:',label='Physical reference')
axes[0].set(ylabel='Radiance mean +/- 6 SE',title='Same two-scattering integral')
axes[1].set(ylabel='Integral of cache minus physical reference',title='Spatial approximation bias')
axes[2].set(ylabel='Variance of 64-path estimate',yscale='log',title='Includes retraining in every run')
for ax in axes:ax.set_xlabel('Receiver x');ax.grid(alpha=.2)
axes[0].legend(fontsize=7)
fig.suptitle('4096 independent runs; 64 training samples per node; no GPU timing claim')
fig.savefig(root/'bias-variance.png',dpi=160);plt.close(fig)
(root/'summary.json').write_text(json.dumps(summary,indent=2),encoding='utf-8')
print('CACHE PLOT PASS')
