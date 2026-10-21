"""绘制CPU独立积分与查表实测，不将它称为GPU图像。
只读取本课CSV；matplotlib沿用GGX实验的隔离依赖目录。图和SVG直接写本节results/energy。
"""
from pathlib import Path
import csv
import sys

root = Path(__file__).resolve().parent
out = root / 'results/energy'
sys.path.insert(0, str(root / 'results/ggx/plot_packages'))
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.font_manager import FontProperties

font = FontProperties(fname='C:/Windows/Fonts/msyh.ttc')
plt.rcParams.update({'font.family': font.get_name(), 'font.size': 11, 'axes.unicode_minus': False})
with (out / 'energy.csv').open(encoding='utf-8') as f:
    lut = list(csv.DictReader(f))
with (out / 'furnace.csv').open(encoding='utf-8') as f:
    furnace = list(csv.DictReader(f))
fig, (left, right) = plt.subplots(1, 2, figsize=(13.5, 5.2), layout='constrained')
for roughness in [0, .25, .5, .75, 1]:
    row = [p for p in lut if float(p['roughness']) == roughness]
    left.plot([float(p['cosine']) for p in row], [float(p['energy']) for p in row], label=f'r={roughness:g}')
left.set(xlabel='方向余弦 c（左侧为掠射）', ylabel='镜面方向反照率 E(c)', title='先积分镜面响应，得到剩余能量预算')
left.legend(frameon=False)
row = [p for p in furnace if float(p['roughness']) == .25]
angles = [float(p['angle']) for p in row]
right.plot(angles, [float(p['original_white']) for p in row], 's-', label='原半角 Fresnel 漫反射耦合', color='#b2453f')
right.plot(angles, [float(p['corrected_white']) for p in row], 'o-', label='双侧归一化耦合', color='#177e89')
right.axhline(1, linestyle=':', color='#777777', label='白色无吸收目标 1')
right.annotate('1.268656887 → 0.999999958', xy=(80, 1), xytext=(15, 1.12),
               arrowprops={'arrowstyle': '->', 'color': '#555555'}, fontsize=11)
right.set(xlabel='观察角（度）', ylabel='白炉反射输出', title='白色非金属 r=0.25：独立完整 BRDF 积分', xticks=angles, ylim=(.97, 1.32))
right.legend(frameon=False, loc='upper left', fontsize=10)
for ax in [left, right]:
    ax.grid(alpha=.2)
fig.suptitle('PT.8 CPU 数学参考：能量守恒与互易性同时成立', fontsize=16)
fig.savefig(out / 'energy-balance.png', dpi=160)
fig.savefig(out / 'energy-balance.svg')
print(out / 'energy-balance.png')
