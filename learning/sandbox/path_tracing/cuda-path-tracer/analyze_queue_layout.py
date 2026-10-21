"""由真实stateId快照推导单标量load的地址覆盖，不伪造硬件事务或带宽计数。

AoS实际字段：states[id].ray.origin.x / shadows[id].ray.origin.x。
SoA假设字段：独立、32B对齐的float originX[N]，保持相同id。
dense假设字段：按queue slot打包的float originX[count]，其重排成本未计算。
每个模型都统计同一warp一次4B标量load覆盖的32B地址段；不同warp不去重，
不同指令/缓存/实际SASS访存宽度不在模型中。它不是DRAM读取字节数。
"""
from pathlib import Path
import csv
import json
import math
import sys

lesson = Path(__file__).resolve().parent
sys.path.insert(0, str(lesson / 'build' / 'python-deps'))
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
root = lesson / 'results' / 'queue-layout'


def sector_sum(ids, stride, offset=0):
    total = 0
    for start in range(0, len(ids), 32):
        # 此处只允许4B对齐的float字段，不能跨32B边界；跨边界访问需统计首尾两段。
        addresses = ids[start:start+32].astype(np.uint64)*stride + offset
        assert np.all(addresses % 4 == 0)
        total += len(np.unique(addresses//32))
    return total


# 解析预期值验证模型本身：空、满warp、尾warp、反序、间隔8个float。
seq = np.arange(32, dtype=np.uint32)
assert sector_sum(seq, 88) == 32 and sector_sum(seq, 4) == 4
assert sector_sum(seq[::-1], 4) == 4
assert sector_sum(seq*8, 4) == 32
assert sector_sum(np.arange(33, dtype=np.uint32), 4) == 5
assert sector_sum(np.array([], dtype=np.uint32), 4) == 0
assert sector_sum(seq+1, 4) == 5

rows = []
for case in ['gallery', 'empty', 'sanitizer']:
    folder = root / case
    manifest = list(csv.DictReader((folder / 'queues.csv').open(encoding='utf-8')))
    for entry in manifest:
        count, capacity, stride, offset = [int(entry[k]) for k in ['count','capacity','aos_stride','field_offset']]
        binary = folder / entry['file']
        assert binary.stat().st_size == count*4
        ids = np.fromfile(binary, dtype='<u4')
        assert len(np.unique(ids)) == count and (not count or int(ids.max()) < capacity)
        warps = (count+31)//32
        sectors = {'aos': sector_sum(ids, stride, offset), 'soa_same_id': sector_sum(ids, 4),
                   'dense_slot': sector_sum(np.arange(count, dtype=np.uint32), 4)}
        row = {'case': case, 'kind': entry['kind'], 'depth': int(entry['depth']),
               'count': count, 'capacity': capacity, 'nonempty_warps': warps,
               'valid_fraction_of_launched_threads': count/(math.ceil(capacity/128)*128)}
        for name, value in sectors.items():
            row[name+'_sector_sum'] = value
            row[name+'_sectors_per_nonempty_warp'] = value/warps if warps else None
        rows.append(row)
    if case == 'empty':
        assert all(r['count'] == 0 for r in rows if r['case'] == case and (r['depth'] > 0 or r['kind'] == 'shadow'))

with (root / 'address-model.csv').open('w', newline='', encoding='utf-8') as f:
    writer = csv.DictWriter(f, fieldnames=rows[0].keys());writer.writeheader();writer.writerows(rows)
result = {'scope': 'address coverage for one hypothetical scalar load, not measured memory traffic',
          'fixtures': '7 analytic address cases passed',
          'soa_and_dense': 'address alternatives only; not implemented backends, repacking cost excluded', 'rows': rows}
(root / 'analysis.json').write_text(json.dumps(result, indent=2), encoding='utf-8')

fig, axes = plt.subplots(1, 2, figsize=(11, 4.1), constrained_layout=True)
for ax, kind in zip(axes, ['ray', 'shadow']):
    data = [r for r in rows if r['case'] == 'gallery' and r['kind'] == kind]
    for key, label, marker in [('aos','Current AoS by stateId','o'),
                               ('soa_same_id','Hypothetical SoA, same stateId','s'),
                               ('dense_slot','Hypothetical packed field by slot','^')]:
        ax.plot([r['depth'] for r in data], [np.nan if r[key+'_sectors_per_nonempty_warp'] is None else r[key+'_sectors_per_nonempty_warp'] for r in data], marker+'-', label=label)
    ax.set(title=kind+' queue', xlabel='Path depth', ylabel='32B address segments per nonempty warp', ylim=(0,34))
    ax.grid(alpha=.2);ax.legend(fontsize=8)
fig.suptitle('Gallery: scalar origin.x address model from actual queue snapshots\nNot hardware traffic; empty shadow queue at depth 6 has no point', fontsize=10)
fig.savefig(root / 'address-coverage.png', dpi=160);plt.close(fig)
print('QUEUE ADDRESS MODEL PASS: 7 fixtures, queue IDs/lengths, empty queues')
for r in rows:
    if r['case']=='gallery':
        print(r['kind'],r['depth'],r['count'],
              'AoS/SoA/dense=',*[None if r[k+'_sectors_per_nonempty_warp'] is None else round(r[k+'_sectors_per_nonempty_warp'],4) for k in ['aos','soa_same_id','dense_slot']])
