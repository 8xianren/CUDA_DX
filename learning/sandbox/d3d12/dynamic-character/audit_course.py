"""核对真实验收产物和交互轨迹，汇总耗时；不从进度文档推断测试通过。"""
import csv
import hashlib
import json
import statistics
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RESULTS = ROOT / 'results'

def read_csv(path):
    with path.open(encoding='utf-8-sig', newline='') as stream:
        return list(csv.DictReader(stream))

def main():
    evidence = {}
    for name in ['h1/gltf-audit.json', 'h2/summary.json', 'h2/independent.json', 'h3/summary.json',
                 'h4/summary.json', 'h5/summary.json', 'h6/summary.json']:
        path = RESULTS / name
        data = json.loads(path.read_text(encoding='utf-8-sig'))
        assert data['pass'], name
        evidence[name] = data
    memcheck = (RESULTS / 'h2/memcheck.txt').read_text(encoding='utf-8-sig')
    assert 'ERROR SUMMARY: 0 errors' in memcheck and '0 bytes leaked' in memcheck
    rows = read_csv(RESULTS / 'h7/interactive/frames.csv')
    assert len(rows) == 300
    ticks = [int(row['tick']) for row in rows]
    assert ticks[2] == ticks[3] == ticks[4] == ticks[5]
    assert ticks[6] == ticks[5] + 1 and ticks[6] == ticks[7] == ticks[8]
    assert ticks[9] == ticks[8] + 4
    states = sorted(set(row['state'] for row in rows))
    assert states == sorted(['Idle', 'Walk', 'Run', 'Jump', 'Fall', 'Land'])
    window = (RESULTS / 'h7/window.txt').read_text(encoding='utf-8-sig')
    assert 'debug_warning_error=0' in window and 'frames=300' in window
    # 样本较少，p95采用排序后的nearest-rank，明确记录而不冒充稳定帧率保证。
    perf = read_csv(RESULTS / 'h7/performance.csv')
    groups = {}
    for row in perf:
        key = row['mode'] + '-' + row['width'] + 'x' + row['height']
        groups.setdefault(key, []).append(row)
    measurements = {}
    assert len(groups) == 4
    for key, group in groups.items():
        assert len(group) == 12
        measurements[key] = {}
        for column in list(group[0])[6:]:
            values = sorted(float(row[column]) for row in group)
            assert all(v >= 0 for v in values)
            measurements[key][column] = {'median': statistics.median(values), 'p95': values[-1]}
    hashes = {}
    for directory in ['src', 'shaders', 'tests']:
        for path in sorted((ROOT / directory).rglob('*')):
            if path.is_file():
                hashes[path.relative_to(ROOT).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    summary = {'pass': True, 'frames': len(rows), 'states': states,
               'pause_step_resume': True, 'debug_errors': 0,
               'measurement_scope': 'single-frame synchronous, validation off, no window/Present, 3 warmup + 12 measured',
               'performance': measurements, 'evidence': evidence, 'source_sha256': hashes}
    (RESULTS / 'h7/summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({'pass': True, 'performance': measurements}, indent=2))

if __name__ == '__main__':
    main()
