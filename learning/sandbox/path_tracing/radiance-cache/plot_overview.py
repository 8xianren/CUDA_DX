"""课程示意图：缓存替换路径后缀；探针插值是实现缓存函数的一种方式。"""
from pathlib import Path
import sys
lesson=Path(__file__).resolve().parent
sys.path.insert(0,str(lesson.parent/'cuda-path-tracer/build/python-deps'))
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch
out=lesson/'results/overview'
out.mkdir(parents=True,exist_ok=True)
fig,axes=plt.subplots(3,1,figsize=(11,7.8),constrained_layout=True)
def box(ax,x,y,text,color='#dbeafe',width=1.65):
    ax.add_patch(FancyBboxPatch((x-width/2,y-.22),width,.44,boxstyle='round,pad=.04',facecolor=color,edgecolor='#334155'))
    ax.text(x,y,text,ha='center',va='center',fontsize=11)
def arrow(ax,a,b):
    ax.annotate('',xy=b,xytext=a,arrowprops={'arrowstyle':'->','color':'#475569','lw':1.5})
for ax in axes: ax.set(xlim=(0,10),ylim=(0,2));ax.axis('off')
ax=axes[0];ax.set_title('1. Full path estimator: explicitly sample the remaining transport',loc='left',weight='bold')
for x,label in [(1,'Camera'),(3,'Prefix'),(5,'State S'),(7,'More bounces'),(9,'Light')]:box(ax,x,1.15,label)
for x in [1,3,5,7]:arrow(ax,(x+.88,1.15),(x+1.1,1.15))
ax.text(5,.35,r'$\widehat I_{\rm full}=A+\beta\,\widehat L_{\rm tail}(S)$',ha='center',fontsize=16)
ax=axes[1];ax.set_title('2. Cache termination: replace the remaining transport by a function query',loc='left',weight='bold')
for x,label in [(1,'Camera'),(3,'Prefix'),(5,'State S')]:box(ax,x,1.15,label)
box(ax,8,1.15,'Cache C(S)',color='#dcfce7',width=2)
for a,b in [(1.88,2.1),(3.88,4.1),(5.88,6.9)]:arrow(ax,(a,1.15),(b,1.15))
ax.text(5,.35,r'$\widehat I_{\rm cache}=A+\beta\,C(S)\qquad \Delta I=\mathbb{E}[\beta(C-L_{\rm tail})]$',ha='center',fontsize=16)
ax=axes[2];ax.set_title('3. Probe interpolation: construct C(S) from nearby directional records',loc='left',weight='bold')
for x,label in [(1.5,'Probe 0'),(4,'Probe 1'),(6.5,'Probe 2')]:
    box(ax,x,1.3,label,color='#fef3c7');arrow(ax,(x,1.03),(4,.72))
box(ax,4,.45,'Weighted interpolation',color='#dcfce7',width=3)
box(ax,8.7,.45,'C(S)',color='#dcfce7',width=1.2);arrow(ax,(5.6,.45),(8,.45))
ax.text(8.7,1.4,'Position + direction\nidentify the query',ha='center',fontsize=11)
fig.savefig(out/'path-cache-probes.png',dpi=160)
plt.close(fig)
print('CACHE OVERVIEW PLOT PASS')
