"""汇总真正存在的F验收记录，区分正确性、GPU离屏成本与窗口显示证据。

不重写子测试，不把缺失/回退当通过。性能去掉前8帧预热；CPU等待/Present不在GPU区间内。
"""
import csv
import hashlib
import json
import platform
import statistics
import subprocess
from datetime import datetime, timezone, timedelta
from pathlib import Path

ROOT=Path(__file__).resolve().parent
METHODS=['reference','noaa','msaa4','fxaa','taa','taa-no-reprojection','taa-no-rejection','taa-no-clamp',
         'bilinear','bicubic','nis','fsr-native','fsr-quality','fsr-balanced','fsr-performance',
         'xess-native','xess-quality','xess-balanced','xess-performance']

def read(path):
    return json.loads((ROOT/path).read_text(encoding='utf-8-sig'))

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def stats(values):
    values=sorted(values)
    return {'count':len(values),'mean_ms':statistics.mean(values),'p50_ms':statistics.median(values),
            'p95_ms':values[int((len(values)-1)*.95)],'min_ms':min(values),'max_ms':max(values)}

def benchmark_contract_errors(method,capture,bench):
    """质量与性能可以关闭不同的诊断，但不能偷偷更换算法、采样面积或相位。"""
    errors=[]
    if bench.get('fallback') is not False:errors.append('benchmark must explicitly report fallback=false')
    for field in ('provider','render_width','render_height','output_width','output_height'):
        if field not in capture or field not in bench or capture[field]!=bench[field]:
            errors.append(f'capture/benchmark {field} mismatch or missing')
    # 空间算法未使用抖动，旧记录无该字段等价于0；时域算法必须显式声明
    # 有效相位数，防止把8相位质量结果与32相位性能结果拼在一起。
    temporal=method.startswith(('taa','fsr-','xess-'))
    capture_phase=capture.get('jitter_phase_count',None if temporal else 0)
    bench_phase=bench.get('jitter_phase_count',None if temporal else 0)
    if capture_phase is None or bench_phase is None or capture_phase!=bench_phase:
        errors.append('capture/benchmark jitter_phase_count mismatch or missing')
    elif temporal and (not isinstance(capture_phase,int) or capture_phase<1):
        errors.append('temporal jitter_phase_count must be a positive integer')
    if method.startswith(('fsr-','xess-')) and (not capture.get('provider') or capture['provider'] in ('none','bilinear fallback')):
        errors.append('official SDK provider is unavailable')
    return errors

def main():
    out=ROOT/'results/verification';out.mkdir(parents=True,exist_ok=True)
    reports=['results/f1/summary.json','results/f2/summary.json','results/f4/cpu-contract.json',
             'results/f4/gpu-summary.json','results/f5/gpu-oracle.json','results/f6/summary.json',
             'results/f7/sdk-probe.json','results/f7/sdk-contracts.json','results/f9/summary.json',
             'results/f10/analysis-unit.json','results/f10/quality/summary.json']
    checks=[]
    for report in reports:
        data=read(report)
        checks.append({'path':report,'pass':data.get('pass') is True,'sha256':sha(ROOT/report)})
    timing={}
    for method in METHODS:
        capture=read(f'results/f10/sequences/{method}/summary.json')
        bench=read(f'results/f10/benchmark/{method}/summary.json')
        log=ROOT/f'results/verification/sequence-{method}.txt'
        # PowerShell Tee-Object在本环境写UTF8。若外部PowerShell改成UTF16，用签名识别读取。
        raw=log.read_bytes();text=raw.decode('utf-16' if raw.startswith(b'\xff\xfe') else 'utf-8-sig')
        contract_errors=benchmark_contract_errors(method,capture,bench)
        ok=(capture['frames']==120 and capture['pass'] and capture['debug_validation'] and not capture.get('fallback')
            and 'debug_warning_error=0' in text and bench['pass'] and not bench['debug_validation'] and bench['frames']==40
            and not contract_errors)
        checks.append({'method':method,'pass':bool(ok),'sequence_frames':capture['frames'],'benchmark_frames':bench['frames'],
                       'contract_errors':contract_errors})
        # 失败模式不能只在另一个JSON中留下false，同时仍以SDK标签发布耗时表。
        if not ok:continue
        with (ROOT/f'results/f10/benchmark/{method}/frames.csv').open() as stream:
            rows=list(csv.DictReader(stream))[8:]
        timing[method]={'render_width':bench['render_width'],'render_height':bench['render_height'],
                        'provider':bench['provider'],'jitter_phase_count':bench.get('jitter_phase_count',0),
                        'warmup_excluded':8,'frame':stats([float(r['gpu_frame_ms']) for r in rows]),
                        'reconstruction':stats([float(r['gpu_reconstruction_ms']) for r in rows])}
    fallback=read('results/f10/sequences/fsr-unavailable/summary.json')
    dynamic=read('results/f10/sequences/fsr-dynamic/summary.json')
    resize=read('results/f7/resize-dispatch/summary.json')
    checks.append({'case':'missing_sdk_renders_bilinear','pass':fallback['pass'] and fallback['fallback'] and fallback['frames']==8})
    checks.append({'case':'fsr_dynamic_and_resize_dispatch','pass':dynamic['pass'] and not dynamic['fallback'] and dynamic['frames']==16
                   and resize['pass'] and not resize['fallback'] and resize['output_width']==800 and resize['output_height']==450})
    sources={}
    for folder in ('src','shaders'):
        for path in sorted((ROOT/folder).rglob('*')):
            if path.is_file():sources[path.relative_to(ROOT).as_posix()]=sha(path)
    for name in ('CMakeLists.txt','build.ps1','verify.ps1','audit_temporal.py','analyze_sequences.py','summarize_verification.py','verify_sdk_contracts.py','sdk_manifest.json','nis.lock.json'):
        sources[name]=sha(ROOT/name)
    env={'recorded_at':datetime.now(timezone(timedelta(hours=8))).isoformat(),'platform':platform.platform(),
         'python':platform.python_version(),'gpu':subprocess.check_output(['nvidia-smi','--query-gpu=name,driver_version,memory.total','--format=csv,noheader'],text=True).strip(),
         'scene':'640x360 output; fixed time frame/60; camera cut frame60; linear HDR; 4x-axis raster box reference',
         'benchmark':'19 modes, 40 frames each; first8 excluded; Debug/GPU validation disabled only for benchmark; offscreen no Present',
         'gpu_validation':'correctness runs enable D3D12 Debug and GPU-based validation; F9 has separate window/ETW evidence'}
    (ROOT/'results/f10/benchmark/summary.json').write_text(json.dumps({'scope':env['benchmark'],'methods':timing},ensure_ascii=False,indent=2),encoding='utf-8')
    report={'pass':all(c['pass'] for c in checks),'scope':'F1-F10 declared teaching and SDK integration acceptance; not H demo production integration',
            'environment':env,'checks':checks,'source_sha256':sources}
    (out/'summary.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({'pass':report['pass'],'checks':len(checks),'sequence_frames':19*120,'benchmark_frames':19*40,'source_files':len(sources)}))
    return 0 if report['pass'] else 1

if __name__=='__main__':raise SystemExit(main())
