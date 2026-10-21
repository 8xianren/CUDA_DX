"""从实际验收CSV生成图：左侧CPU表外积分误差，右侧真实GPU白炉统计。不是渲染器截图。"""
from pathlib import Path
import csv, math, sys
root = Path(__file__).resolve().parent
out = root / 'results/energy-gpu'
sys.path.insert(0, str(root / 'results/ggx/plot_packages'))
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.font_manager import FontProperties
font = FontProperties(fname='C:/Windows/Fonts/msyh.ttc')
plt.rcParams.update({'font.family': font.get_name(), 'font.size': 11, 'axes.unicode_minus': False})
def read(path):
    with path.open(encoding='utf-8') as f:
        return list(csv.DictReader(f))
def aggregate(rows, angle, mode):
    group = [r for r in rows if int(r['tile']) == 0 and float(r['angle']) == angle and int(r['mode']) == mode]
    n = sum(int(r['samples']) for r in group)
    mean = sum(int(r['samples'])*float(r['r_mean']) for r in group)/n
    m2 = sum((int(r['samples'])-1)*int(r['samples'])*float(r['r_SE'])**2 + int(r['samples'])*(float(r['r_mean'])-mean)**2 for r in group)
    return mean, math.sqrt(m2/(n-1)/n), float(group[0]['r_reference'])
offgrid = read(out/'offgrid.csv')
good = read(out/'summary.csv')
bad = read(out/'negative-baseline/summary.csv')
fig, (left, right) = plt.subplots(1, 2, figsize=(14, 5.3), layout='constrained')
sc = left.scatter([float(p['roughness']) for p in offgrid], [float(p['cosine']) for p in offgrid],
                  c=[float(p['error'])*1e4 for p in offgrid], s=17, cmap='viridis', vmin=0, vmax=3)
left.set(xscale='log', yscale='log', xlabel='roughness（对数轴）', ylabel='方向余弦（对数轴）', title='512个表外点：独立加密积分与float表的差')
fig.colorbar(sc, ax=left, label='绝对误差 × 10⁴')
angles = [0, 60, 80]
for rows, mode, label, color in [(good, 0, '修正 GPU，p_s=0.5', '#177e89'), (good, 1, '修正 GPU，p_s=0.8', '#3c5eaa'), (bad, 0, '原模型 GPU，p_s=0.5', '#b2453f')]:
    values = [aggregate(rows, a, mode) for a in angles]
    right.errorbar(angles, [v[0] for v in values], yerr=[3*v[1] for v in values], fmt='o-', capsize=3, label=label+' ±3SE', color=color)
right.plot(angles, [aggregate(good, a, 0)[2] for a in angles], 'k:', label='修正模型独立积分，约1')
right.set(xlabel='观察角（度）', ylabel='白炉输出（红通道）', title='RTX 5070：白色非金属 r=0.25', xticks=angles)
right.legend(frameon=False, fontsize=9)
for ax in [left, right]:
    ax.grid(alpha=.2)
fig.suptitle('PT.8 能量表接入GPU：插值误差与真实射线验收', fontsize=16)
fig.savefig(out/'energy-gpu.png', dpi=160)
fig.savefig(out/'energy-gpu.svg')
print(out/'energy-gpu.png')
