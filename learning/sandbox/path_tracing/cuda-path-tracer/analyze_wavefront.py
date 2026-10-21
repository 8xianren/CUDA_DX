"""PT.9 Wavefront线性图像对照、队列有效项与固定capacity网格的区别。"""
from pathlib import Path
import sys
import csv
import json
lesson = Path(__file__).resolve().parent
local = lesson / "build" / "python-deps"
if local.exists():
    sys.path.insert(0, str(local))
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

root = lesson / "results" / "wavefront"
def read_pfm(path):
    with path.open("rb") as f:
        assert f.readline().strip() == b"PF"
        w, h = map(int, f.readline().split())
        assert float(f.readline()) == -1.0
        return np.flipud(np.frombuffer(f.read(), dtype="<f4").reshape(h, w, 3)).copy()

records = list(csv.DictReader((root / "wavefront.csv").open(encoding="utf-8")))
summary = {}
for row in records:
    name = row["case"]
    a, b = read_pfm(root / f"{name}-mega.pfm"), read_pfm(root / f"{name}-wave.pfm")
    assert np.array_equal(a, b), f"image mismatch: {name}"
    summary[name] = {"max_abs_rgb_difference": float(np.max(np.abs(a-b))), "workspace_mib": int(row["workspace_bytes"])/1048576,
                     "mega_ms": float(row["mega_ms"]), "wave_ms": float(row["wave_ms"]), "wave_kernel_launches": int(row["wave_launches"])}

queues = list(csv.DictReader((root / "queues.csv").open(encoding="utf-8")))
gallery = [r for r in queues if r["case"] == "gallery"]
depths = [int(r["depth"]) for r in gallery]
rays = [int(r["current_rays"]) for r in gallery]
shadows = [int(r["shadows"]) for r in gallery]
fig, ax = plt.subplots(figsize=(8, 4.4), constrained_layout=True)
ax.plot(depths, rays, "o-", label="Valid ray queue entries")
# 最终层shadow=0不能放到对数轴；将该点留空，并在图注明确是0。
ax.plot(depths, [n if n else np.nan for n in shadows], "s-", label="Valid shadow queue entries (last = 0)")
ax.axhline(rays[0], color="gray", linestyle="--", label="Intersect / shade / shadow grid capacity")
for x, y in zip(depths, rays):
    ax.annotate(str(y), (x,y), xytext=(0,8), textcoords="offset points", ha="center", fontsize=8)
ax.set(yscale="log", xlabel="Path depth", ylabel="Entries / launched threads", xticks=depths, ylim=(300, 1800000), title="Gallery: compact data, fixed-capacity launch grid")
ax.grid(alpha=.2); ax.legend(fontsize=8)
fig.savefig(root / "queue-capacity.png", dpi=160)
plt.close(fig)

def show(a):
    x = np.maximum(a,0); x = x/(1+x)
    return np.where(x<=.0031308,12.92*x,1.055*x**(1/2.4)-.055)
fig, axes = plt.subplots(1,2,figsize=(12,4),constrained_layout=True)
for ax, backend in zip(axes,["mega","wave"]):
    ax.imshow(show(read_pfm(root / f"gallery-{backend}.pfm")),interpolation="nearest")
    ax.set_title("Megakernel" if backend=="mega" else "Wavefront (identical linear RGB)"); ax.axis("off")
fig.savefig(root / "backend-images.png",dpi=150)
plt.close(fig)
(root / "analysis.json").write_text(json.dumps(summary,indent=2),encoding="utf-8")
print(json.dumps(summary,indent=2))
