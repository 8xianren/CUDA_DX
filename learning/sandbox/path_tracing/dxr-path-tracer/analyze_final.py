"""PT.10整章质量/性能报告。指标来自线性读回，计时来自GPU query/event，不用PNG估计误差。"""
from pathlib import Path
import csv,json,sys
root=Path(__file__).resolve().parent;out=root/'results/pt10-final';data=out/'benchmark'
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
    with (data/(name+'.pfm')).open('rb') as f:
        assert f.readline()==b'PF\n';w,h=map(int,f.readline().split());assert float(f.readline())==-1
        a=np.frombuffer(f.read(),'<f4').reshape(h,w,3)[::-1].astype(np.float64)
    assert np.isfinite(a).all() and (a>=0).all();return a
def display(a):
    t=a/(1+a);s=np.where(t<=.0031308,12.92*t,1.055*t**(1/2.4)-.055)
    return np.clip(np.rint(s*255),0,255).astype(np.uint8)
def rows(path):
    with path.open(encoding='utf-8-sig') as f:return list(csv.DictReader(f))
quality=[];references={w:read(f'reference-w{w}-color') for w in (192,384)}
source_rows=rows(data/'quality.csv');assert len(source_rows)==24
for row in source_rows:
    w=int(row['width']);spp=int(row['spp']);ref=references[w];bright=np.max(ref,axis=2)>2
    for name,suffix in [('raw','color'),('color','coloronly'),('guides','output')]:
        a=read(row['prefix']+'-'+suffix);assert a.shape==ref.shape
        error=(a-ref)**2
        quality.append({'width':w,'seed':int(row['seed']),'spp':spp,'consumer':name,
            'mse':float(error.mean()),'nonbright_mse':float(error[~bright].mean()),'bright_mse':float(error[bright].mean()),
            'rays':int(row['rays'])})
aggregates=[]
fig,axes=plt.subplots(1,2,figsize=(11,4),layout='constrained')
for ax,w in zip(axes,(192,384)):
    for name,label in [('raw','原始'),('color','OIDN仅颜色'),('guides','OIDN含特征')]:
        means=[];lows=[];highs=[]
        for spp in (4,16,64,256):
            group=[q for q in quality if q['width']==w and q['spp']==spp and q['consumer']==name]
            assert len(group)==3;values=[q['mse'] for q in group];mean=float(np.mean(values));means.append(mean);lows.append(min(values));highs.append(max(values))
            aggregates.append({'width':w,'height':w//2,'spp':spp,'consumer':name,'mse_mean':mean,'mse_seed_min':min(values),'mse_seed_max':max(values),
                'nonbright_mse_mean':float(np.mean([q['nonbright_mse'] for q in group])),
                'bright_mse_mean':float(np.mean([q['bright_mse'] for q in group]))})
        ax.loglog((4,16,64,256),means,'o-',label=label);ax.fill_between((4,16,64,256),lows,highs,alpha=.12)
    raw=[a for a in aggregates if a['width']==w and a['consumer']=='raw']
    assert raw[-1]['mse_mean']<raw[0]['mse_mean']*.2
    ax.set_title(f'{w}×{w//2} / 3个输入种子');ax.set_xlabel('每像素样本数');ax.set_ylabel('线性RGB MSE');ax.grid(alpha=.2);ax.legend()
fig.suptitle('各分辨率分别对独立1024 spp参考；阴影为3种子的最小/最大值')
fig.savefig(out/'quality-curves.png',dpi=160);plt.close(fig)
timings=rows(data/'timings.csv');assert len(timings)==54
times_summary=[]
fields=['render_ms','pack_ms','handoff_ms','display_copy_ms','readback_ms','cuda_ms','cpu_wall_ms']
for w in (192,384):
    all_rays=set()
    for name in ('raw','color','guides'):
        group=[t for t in timings if int(t['width'])==w and t['consumer']==name];assert len(group)==9
        all_rays.update(int(t['rays']) for t in group)
        entry={'width':w,'height':w//2,'consumer':name,'samples':9,'rays_per_32spp':int(group[0]['rays'])}
        for field in fields:
            v=np.array([float(t[field]) for t in group]);assert np.isfinite(v).all() and (v>=0).all()
            entry[field]={'median':float(np.median(v)),'min':float(v.min()),'max':float(v.max())}
        total=[sum(float(t[k]) for k in fields[:5]) for t in group]
        entry['queue_interval_ms_median']=float(np.median(total))
        entry['local_usage_bytes_max_sampled']=max(int(t['local_usage_bytes']) for t in group)
        times_summary.append(entry)
    assert len(all_rays)==1 # 同分辨率同样本的三个消费者不应改变积分器路径数。
# 可视化最终384×192、16spp的三种输出与各自同分辨率参考；选择固定种子0，避免挑有利结果。
fig,axes=plt.subplots(2,2,figsize=(12,6.4),layout='constrained')
names=['w384-seed0-spp16-color','w384-seed0-spp16-coloronly','w384-seed0-spp16-output','reference-w384-color']
for ax,name,label in zip(axes.flat,names,['原始16spp','OIDN仅颜色','OIDN含特征','独立1024spp参考']):
    ax.imshow(display(read(name)));ax.set_title(label);ax.axis('off')
fig.savefig(out/'quality-images.png',dpi=160);plt.close(fig)
# 展示窗口真实读回；文件已包含曝光/sRGB，不再套一遍显示变换。
fig,axes=plt.subplots(1,3,figsize=(12,3),layout='constrained')
for ax,name in zip(axes,('raw','guided','exposure')):
    with Image.open(out/'window'/(name+'.ppm')) as im:ax.imshow(np.array(im))
    ax.set_title(name);ax.axis('off')
fig.savefig(out/'window-comparison.png',dpi=160);plt.close(fig)
window=rows(out/'window/window.csv');assert len(window)==10
assert max(int(r['max_byte_error']) for r in window)<=1
assert all(int(r['spp'])==32 and int(r['generation'])==1 for r in window[:7])
assert [(int(r['spp']),int(r['generation'])) for r in window[7:]]==[(4,2),(4,3),(4,4)]
report={'quality':aggregates,'timings':times_summary,'memory':rows(data/'memory.csv'),
    'reference':'seed73,1024spp per resolution; finite noisy reference',
    'timing_contract':'Debug/GBV off in a separate process; 3 warmups+9 measured; 32spp reset per repetition; same shader; headless synchronous readback. CUDA interval is nested inside handoff interval, do not add twice.',
    'scope':'fixed gallery, K8, flat geometric normals, nonnested teaching glass, no absorption, no temporal denoising; sampled process memory is not peak or exclusive OIDN allocation.'}
(out/'summary.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
for a in aggregates:print('QUALITY',a)
for t in times_summary:print('TIMING',json.dumps(t,ensure_ascii=False))
print('FINAL ANALYSIS PASS')
