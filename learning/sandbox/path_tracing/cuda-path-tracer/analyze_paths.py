"""PT.9线性HDR对照与实际GPU图像；不从显示PNG反推积分正确性。"""
from pathlib import Path
import csv
import json
import sys
# 绘图依赖可安装到本课build/python-deps，不改系统Python环境；需用安装时相同的Python运行。
local_dependencies = Path(__file__).resolve().parent / "build" / "python-deps"
if local_dependencies.exists():
    sys.path.insert(0, str(local_dependencies))
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

root = Path(__file__).resolve().parent / "results" / "megakernel"

def pfm(path):
    with path.open("rb") as f:
        assert f.readline().strip() == b"PF"
        w, h = map(int, f.readline().split())
        assert float(f.readline()) == -1.0
        a = np.frombuffer(f.read(), dtype="<f4").reshape(h, w, 3)
    return np.flipud(a).copy()

def display(a):
    # 与C++预览相同：非负线性HDR→Reinhard→一次sRGB。数值验收仍使用原始PFM。
    x = np.maximum(a, 0)
    x = x / (1 + x)
    return np.where(x <= .0031308, 12.92*x, 1.055*x**(1/2.4)-.055)

records = list(csv.DictReader((root / "paths.csv").open(encoding="utf-8")))
lookup = {r["case"]: r for r in records}
summary = {}
for name in ("K0-emission", "K1-direct", "K4-MIS", "K4-RR", "K4-BSDF-only"):
    gpu, cpu = pfm(root / f"{name}.pfm"), pfm(root / f"{name}-cpu.pfm")
    diff = gpu.astype(np.float64) - cpu.astype(np.float64)
    summary[name] = {"max_abs": float(np.abs(diff).max()), "max_normalized": float((np.abs(diff)/(1+np.abs(cpu))).max()), "mse": float((diff*diff).mean())}
    assert summary[name]["max_normalized"] < 2e-4

fig, axes = plt.subplots(1, 2, figsize=(12, 4.7), constrained_layout=True)
for ax, name, title in zip(axes, ["cornell", "gallery-lambert"], ["CUDA Lambert / 144 x 96 / 128 spp / K=8", "CUDA Lambert override / 192 x 96 / 32 spp / K=6"]):
    ax.imshow(display(pfm(root / f"{name}.pfm")), interpolation="nearest")
    ax.set_title(title, fontsize=11)
    ax.axis("off")
fig.savefig(root / "gpu-images.png", dpi=150)
plt.close(fig)

gpu, cpu = pfm(root / "K4-RR.pfm"), pfm(root / "K4-RR-cpu.pfm")
error = np.max(np.abs(gpu.astype(np.float64)-cpu), axis=2)
fig, axes = plt.subplots(1, 3, figsize=(12, 3.4), constrained_layout=True)
axes[0].imshow(display(cpu), interpolation="nearest"); axes[0].set_title("CPU double reference")
axes[1].imshow(display(gpu), interpolation="nearest"); axes[1].set_title("CUDA float / BVH")
im = axes[2].imshow(error, cmap="magma", interpolation="nearest", vmin=0, vmax=max(error.max(), 1e-12))
axes[2].set_title(f"Linear RGB max error: {error.max():.3g}")
fig.colorbar(im, ax=axes[2], shrink=.7)
for ax in axes: ax.axis("off")
fig.savefig(root / "cpu-gpu.png", dpi=150)
plt.close(fig)

fig, ax = plt.subplots(figsize=(7, 4), constrained_layout=True)
for name, label in [("K4-MIS", "RR off"), ("K4-RR", "RR from 3rd scatter")]:
    values = [int(lookup[name][f"active_{i}"]) for i in range(5)]
    ax.plot(range(5), values, "o-", label=label)
    for i, value in enumerate(values):
        ax.annotate(str(value), (i, value), xytext=(4, 6 if name == "K4-MIS" else -16), textcoords="offset points", fontsize=8)
ax.set(xlabel="Path ray depth (0 = camera)", ylabel="Active sample paths", xticks=range(5), ylim=(0, 4700), title="Same 31 x 17 x 8 starting samples")
ax.grid(alpha=.2); ax.legend()
fig.savefig(root / "active-paths.png", dpi=160)
plt.close(fig)
(root / "analysis.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
print(json.dumps(summary, indent=2))
