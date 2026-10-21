"""读取本课真实CSV生成GGX分布和白炉图，不重新运行或替换数值实验。
可选依赖matplotlib隔离安装在results/ggx/plot_packages，不修改系统Python包。
从任意目录运行python plot_ggx.py，图像直接写入本课结果目录。
"""
from pathlib import Path
import csv
import sys

out = Path(__file__).resolve().parent / 'results/ggx'
sys.path.insert(0, str(out/'plot_packages'))
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.font_manager import FontProperties

font = FontProperties(fname='C:/Windows/Fonts/msyh.ttc')
plt.rcParams.update({'font.family': font.get_name(), 'font.size': 12, 'axes.unicode_minus': False})
with (out/'distribution.csv').open(encoding='utf-8') as f:
    rows = list(csv.DictReader(f))
with (out/'roughness.csv').open(encoding='utf-8') as f:
    scan = list(csv.DictReader(f))
with (out/'furnace.csv').open(encoding='utf-8') as f:
    measured = [r for r in csv.DictReader(f) if r['view_degrees'] == '0' and r['material'] == '0' and r['strategy'] == '0']

fig, (left, right) = plt.subplots(1, 2, figsize=(13.8, 5.5), layout='constrained')
for roughness in [.25, .5, .75, 1.]:
    selected = [r for r in rows if float(r['roughness']) == roughness and float(r['m_degrees']) <= 80]
    left.semilogy([float(r['m_degrees']) for r in selected], [float(r['D']) for r in selected],
                  label=f'roughness={roughness:g}', linewidth=2)
left.set(xlabel='微表面法线与宏观法线的夹角（度）', ylabel=r'$D(m)$', title='GGX：粗糙度改变法线分布')
left.legend(frameon=False)
left.grid(alpha=.2, which='both')

x = [float(r['roughness']) for r in scan]
y = [float(r['normal_white_mean']) for r in scan]
error = [6*float(r['SE']) for r in scan]
right.errorbar(x, y, yerr=error, fmt='o-', capsize=3, color='#2675ae', label='NDF采样均值 ± 6SE')
right.scatter([float(r['roughness']) for r in measured], [float(r['r_reference']) for r in measured],
              marker='x', s=70, linewidth=2, color='#d36828', label='独立方向积分')
right.axhline(1, color='#555555', linestyle='--', linewidth=1, label='无损完整反射的期望值')
right.annotate(r'$1-\ln 2\approx0.30685$', xy=(1, 1-__import__('math').log(2)), xytext=(.55,.17),
               arrowprops={'arrowstyle':'->','color':'#555555'}, fontsize=12)
right.set(xlabel='roughness（α = roughness²）', ylabel='白炉输出', title=r'正视、$F_0=1$：单次微反射的能量缺失', ylim=(0,1.08), xlim=(-.025,1.04))
right.legend(loc='lower left', frameon=False, fontsize=10)
right.grid(alpha=.2)
fig.suptitle('PT.8 CPU实测：GGX分布与白炉验证', fontsize=17)
fig.savefig(out/'ggx-white-furnace.png', dpi=160)
fig.savefig(out/'ggx-white-furnace.svg')
plt.close(fig)
print(out/'ggx-white-furnace.png')
