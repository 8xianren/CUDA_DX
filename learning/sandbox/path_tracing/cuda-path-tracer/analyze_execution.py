"""PT.9：独立事件计时与单次 Nsight 时间线分开分析，不把理论驻留率当实测。

从本课 results/execution 读取原始 CSV/SQLite；保留采集警告，不过滤不利证据。
硬件计数器权限不足时，本脚本不构造分支效率、带宽或实际 occupancy 数据。
"""
from pathlib import Path
import csv
import json
import sqlite3
import statistics
import sys

lesson = Path(__file__).resolve().parent
sys.path.insert(0, str(lesson / 'build' / 'python-deps'))
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

root = lesson / 'results' / 'execution'
backends = ['pixel', 'sample', 'wave']
summary = {'timing': {}, 'nsight': {}, 'limitations': [
    'Nsight Systems diagnostics warn: Not all CUDA events might have been collected.',
    'Expected kernel counts/names/order are checked; this does not prove complete CUDA API capture.',
    'Nsight Compute hardware counters unavailable: ERR_NVGPUCTRPERM.',
]}
timings = []
fig, axes = plt.subplots(1, 3, figsize=(12, 3.8), constrained_layout=True)
for ax, scene in zip(axes, ['cornell', 'gallery', 'empty']):
    rows = list(csv.DictReader((root / scene / 'timings.csv').open(encoding='utf-8')))
    checks = list(csv.DictReader((root / scene / 'checks.csv').open(encoding='utf-8')))
    assert len(checks) == 3 and all(float(r['max_rgb_difference']) == 0 for r in checks)
    summary['timing'][scene] = {}
    for i, backend in enumerate(backends):
        values = [float(r['gpu_ms']) for r in rows if r['backend'] == backend]
        assert len(values) == 9 and all(v > 0 for v in values)
        lo, med, hi = min(values), statistics.median(values), max(values)
        item = {'scene': scene, 'backend': backend, 'n': len(values),
                'min_ms': lo, 'median_ms': med, 'max_ms': hi}
        summary['timing'][scene][backend] = item
        timings.append(item)
        ax.bar(i, med, color=['#5a6fa7', '#dc9b42', '#449b83'][i])
        ax.errorbar(i, med, yerr=[[med-lo], [hi-med]], color='black', capsize=4)
        ax.annotate(f'{med:.3f}', (i, hi), xytext=(0, 5), textcoords='offset points', ha='center')
    ax.set(title=scene, ylabel='GPU event interval (ms)', xticks=range(3), xticklabels=backends)
    ax.set_ylim(0, ax.get_ylim()[1]*1.16)
    ax.grid(axis='y', alpha=.2)
fig.suptitle('3 warmups + 9 rotated rounds; median with min/max; no profiler')
fig.savefig(root / 'timing-comparison.png', dpi=160)
plt.close(fig)

timeline = []
for backend, expected in zip(backends, [1, 2, 23]):
    # URI只读打开，避免路径拼错时sqlite悄悄新建一个空数据库。
    db = sqlite3.connect((root / f'nsys-{backend}.sqlite').as_uri() + '?mode=ro', uri=True)
    kernels = db.execute('''select k.start,k.end,s.value,k.gridX,k.blockX,k.registersPerThread,k.streamId
        from CUPTI_ACTIVITY_KIND_KERNEL k join StringIds s on s.id=k.shortName order by k.start''').fetchall()
    assert len(kernels) == expected
    names = [r[2] for r in kernels]
    expected_names = {'pixel': ['Megakernel'], 'sample': ['SampleMegakernel', 'SampleResolve'],
                      'wave': ['WaveGenerate'] + ['WaveIntersect', 'WaveShade', 'WaveShadow']*7 + ['WaveResolve']}[backend]
    assert names == expected_names, names
    assert len({r[6] for r in kernels}) == 1
    assert all(kernels[i][1] <= kernels[i+1][0] for i in range(len(kernels)-1))
    warnings = db.execute('select severity,text from DIAGNOSTIC_EVENT where severity>=2').fetchall()
    api = db.execute('''select s.value,count(*),sum(r.end-r.start)/1e6
        from CUPTI_ACTIVITY_KIND_RUNTIME r join StringIds s on s.id=r.nameId group by s.value''').fetchall()
    start, end = kernels[0][0], kernels[-1][1]
    duration = sum(r[1]-r[0] for r in kernels)/1e6
    # CPU API区间和GPU区间在不同执行者上，可重叠；不能把两列时间直接相加。
    entry = {'kernel_count': len(kernels), 'kernel_sum_ms': duration,
             'first_to_last_kernel_ms': (end-start)/1e6, 'between_kernel_ms': (end-start)/1e6-duration,
             'diagnostics': warnings, 'runtime_api': api}
    tables = {r[0] for r in db.execute("select name from sqlite_master where type='table'")}
    entry['recorded_memcpy_count'] = db.execute('select count(*) from CUPTI_ACTIVITY_KIND_MEMCPY').fetchone()[0] if 'CUPTI_ACTIVITY_KIND_MEMCPY' in tables else 0
    entry['recorded_memset'] = db.execute('select count(*),sum(end-start)/1e6 from CUPTI_ACTIVITY_KIND_MEMSET').fetchone() if 'CUPTI_ACTIVITY_KIND_MEMSET' in tables else (0, 0)
    for index, (a, b, name, grid, block, regs, stream) in enumerate(kernels):
        timeline.append({'backend': backend, 'index': index, 'kernel': name,
                         'start_ms': (a-start)/1e6, 'duration_ms': (b-a)/1e6,
                         'grid_x': grid, 'block_x': block, 'registers': regs, 'stream': stream})
    summary['nsight'][backend] = entry
    db.close()

# 相同横轴展示样本级完整路径与分阶段执行；像素级的40ms已在计时图展示。
colors = {'SampleMegakernel': '#dc9b42', 'SampleResolve': '#666666', 'WaveGenerate': '#8b78aa',
          'WaveIntersect': '#529ac7', 'WaveShade': '#449b83', 'WaveShadow': '#d46c70', 'WaveResolve': '#666666'}
fig, ax = plt.subplots(figsize=(12, 4.2))
fig.subplots_adjust(left=.08, right=.98, top=.78, bottom=.32)
seen = set()
for row in timeline:
    if row['backend'] == 'pixel':
        continue
    name = row['kernel']; y = 1 if row['backend'] == 'sample' else 0
    ax.barh(y, row['duration_ms'], left=row['start_ms'], height=.45, color=colors[name],
            label=name if name not in seen else None)
    seen.add(name)
ax.set(yticks=[0, 1], yticklabels=['wave', 'sample'], xlabel='GPU time from first kernel start (ms)',
       title='Gallery: one captured render; expected 2 / 23 kernels present')
fig.legend(ncol=4, fontsize=8, loc='lower center', bbox_to_anchor=(.5, .02))
fig.suptitle('Capture warning retained: not all CUDA events might have been collected', fontsize=10)
fig.savefig(root / 'kernel-timeline.png', dpi=160)
plt.close(fig)

for filename, rows in [('timing-summary.csv', timings), ('timeline.csv', timeline)]:
    with (root / filename).open('w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=rows[0].keys()); writer.writeheader(); writer.writerows(rows)
(root / 'analysis.json').write_text(json.dumps(summary, indent=2), encoding='utf-8')
print(json.dumps(summary, indent=2))
