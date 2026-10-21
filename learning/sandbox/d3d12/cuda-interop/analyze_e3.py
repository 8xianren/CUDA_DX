"""E.3：重放槽位协议、比较固定工作量、核对统一时钟的真实GPU区间。

时间戳区间并非SM活跃周期；保留Nsight采集警告，不从这些数据推断缓存/占用率。
"""
from pathlib import Path
import csv
import json
import sqlite3
import statistics as st
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

root = Path(__file__).resolve().parent / 'results/e3'
def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))
def rows(path):
    with path.open(newline='', encoding='utf-8-sig') as f:
        return list(csv.DictReader(f))

summary = {'timing': [], 'traces': {}, 'validation': [], 'limitations': [
    'Finite pre-recorded batches, not a window frame pacing benchmark.',
    'CUDA event elapsed intervals may contain scheduling delays, not just kernel execution.',
    'Trace interval gaps do not prove whole-GPU idle; other applications may run.',
    'Nsight incomplete-event warnings retained; no hardware-counter causal attribution.'
]}
def replay(folder):
    s = read(folder / 'summary.json')
    assert s['pass'] and s['mismatches'] == 0
    assert s['ready'] == s['consumed'] == s['frames']*(s['warmups']+s['rounds'])
    trace = rows(folder / 'fences.csv')
    assert len(trace) == s['ready']
    for i, row in enumerate(trace):
        b, f = divmod(i, s['frames'])
        expected = (b, f, f % s['slots'], i-s['slots']+1 if f >= s['slots'] else 0, i+1, i+1)
        assert tuple(map(int, row.values())) == expected
    return s

for n in (1, 2, 3):
    s = replay(root / f'validate-{n}')
    assert s['debug_enabled'] and s['pixels_checked'] > 1_000_000 and s['bytes_checked'] == 14208
    summary['validation'].append(s)
assert len({s['image_hash'] for s in summary['validation']}) == 1
assert len({s['simulation_hash'] for s in summary['validation']}) == 1

for workload in ('cuda-heavy', 'graphics-heavy', 'balanced'):
    hashes, simulation_hashes = set(), set()
    for n in (1, 2, 3):
        samples = []
        for repeat in range(3):
            folder = root / f'perf-{workload}-{n}-{repeat}'
            s = replay(folder)
            assert not s['debug_enabled'] and s['frames'] == 48 and s['present_calls'] == 0
            assert s['simulation_values_checked'] == 16384 and s['bytes_checked'] == 592
            hashes.add(s['image_hash']); simulation_hashes.add(s['simulation_hash'])
            samples.extend(rows(folder / 'timing.csv'))
        assert len(samples) == 15
        entry = {'workload': workload, 'slots': n, 'samples': len(samples),
                 'allocation_bytes': s['shared_allocation_bytes'], 'cuda_substeps': s['cuda_substeps'],
                 'pixel_iterations': s['pixel_iterations'], 'image_hash':s['image_hash'],
                 'simulation_hash':s['simulation_hash']}
        for field in ('wall_ms','cpu_submit_ms','cpu_final_wait_ms','cuda_sum_ms','d3d_sum_ms','d3d_span_ms'):
            values = [float(x[field]) for x in samples]
            entry[field] = {'median': st.median(values), 'min': min(values), 'max': max(values)}
        summary['timing'].append(entry)
    assert len(hashes) == len(simulation_hashes) == 1, 'slots must not change output'

timelines = {}
for n in (1, 2, 3):
    profiled = replay(root / f'profile-{n}')
    baseline = next(s for s in summary['timing'] if s['workload']=='balanced' and s['slots']==n)
    assert profiled['image_hash']==baseline['image_hash'] and profiled['simulation_hash']==baseline['simulation_hash']
    db = sqlite3.connect((root / f'nsys-{n}.sqlite').as_uri()+'?mode=ro', uri=True)
    # DX12的捕获可能含负时间的预热记录，必须用实际NVTX测量边界过滤，不能直接取整表前48行。
    batch = db.execute("select start,end from NVTX_EVENTS where text='E3 measured batch'").fetchall()
    assert len(batch) == 1 and batch[0][1] is not None
    a, b = batch[0]
    kernels = db.execute('''select k.start,k.end,s.value from CUPTI_ACTIVITY_KIND_KERNEL k
        join StringIds s on s.id=k.shortName where k.start>=? and k.end<=? order by k.start''', (a,b)).fetchall()
    graphics = db.execute('select start,end from DX12_WORKLOAD where start>=? and end<=? order by start', (a,b)).fetchall()
    nvtx = db.execute('select text,count(*) from NVTX_EVENTS where start>=? and end<=? group by text', (a,b)).fetchall()
    assert len(kernels) == 144 and len(graphics) == 48
    assert [k[2] for k in kernels] == ['Simulate','Update','Deform']*48
    assert dict(nvtx) == {'E3 measured batch':1, 'E3 enqueue frame':48, 'E3 final CPU drain':1}
    assert all(kernels[i][1] <= kernels[i+1][0] for i in range(143))
    assert all(graphics[i][1] <= graphics[i+1][0] for i in range(47))
    assert all(kernels[3*f+2][1] <= graphics[f][0] for f in range(48)), 'read before producer completion'
    assert all(graphics[f-n][1] <= kernels[3*f][0] for f in range(n,48)), 'slot overwrite before prior consumer'
    intersection = sum(max(0, min(y,v)-max(x,u)) for x,y,_ in kernels for u,v in graphics)
    kernel_sum = sum(y-x for x,y,_ in kernels)
    graphics_sum = sum(y-x for x,y in graphics)
    span = max(kernels[-1][1],graphics[-1][1])-min(kernels[0][0],graphics[0][0])
    warnings = db.execute('select severity,text from DIAGNOSTIC_EVENT where severity>=2').fetchall()
    summary['traces'][n] = {'kernels': len(kernels), 'graphics_batches':len(graphics), 'nvtx':dict(nvtx),
        'kernel_ms':kernel_sum/1e6, 'graphics_ms':graphics_sum/1e6, 'cross_api_interval_overlap_ms':intersection/1e6,
        'first_to_last_ms':span/1e6, 'outside_recorded_intervals_ms':(span-kernel_sum-graphics_sum+intersection)/1e6,
        'dependency_violations':0, 'warnings':warnings}
    timelines[n] = (kernels, graphics)
    db.close()

fig, axes = plt.subplots(1,3,figsize=(12,4))
for ax, workload in zip(axes, ('cuda-heavy','graphics-heavy','balanced')):
    values = [s for s in summary['timing'] if s['workload']==workload]
    med = [s['wall_ms']['median'] for s in values]
    ax.bar([1,2,3],med,color=['#496b9b','#479b85','#c38a45'])
    ax.errorbar([1,2,3],med,yerr=[[m-s['wall_ms']['min'] for m,s in zip(med,values)],
                [s['wall_ms']['max']-m for m,s in zip(med,values)]],fmt='none',color='black',capsize=4)
    for x,y,s in zip([1,2,3],med,values):ax.text(x,s['wall_ms']['max']+.3,f'{y:.2f}',ha='center',fontsize=9)
    ax.set(title=workload+' (synthetic)',xlabel='Shared buffer slots',xticks=[1,2,3],ylabel='48-frame wall time (ms)')
    ax.set_ylim(0,max(s['wall_ms']['max'] for s in values)*1.18)
fig.suptitle('No profiler; 15 measured batches per configuration; median and min/max')
fig.tight_layout();fig.savefig(root/'timing-comparison.png',dpi=160);plt.close(fig)

fig, axes = plt.subplots(3,1,figsize=(12,6),sharex=True)
for ax, n in zip(axes,(1,2,3)):
    kernels, graphics = timelines[n];start=min(kernels[0][0],graphics[0][0])
    for x,y,name in kernels[:18]:ax.broken_barh([((x-start)/1e6,(y-x)/1e6)],(.6,.3),facecolors='#479b85')
    for x,y in graphics[:6]:ax.broken_barh([((x-start)/1e6,(y-x)/1e6)],(.1,.3),facecolors='#496b9b')
    ax.set(yticks=[.25,.75],yticklabels=['D3D12','CUDA'],title=f'{n} slots: first six frames; recorded overlap = {summary["traces"][n]["cross_api_interval_overlap_ms"]:.3f} ms')
    ax.grid(axis='x',alpha=.2)
axes[-1].set_xlabel('Time from first recorded GPU operation (ms)')
fig.suptitle('Nsight Systems CUDA + DX12, one clock; incomplete-event warnings retained')
fig.tight_layout();fig.savefig(root/'gpu-timeline.png',dpi=160);plt.close(fig)

(root/'analysis.json').write_text(json.dumps(summary,indent=2,ensure_ascii=False),encoding='utf-8')
for row in summary['timing']:
    print(row['workload'],row['slots'], 'wall',row['wall_ms']['median'],
          'submit',row['cpu_submit_ms']['median'],'wait',row['cpu_final_wait_ms']['median'],
          'cuda',row['cuda_sum_ms']['median'],'d3d',row['d3d_sum_ms']['median'])
print('Trace:',json.dumps(summary['traces'],ensure_ascii=False))
print('PASS: slot replay, multi-buffer output equality, expected GPU/NVTX counts and temporal dependencies')
