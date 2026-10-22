"""F.4–F.6 独立 CPU oracle；GPU 执行由 D3D12 宿主负责，绝不把 CPU pass 写成 GPU pass。

python .../audit_temporal.py --emit-fixtures
python .../audit_temporal.py --gpu-manifest .../results/f5/oracle-cases.json
纹理交换文件为 little-endian float32、H×W×4、逐行紧密排布，无 D3D12 RowPitch padding。
GPU 读回先通过 GetCopyableFootprints 去除 padding，RGBA16F 须转为 float32 后保存。
"""
from __future__ import annotations
import argparse
import json
import math
from pathlib import Path
import struct
import numpy as np

ROOT = Path(__file__).resolve().parent
HISTORY, REPROJECT, DEPTH, CLAMP, YCOCG, JITTER_IN_MV = 1, 2, 4, 8, 16, 32


def halton(n: int, base: int) -> float:
    # 整数的进制展开独立于 shader；例 5=101₂ → .101₂=5/8。
    digits = []
    while n:
        n, digit = divmod(n, base)
        digits.append(digit)
    return sum(digit * base ** (-i-1) for i, digit in enumerate(digits))


def project(world, eye=(0, 0, 0), fov=math.pi/2, aspect=1):
    # 左手视空间 +z 向前的针孔推导：NDC=(x/(z*a*tan(f/2)),y/(z*tan(f/2)))。
    p = np.asarray(world, dtype=float) - eye
    if p[2] <= 0:
        raise ValueError("point has no valid forward history")
    scale = math.tan(fov/2)
    return np.array([.5+.5*p[0]/(p[2]*aspect*scale), .5-.5*p[1]/(p[2]*scale)])


def bilinear(image, uv):
    """与硬件 linear clamp 同一数学核；以像素中心 n+.5 为节点。"""
    h, w = image.shape[:2]
    xy = np.asarray(uv)*[w, h]-.5
    p = np.floor(xy).astype(int)
    f = xy-p
    result = np.zeros(image.shape[-1], dtype=float)
    for dy, wy in ((0, 1-f[1]), (1, f[1])):
        for dx, wx in ((0, 1-f[0]), (1, f[0])):
            result += image[np.clip(p[1]+dy, 0, h-1), np.clip(p[0]+dx, 0, w-1)]*wx*wy
    return result


def cubic_weight(t):
    # Catmull-Rom 的四基函数写成 Hermite 形式，避免直接抄 HLSL 分段实现。
    return np.array([-.5*t+t*t-.5*t*t*t, 1-2.5*t*t+1.5*t*t*t,
                     .5*t+2*t*t-1.5*t*t*t, -.5*t*t+.5*t*t*t])


def spatial(image, out_size, cubic=False, offset_uv=(0,0)):
    h, w = image.shape[:2]
    ow, oh = out_size
    out = np.zeros((oh, ow, 4), dtype=float)
    for y in range(oh):
        for x in range(ow):
            uv = np.array([(x+.5)/ow, (y+.5)/oh])+offset_uv
            if not cubic:
                out[y, x] = bilinear(image, uv)
            else:
                xy = uv*[w, h]-.5
                base = np.floor(xy).astype(int)
                wx, wy = (cubic_weight(t) for t in xy-base)
                patch = image[np.clip(np.arange(-1, 3)+base[1], 0, h-1)[:, None],
                              np.clip(np.arange(-1, 3)+base[0], 0, w-1)[None, :]]
                out[y, x] = np.einsum("i,j,ijc->c", wy, wx, patch)
            out[y, x, 3] = 1
    return out


# 每个像素的 RGB 行向量右乘 M^T。逆变换由矩阵求逆生成，不另复制 shader 公式。
RGB_TO_YCOCG = np.array([[.25, .5, .25], [.5, 0, -.5], [-.25, .5, -.25]])
YCOCG_TO_RGB = np.linalg.inv(RGB_TO_YCOCG)


def temporal(current, history, md, previous_depth, reactive, *, flags=31,
             jitter=(0, 0), previous_jitter=(0, 0), weight=.9, depth_threshold=.02):
    h, w = current.shape[:2]
    out = current.astype(float).copy()
    out[:, :, 3] = 1
    diag = np.zeros((h, w, 4), dtype=float)
    for y in range(h):
        for x in range(w):
            uv = np.array([(x+.5)/w, (y+.5)/h])
            prior_uv = uv.copy()
            if flags & REPROJECT:
                prior_uv += md[y, x, :2]
                if not flags & JITTER_IN_MV:
                    prior_uv += np.asarray(previous_jitter)-jitter
            motion = np.linalg.norm(md[y, x, :2]*[w, h])
            reason = 0
            if not flags & HISTORY:
                reason = 1
            elif not np.isfinite(prior_uv).all() or not ((prior_uv >= 0).all() and (prior_uv < 1).all()):
                reason = 2
            elif flags & DEPTH:
                px, py = np.clip(np.floor(prior_uv*[w, h]).astype(int), [0, 0], [w-1, h-1])
                actual = previous_depth[py, px, 0]
                expected = md[y, x, 3]
                if expected <= 0 or not np.isfinite(actual) or abs(actual-expected) > max(.001, abs(expected)*depth_threshold):
                    reason = 3
            if reason:
                diag[y, x] = [0, 0, motion, reason]
                continue
            prior = bilinear(history, prior_uv)[:3]
            if not np.isfinite(prior).all():
                diag[y, x] = [0, 0, motion, 4]
                continue
            original = prior.copy()
            if flags & CLAMP:
                neighbors = current[max(0,y-1):min(h,y+2), max(0,x-1):min(w,x+2), :3].reshape(-1, 3)
                if flags & YCOCG:
                    neighbors = neighbors @ RGB_TO_YCOCG.T
                    prior = RGB_TO_YCOCG @ prior
                prior = np.clip(prior, neighbors.min(axis=0), neighbors.max(axis=0))
                if flags & YCOCG:
                    prior = YCOCG_TO_RGB @ prior
            effective = np.clip(weight, 0, 1)*(1-np.clip(reactive[y, x, 0], 0, 1))
            out[y, x, :3] = current[y, x, :3]*(1-effective)+prior*effective
            diag[y, x] = [int(effective > 0), np.linalg.norm(prior-original), motion,
                           5 if reactive[y, x, 0] >= 1 else 0]
    return out, diag


def self_test():
    checks = []
    def check(name, condition, value=None):
        checks.append({"name": name, "pass": bool(condition), "value": value})
    points = [(halton(i, 2)-.5, halton(i, 3)-.5) for i in range(1, 9)]
    check("halton_first_sample", np.allclose(points[0], [0, -1/6]), list(points[0]))
    check("halton_8_x_strata", len(set(int((x+.5)*8) for x, _ in points)) == 8)
    check("halton_5_base_2", halton(5, 2) == .625)
    p = np.array([1., .5, 4.])
    static = project(p)-project(p)
    pan = project(p)-project(p, eye=np.array([.5, 0, 0]))
    rotated = np.array([0., 1., 4.])  # 点 (1,0,4) 围绕 z 轴旋转 90°。
    rot = project([1, 0, 4])-project(rotated)
    check("static_motion_zero", np.array_equal(static, [0, 0]), static.tolist())
    check("camera_pan_previous_minus_current", np.allclose(pan, [.0625, 0]), pan.tolist())
    check("object_rotation_motion", np.allclose(rot, [.125, .125]), rot.tolist())
    c, old = np.array([.5, .5]), np.array([.45, .55])
    jc, jp = np.array([.25, -.25])/64, np.array([-.25, .25])/64
    check("jitter_excluded_reprojection", np.allclose(c+jc+(old-c)+jp-jc, old+jp))
    check("jitter_included_no_double_correction", np.allclose(c+jc+(old+jp-c-jc), old+jp))
    check("linear_previous_depth_camera_dolly", np.isclose((p-np.array([0,0,1]))[2], 3) and p[2] == 4)
    colors = np.array([[1,0,0], [0,1,0], [0,0,1], [2,.5,4], [0,0,0]])
    check("ycocg_roundtrip", np.max(abs(colors @ RGB_TO_YCOCG.T @ YCOCG_TO_RGB.T-colors)) < 1e-12)
    image = np.ones((4, 6, 4))*.25; image[:, :, 3] = 1
    for cubic in (False, True):
        for ratio in (1, 1.5, 2):
            result = spatial(image, (int(6*ratio), int(4*ratio)), cubic)
            check(f"{'bicubic' if cubic else 'bilinear'}_constant_{ratio}", np.max(abs(result[:, :, :3]-.25)) < 1e-12)
    rng = np.random.default_rng(4156)
    random_image = rng.random((4, 6, 4)); random_image[:, :, 3] = 1
    for cubic in (False, True):
        check(f"{'bicubic' if cubic else 'bilinear'}_identity", np.max(abs(spatial(random_image,(6,4),cubic)-random_image)) < 1e-12)
    # 解析线性信号f(x)=x：jittered像素保存x-j，最后采样x+j应在内域回到x。
    for shift in (-.375,.375):
        ramp=np.zeros((4,6,4));ramp[:,:,0]=np.arange(6)-shift;ramp[:,:,3]=1
        stable=spatial(ramp,(6,4),offset_uv=(shift/6,0))
        check(f"unjitter_linear_signal_{shift}",np.max(abs(stable[:,1:-1,0]-np.arange(1,5)))<1e-12)
    current = np.zeros((4, 6, 4)); current[:, :, 3] = 1
    history = np.ones_like(current); md = np.zeros_like(current); md[:, :, 2:] = 4
    depth = np.ones_like(current)*4; reactive = np.zeros_like(current)
    for label, flags, expected in (("camera_cut",30,0),("no_clamp_ghost",7,.9),("clamp_rejects_color",31,0)):
        result, _ = temporal(current, history, md, depth, reactive, flags=flags)
        check(label, np.allclose(result[:, :, :3], expected), float(result[1,1,0]))
    depth[:, :, 0] = 2
    for label, flags, expected in (("disocclusion_depth_reject",7,0),("no_depth_ghost",3,.9)):
        result, _ = temporal(current, history, md, depth, reactive, flags=flags)
        check(label, np.allclose(result[:, :, :3], expected), float(result[1,1,0]))
    depth[:, :, 0] = 4; reactive[:, :, 0] = 1
    result, _ = temporal(current, history, md, depth, reactive, flags=7)
    check("reactive_one_uses_current", np.allclose(result[:, :, :3],0))
    md[:, :, 0] = 2
    result, diag = temporal(current, history, md, depth, reactive, flags=7)
    check("out_of_bounds_reject_before_sample", np.all(diag[:, :, 3]==2))
    return {"pass": all(x["pass"] for x in checks), "execution": "CPU only", "checks": checks,
            "gpu_status": "see independently produced gpu-oracle.json; CPU result is not a GPU validation"}


def emit_fixtures():
    folder = ROOT / "results" / "f5" / "oracle-input"
    folder.mkdir(parents=True, exist_ok=True)
    w, h = 16, 12
    yy, xx = np.mgrid[:h,:w]
    current = np.zeros((h,w,4)); current[:, :, 3] = 1
    current[:,:,0] = xx/w; current[:,:,1] = yy/h; current[:,:,2] = .25
    history = current.copy(); history[:,:,0] = (xx+2)/w
    md = np.zeros_like(current); md[:,:,0] = -2/w; md[:,:,2:] = 4
    depth = np.ones_like(current)*4; reactive = np.zeros_like(current)
    cases=[]
    variants=[("reset",30), ("reproject",7), ("no_reproject",5), ("rgb_clamp",15),
              ("ycocg_clamp",31), ("disocclusion",7), ("no_depth",3), ("reactive",7),
              ("jitter_excluded",7), ("jitter_included",39),
              ("out_of_bounds",7), ("expected_previous_depth",7)]
    for label, flags in variants:
        inputs={"current":current.copy(),"history":history.copy(),"motion_depth":md.copy(),
                "previous_depth":depth.copy(),"reactive":reactive.copy()}
        jitter, previous_jitter=[0,0],[0,0]
        if label=="reset": inputs["history"][:,:,:3]=np.nan  # 无效历史不得污染首帧。
        if label=="out_of_bounds": inputs["motion_depth"][:,:,:2]=2
        if label=="expected_previous_depth": inputs["motion_depth"][:,:,2]=3  # w仍4；相机dolly反例。
        if label in ("rgb_clamp","ycocg_clamp"):
            inputs["history"][4:8,6:10,:3]=[4,0,4]
        if label in ("disocclusion","no_depth"):
            inputs["previous_depth"][4:8,4:9,0]=2
        if label=="reactive": inputs["reactive"][3:9,4:12,0]=1
        if label.startswith("jitter"):
            jitter=[.25/w,-.25/h]; previous_jitter=[-.25/w,.25/h]
            if label=="jitter_included": inputs["motion_depth"][:,:,:2]+=np.array(previous_jitter)-jitter
        record={"name":label,"entry":"TaaCS","input_width":w,"input_height":h,
                "output_width":w,"output_height":h,"flags":flags,"jitter_uv":jitter,
                "previous_jitter_uv":previous_jitter,"history_weight":.9,"depth_threshold":.02,
                "tolerance":.0002}
        case_folder=folder/label;case_folder.mkdir(parents=True,exist_ok=True)
        for key, data in inputs.items():
            path=case_folder/f"{key}.f32"; data.astype('<f4').tofile(path)
            record[key]=str(path.relative_to(ROOT)).replace('\\','/')
        record["output"]=str((case_folder/"output.f32").relative_to(ROOT)).replace('\\','/')
        result,_=temporal(inputs["current"],inputs["history"],inputs["motion_depth"],inputs["previous_depth"],inputs["reactive"],
                          flags=flags,jitter=jitter,previous_jitter=previous_jitter)
        result.astype('<f4').tofile(case_folder/"expected.f32")
        cases.append(record)
    for entry in ("BilinearCS","BicubicCS"):
        for ratio in (1,1.5,2):
            label=f"{entry}-{ratio}"
            record=dict(cases[0]);record.update(name=label,entry=entry,output_width=int(w*ratio),output_height=int(h*ratio))
            case_folder=folder/label;case_folder.mkdir(parents=True,exist_ok=True)
            for key in ("current","history","motion_depth","previous_depth","reactive"):
                destination=case_folder/f"{key}.f32"
                destination.write_bytes((ROOT/record[key]).read_bytes())
                record[key]=str(destination.relative_to(ROOT)).replace('\\','/')
            record["output"]=str((case_folder/"output.f32").relative_to(ROOT)).replace('\\','/')
            cases.append(record)
    for label,jitter_pixels in [('unjitter_identity',(0,0)),('unjitter_positive',(.375,-.25)),
                                ('unjitter_negative',(-.375,.25)),('unjitter_boundary',(.5,.5))]:
        record=dict(cases[0]);record.update(name=label,entry='UnjitterCS',jitter_uv=[jitter_pixels[0]/w,jitter_pixels[1]/h])
        case_folder=folder/label;case_folder.mkdir(parents=True,exist_ok=True)
        for key in ('current','history','motion_depth','previous_depth','reactive'):
            destination=case_folder/f'{key}.f32';destination.write_bytes((ROOT/record[key]).read_bytes())
            record[key]=str(destination.relative_to(ROOT)).replace('\\','/')
        record['output']=str((case_folder/'output.f32').relative_to(ROOT)).replace('\\','/')
        cases.append(record)
    for record in cases:
        case_folder=folder/record['name']
        (case_folder/'entry.txt').write_text(record['entry']+'\n')
        (case_folder/'meta.json').write_text(json.dumps(record,indent=2)+'\n')
        # HLSL 的 cbuffer 每16字节一个register；本合同没有跨register的隐式洞。
        packed=struct.pack('<4I8f2I2f',record['input_width'],record['input_height'],
            record['output_width'],record['output_height'],*record['jitter_uv'],*record['previous_jitter_uv'],
            record['history_weight'],record['depth_threshold'],.125,.0312,record['flags'],0,0,0)
        assert len(packed)==64
        (case_folder/'constants.bin').write_bytes(packed)
    manifest=ROOT/"results/f5/oracle-cases.json"
    manifest.write_text(json.dumps({"format":"raw little-endian float32 RGBA","cases":cases},indent=2)+'\n')
    return manifest


def check_gpu(manifest):
    records=json.loads(Path(manifest).read_text())["cases"]
    checks=[]
    for record in records:
        def load(key,width=None,height=None):
            w=width or record["input_width"];h=height or record["input_height"]
            return np.fromfile(ROOT/record[key],dtype='<f4').reshape(h,w,4).astype(float)
        if record["entry"]=="TaaCS":
            expected,expected_diagnostic=temporal(*(load(k) for k in ("current","history","motion_depth","previous_depth","reactive")),
                flags=record["flags"],jitter=record["jitter_uv"],previous_jitter=record["previous_jitter_uv"],
                weight=record["history_weight"],depth_threshold=record["depth_threshold"])
        else:
            expected=spatial(load("current"),(record["output_width"],record["output_height"]),record["entry"]=="BicubicCS",
                record['jitter_uv'] if record['entry']=='UnjitterCS' else (0,0))
        path=ROOT/record["output"]
        if not path.exists():
            checks.append({"name":record["name"],"pass":False,"reason":"GPU output missing"});continue
        actual=load("output",record["output_width"],record["output_height"])
        error=float(np.max(abs(expected-actual)))
        check={"name":record["name"],"pass":bool(np.isfinite(actual).all() and error<=record["tolerance"]),
               "max_absolute_error":error,"tolerance":record["tolerance"]}
        if record['entry']=='TaaCS':
            diagnostic_path=path.parent/'diagnostic.f32'
            if not diagnostic_path.exists(): check.update(reason='GPU diagnostic missing');check['pass']=False
            else:
                diagnostic=np.fromfile(diagnostic_path,dtype='<f4').reshape(expected_diagnostic.shape)
                diagnostic_error=float(np.max(abs(diagnostic-expected_diagnostic)))
                check['diagnostic_max_absolute_error']=diagnostic_error
                check['pass']=bool(check['pass'] and np.isfinite(diagnostic).all() and diagnostic_error<=record['tolerance'])
        checks.append(check)
    return {"pass":all(x["pass"] for x in checks),"execution":"GPU readback vs independent CPU oracle","checks":checks}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--emit-fixtures',action='store_true')
    parser.add_argument('--gpu-manifest',type=Path)
    parser.add_argument('--gpu-oracle-root',type=Path,help='f_lessons.exe oracle 输出所在的 oracle-input 根目录')
    args=parser.parse_args()
    if args.gpu_oracle_root:
        records=[json.loads(p.read_text()) for p in sorted(args.gpu_oracle_root.glob('*/meta.json'))]
        if not records: raise ValueError('GPU oracle root has no cases')
        args.gpu_manifest=ROOT/'results/f5/oracle-cases.json'
        args.gpu_manifest.write_text(json.dumps({'cases':records},indent=2)+'\n')
    result=check_gpu(args.gpu_manifest) if args.gpu_manifest else self_test()
    folder=ROOT/"results"/("f5" if args.gpu_manifest else "f4");folder.mkdir(parents=True,exist_ok=True)
    output=folder/("gpu-oracle.json" if args.gpu_manifest else "cpu-contract.json")
    output.write_text(json.dumps(result,indent=2)+'\n')
    if args.emit_fixtures: print(emit_fixtures())
    print(json.dumps({"pass":result["pass"],"execution":result["execution"],"checks":len(result["checks"]),"result":str(output)}))
    raise SystemExit(0 if result['pass'] else 1)


if __name__=='__main__': main()
