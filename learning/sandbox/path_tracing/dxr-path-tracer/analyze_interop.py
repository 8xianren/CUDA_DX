"""从真实读回的线性PFM评估降噪；显示变换只用于PNG，不进入误差公式。"""
from pathlib import Path
import csv, json, sys
root=Path(__file__).resolve().parent
out=root/'results/pt10-interop'
sys.path.insert(0,str(root/'../pt08-materials/results/ggx/plot_packages'))
import numpy as np
from PIL import Image
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.font_manager import FontProperties
font=FontProperties(fname='C:/Windows/Fonts/msyh.ttc')
plt.rcParams.update({'font.family':font.get_name(),'axes.unicode_minus':False})
def read(name):
    with (out/(name+'.pfm')).open('rb') as f:
        assert f.readline()==b'PF\n'
        w,h=map(int,f.readline().split());assert float(f.readline())==-1
        image=np.frombuffer(f.read(),'<f4').reshape(h,w,3)[::-1].copy()
    assert np.isfinite(image).all()
    return image
def display(image):
    t=np.maximum(image,0)/(1+np.maximum(image,0))
    s=np.where(t<=.0031308,12.92*t,1.055*t**(1/2.4)-.055)
    return np.clip(np.rint(255*s),0,255).astype(np.uint8)
reference=read('reference1024-color').astype(np.float64)
names=['oidn-guides-color','oidn-color-only-output','oidn-guides-output','reference1024-color']
titles=['原始32 spp','OIDN：仅颜色','OIDN：颜色＋特征','独立1024 spp参考']
records=[]
fig,axes=plt.subplots(2,2,figsize=(12,6.3),layout='constrained')
for ax,name,title in zip(axes.flat,names,titles):
    image=read(name);error=float(np.mean((image.astype(np.float64)-reference)**2))
    delta=(image.astype(np.float64)-reference)**2
    # 用独立参考预先定义同一亮区mask，所有候选共用；不按候选误差挑选有利区域。
    bright=np.max(reference,axis=2)>2
    records.append({'case':name,'linear_rgb_mse':error,
        'reference_max_rgb_le2_mse':float(np.mean(delta[~bright])),
        'reference_max_rgb_gt2_mse':float(np.mean(delta[bright])),
        'bright_pixel_fraction':float(np.mean(bright)),
        'bright_squared_error_fraction':float(delta[bright].sum()/delta.sum()) if delta.sum()>0 else 0})
    preview=display(image);Image.fromarray(preview).save(out/(name+'.png'))
    ax.imshow(preview);ax.set_title(f'{title} / MSE {error:.6g}');ax.axis('off')
fig.suptitle('PT.10：同一物理历史，CUDA/OIDN外部消费者，统一显示曲线')
fig.savefig(out/'denoise-comparison.png',dpi=160);plt.close(fig)
albedo=read('oidn-guides-albedo');normal=read('oidn-guides-normal');depth=read('oidn-guides-depth')
assert (albedo>=0).all() and (albedo<=1.00001).all()
assert (np.linalg.norm(normal,axis=2)<=1.0001).all()
fig,axes=plt.subplots(1,3,figsize=(12,3),layout='constrained')
axes[0].imshow(np.clip(albedo,0,1));axes[0].set_title('线性albedo，直接数值预览')
axes[1].imshow(np.clip(normal*.5+.5,0,1));axes[1].set_title('平均世界法线，映射[-1,1]→[0,1]')
axes[2].imshow(depth[:,:,0],cmap='viridis');axes[2].set_title('命中条件下的平均view-z')
for ax in axes:ax.axis('off')
fig.savefig(out/'guide-comparison.png',dpi=160);plt.close(fig)
with (out/'interop.csv').open() as f: timeline=list(csv.DictReader(f))
assert len(timeline)==8
for r in timeline:assert int(r['done'])==int(r['ready'])+1
# 先报告实测，不预设“加guides一定更好”；降噪引入偏差，单图MSE不等于一般质量保证。
summary={'metrics':records,'oidn':'2.5.0 CUDA','reference':'independent seed 73, 1024 spp',
         'guide_normal_length_min':float(np.linalg.norm(normal,axis=2).min()),
         'partial_coverage_pixels':int(np.count_nonzero((depth[:,:,1]>0)&(depth[:,:,1]<1))),
         'notes':'MSE against finite noisy reference; CUDA times include validation and debug environment, not production benchmark.'}
(out/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(summary,ensure_ascii=False,indent=2))
