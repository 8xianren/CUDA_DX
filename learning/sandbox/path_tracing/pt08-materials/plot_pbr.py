"""读取GPU统计CSV画采样策略与能量反例；不是把参考公式画成“GPU渲染截图”。
沿用上节隔离的matplotlib依赖，将四象限同材质样本按样本数合并均值和方差。
"""
from pathlib import Path
import sys, csv, math
root=Path(__file__).resolve().parent
out=root/'results/pbr'
sys.path.insert(0,str(root/'results/ggx/plot_packages'))
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.font_manager import FontProperties
font=FontProperties(fname='C:/Windows/Fonts/msyh.ttc')
plt.rcParams.update({'font.family':font.get_name(),'font.size':11,'axes.unicode_minus':False})
with (out/'summary.csv').open(encoding='utf-8') as f: rows=list(csv.DictReader(f))
def aggregate(tile, angle, mode, wrong=False):
    selected=[r for r in rows if int(r['tile'])==tile and float(r['angle'])==angle and int(r['mode'])==mode]
    mean_name,se_name=('wrong_selected_pdf_r','wrong_SE') if wrong else ('r_mean','r_SE')
    count=sum(int(r['samples']) for r in selected)
    mean=sum(int(r['samples'])*float(r[mean_name]) for r in selected)/count
    m2=sum((int(r['samples'])-1)*int(r['samples'])*float(r[se_name])**2+int(r['samples'])*(float(r[mean_name])-mean)**2 for r in selected)
    return mean,math.sqrt(m2/(count-1)/count),float(selected[0]['r_reference'])
angles=[0,60,80]
fig,(left,right)=plt.subplots(1,2,figsize=(13.8,5.4),layout='constrained')
for ax,tile,title in [(left,0,'白色非金属：采样正确，但基线耦合增加能量'),(right,5,'混合材质：采样概率改变噪声，不改变目标')]:
    for mode in [0,1]:
        values=[aggregate(tile,a,mode) for a in angles]
        ax.errorbar(angles,[v[0] for v in values],yerr=[3*v[1] for v in values],fmt='o-',capsize=3,
                    label=f'GPU：p_s={.5 if mode==0 else .8:g}，±3SE')
    ax.plot(angles,[aggregate(tile,a,0)[2] for a in angles],'kx--',label='独立方向积分')
    ax.set(xlabel='观察角（度）',ylabel='白炉红通道输出',title=title,xticks=angles)
    ax.grid(alpha=.2)
left.axhline(1,color='#b2453f',linestyle=':',label='无额外能量的上界 1')
left.set_ylim(.94,1.33)
wrong=[aggregate(5,a,0,True) for a in angles]
right.errorbar(angles,[v[0] for v in wrong],yerr=[3*v[1] for v in wrong],fmt='s-',color='#b2453f',capsize=3,label='错误：总BRDF / 选中分支PDF')
right.plot(angles,[2*aggregate(5,a,0)[2] for a in angles],':',color='#666666',label='错误估计器的理论目标：2倍积分')
for ax in [left,right]:ax.legend(frameon=False,fontsize=9)
fig.suptitle('PT.8 RTX 5070实测：glTF材质与混合采样',fontsize=16)
fig.savefig(out/'pbr-mixture.png',dpi=160)
fig.savefig(out/'pbr-mixture.svg')
print(out/'pbr-mixture.png')
