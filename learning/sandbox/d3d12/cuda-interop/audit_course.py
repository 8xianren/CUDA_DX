"""E.1–E.3交付审计：按原验收范围检查真实输出，不把清单存在当运行通过。"""
from pathlib import Path
import hashlib
import json
import csv

course=Path(__file__).resolve().parent
root=course/'results'
def read(p):return json.loads(p.read_text(encoding='utf-8-sig'))
def require(value,message):
    if not value:raise RuntimeError(message)
e1=read(root/'e3/e1-regression/summary.json')
require(e1['pass'] and e1['mismatches']==0 and e1['checked_fields']==1920 and e1['covered_pixels']>0,'E1 data/render')
require(e1['cpu_middle_wait_calls']==0 and e1['ready_fence']==e1['consumed_fence']==24,'E1 synchronization')
with (root/'e3/e1-regression/fences.csv').open(newline='') as f:
    for i,row in enumerate(csv.DictReader(f)):
        require(tuple(map(int,row.values()))==(i,0,i,i+1,i+1,i+1),'E1 replay')
require(i==23,'E1 frame count')
e2=read(root/'e2/e2/summary.json');bad=read(root/'e2/e2-stale/summary.json')
require(e2['pass'] and e2['unexpected_vertex_byte_mismatches']==0 and e2['dynamic_vertex_bytes_checked']==6528,'E2 write range')
require(e2['static_unchanged'] and e2['static_snapshot_bytes']==424 and e2['mismatches']==0,'E2 static/render')
require(bad['pass'] and bad['injected_stale_vertex_byte_mismatches']>0 and bad['injected_stale_pixel_mismatches']>0,'E2 stale data detector')
analysis=read(root/'e3/analysis.json')
require(len(analysis['validation'])==3 and len(analysis['timing'])==9,'E3 configurations')
require(all(t['samples']==15 for t in analysis['timing']),'E3 samples')
for n in ('1','2','3'):
    t=analysis['traces'][n]
    require(t['kernels']==144 and t['graphics_batches']==48 and sum(t['nvtx'].values())==50,'E3 captured operations')
    require(t['dependency_violations']==0,'E3 slot temporal order')
    require(len(t['warnings'])>0,'Preserve capture limitations')
for p in (root/'e1/memcheck.txt',root/'e2/memcheck.txt',root/'e3/memcheck.txt'):
    text=p.read_text(encoding='utf-8-sig')
    require('ERROR SUMMARY: 0 errors' in text and '0 bytes leaked' in text,str(p))
for item in read(root/'e3/input-hashes.json'):
    p=Path(item['Path']);require(hashlib.sha256(p.read_bytes()).hexdigest().upper()==item['Hash'],'input/executable changed since measurement')
env=read(root/'e3/environment.json');require('sm_120' in env['build'] and '48 fixed frames' in env['measurement'],'E3 reproducibility metadata')
for name in ('timing-comparison.png','gpu-timeline.png'):
    require((root/'e3'/name).read_bytes().startswith(b'\x89PNG\r\n\x1a\n'),'plot missing')
notes=course.parents[2]/'笔记/d3d12'
for name in ('E.1-实例数据与双向交接.md','E.2-动态顶点缓存与写入边界.md','E.3-多缓冲时间线与性能验收.md'):
    require((notes/name).stat().st_size>3000,'detailed lesson missing')
evidence={
    'pass':True,
    'scope':['E1 glTF instance SRV / external memory and bidirectional fence / zero middle CPU waits / replay',
             'E2 selective dynamic vertices / stride and guard bytes / static GPU resources unchanged / stale-cache detection',
             'E3 one-two-three slots / three fixed workloads / 135 measured batches / CPU and GPU timing / NVTX and Systems'],
    'e1':e1,'e2':e2,'e2_stale':bad,
    'timing_configurations':9,'measured_batches':135,
    'trace_limitations':'Expected operations accounted for; incomplete-event warnings retained; zero observed cross-API interval overlap in captured mixed batches.',
    'explicitly_not_claimed':['Hardware counter attribution (waived by user)','Production animation or PBR performance','Input-to-display latency','Infinite frame resource scheduler'],
    'sha256':{}
}
for p in sorted(list((course/'src').glob('*'))+list((course/'shaders').glob('*'))+list(course.glob('*.py'))+list(course.glob('*.ps1'))):
    if p.is_file():evidence['sha256'][str(p.relative_to(course))]=hashlib.sha256(p.read_bytes()).hexdigest()
(root/'e3/chapter-audit.json').write_text(json.dumps(evidence,indent=2,ensure_ascii=False),encoding='utf-8')
print('PASS: E.1–E.3 requirement audit; live executable/input hashes match measured artifacts.')
