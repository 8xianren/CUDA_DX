"""严格解码 GraphDeco PLY 为 GSBIN v1；不猜测通用 PLY 的语义。

PLY 保存优化器的无约束参数：scale 是对数尺度，opacity 是 logit；运行时
需 exp/sigmoid。f_rest 是按 RGB 通道分别展开，内部则每个 SH 基函数存 RGB。
所有源属性必须存在且为 float32，未知属性直接报错，避免误导入网格/压缩 PLY。
"""
from pathlib import Path
import argparse
import hashlib
import json
import math
import struct
import time
import numpy as np

ROOT = Path(__file__).resolve().parents[2]


def read_ply(path):
    with Path(path).open("rb") as f:
        if f.readline().strip() != b"ply":
            raise ValueError("not a PLY file")
        if f.readline().strip() != b"format binary_little_endian 1.0":
            raise ValueError("only binary_little_endian 1.0 is supported")
        properties, count = [], None
        for _ in range(256):
            line = f.readline().decode("ascii").strip()
            if line == "end_header":
                break
            if line.startswith("comment "):
                continue
            parts = line.split()
            if parts[:2] == ["element", "vertex"] and count is None:
                count = int(parts[2])
                if not 0 < count <= 10_000_000:
                    raise ValueError("vertex count outside supported bounds")
            elif len(parts) == 3 and parts[:2] == ["property", "float"]:
                if parts[2] in properties:
                    raise ValueError("duplicate property " + parts[2])
                properties.append(parts[2])
            else:
                raise ValueError("unknown PLY header declaration: " + line)
        else:
            raise ValueError("header too long")
        if count is None:
            raise ValueError("missing vertex element")
        base = ["x", "y", "z", "nx", "ny", "nz"] + [f"f_dc_{i}" for i in range(3)]
        base += ["opacity"] + [f"scale_{i}" for i in range(3)] + [f"rot_{i}" for i in range(4)]
        rests = [p for p in properties if p.startswith("f_rest_")]
        degree = math.isqrt(len(rests) // 3 + 1) - 1
        if degree not in range(4) or len(rests) != 3 * ((degree + 1) ** 2 - 1):
            raise ValueError("SH rest count is not degree 0..3")
        required = set(base + [f"f_rest_{i}" for i in range(len(rests))])
        missing, unknown = required - set(properties), set(properties) - required
        if missing or unknown:
            raise ValueError(f"property mismatch: missing={sorted(missing)}, unknown={sorted(unknown)}")
        data = np.fromfile(f, dtype=np.dtype([(p, "<f4") for p in properties]), count=count)
        if len(data) != count or f.read(1):
            raise ValueError("truncated payload or unexpected trailing bytes")
    # 先校验原始数值，不能在转换时把 NaN 或 exp 溢出悄悄截断成看似有效的场景。
    if not np.isfinite(data.view("<f4")).all():
        raise ValueError("nonfinite PLY parameter")
    return data, degree


def convert(path, destination):
    start = time.perf_counter()
    data, degree = read_ply(path)
    n = len(data)
    xyz = np.stack([data[k] for k in ("x", "y", "z")], axis=1)
    raw_scale = np.stack([data[f"scale_{i}"] for i in range(3)], axis=1)
    scale = np.exp(raw_scale.astype(np.float64))
    quat = np.stack([data[f"rot_{i}"] for i in range(4)], axis=1).astype(np.float64)
    norms = np.linalg.norm(quat, axis=1)
    if np.any(norms < 1e-12) or not np.isfinite(scale).all() or np.any(scale <= 0):
        raise ValueError("invalid quaternion or decoded scale")
    quat /= norms[:, None]
    logit = data["opacity"].astype(np.float64)
    # 等价 sigmoid 分段避免大负输入导致 exp(-x) 溢出。
    opacity = np.empty(n)
    positive = logit >= 0
    opacity[positive] = 1 / (1 + np.exp(-logit[positive]))
    e = np.exp(logit[~positive]); opacity[~positive] = e / (1 + e)
    sh = np.zeros((n, 16, 3), dtype=np.float32)
    sh[:, 0] = np.stack([data[f"f_dc_{i}"] for i in range(3)], axis=1)
    rest = (degree + 1) ** 2 - 1
    if rest:
        packed = np.stack([data[f"f_rest_{i}"] for i in range(rest * 3)], axis=1)
        sh[:, 1:rest + 1] = packed.reshape(n, 3, rest).transpose(0, 2, 1)
    # 版本化 wire 格式明确固定小端；不能依赖任意编译器 struct padding。
    dtype = np.dtype([("mean", "<f4", 3), ("scale", "<f4", 3),
                      ("rotation", "<f4", 4), ("opacity", "<f4"),
                      ("sh", "<f4", 48), ("id", "<u4"), ("degree", "<u4")])
    output = np.empty(n, dtype=dtype)
    for name, value in (("mean", xyz), ("scale", scale), ("rotation", quat),
                        ("opacity", opacity), ("sh", sh.reshape(n, 48))):
        output[name] = value
    output["id"] = np.arange(n, dtype=np.uint32); output["degree"] = degree
    if not np.isfinite(output["scale"]).all() or np.any(output["scale"] <= 0):
        raise ValueError("float32 runtime scale is not representable")
    destination = Path(destination); destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("wb") as f:
        f.write(struct.pack("<8s4I", b"GSBIN001", n, dtype.itemsize, degree, 0))
        output.tofile(f)
    # 检查逐字段转换，绝不仅凭写入成功判断导入通过。
    reconstructed = np.fromfile(destination, dtype=dtype, offset=24)
    assert len(reconstructed) == n
    assert np.array_equal(reconstructed["mean"], xyz)
    assert np.array_equal(reconstructed["sh"], sh.reshape(n, 48))
    assert np.max(abs(np.linalg.norm(reconstructed["rotation"], axis=1) - 1)) < 2e-6
    assert np.max(abs(reconstructed["opacity"] - opacity)) < 1e-7
    assert np.max(abs(reconstructed["scale"].astype(np.float64) / scale - 1)) < 1e-6
    low, high = np.quantile(xyz, [.02, .98], axis=0)
    report = {"pass": True, "count": n, "degree": degree, "stride": dtype.itemsize,
              "format": "GSBIN001", "source_bytes": Path(path).stat().st_size,
              "runtime_bytes": destination.stat().st_size,
              "source_sha256": hashlib.sha256(Path(path).read_bytes()).hexdigest(),
              "runtime_sha256": hashlib.sha256(destination.read_bytes()).hexdigest(),
              "position_min": xyz.min(0).tolist(), "position_max": xyz.max(0).tolist(),
              "scale_min": float(scale.min()), "scale_max": float(scale.max()),
              "opacity_min": float(opacity.min()), "opacity_max": float(opacity.max()),
              "quaternion_input_norm_min": float(norms.min()), "quaternion_input_norm_max": float(norms.max()),
              "display_center": ((low + high) / 2).tolist(),
              "display_uniform_scale": float(max(high - low) / 2),
              "load_convert_validate_seconds": time.perf_counter() - start,
              "checks": ["count", "exact_position", "positive_exp_scale", "normalized_wxyz",
                         "sigmoid_opacity", "exact_sh_channel_transpose", "degree", "finite"]}
    out = ROOT / "results/g9"; out.mkdir(parents=True, exist_ok=True)
    (out / "import.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, default=ROOT / "downloads/reference/train-7000.ply")
    parser.add_argument("--output", type=Path, default=ROOT / "downloads/reference/train-7000.gsbin")
    args = parser.parse_args()
    convert(args.input, args.output)
