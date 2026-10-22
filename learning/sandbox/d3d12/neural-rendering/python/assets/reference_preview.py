"""将参考相机数值结果保存为可查看PNG并合并来源/相机/运行报告，不修改原始浮点结果。"""
from pathlib import Path
import hashlib
import json
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "results/g9/reference-preview"


def main():
    raw = OUTPUT / "camera0.f32"
    values = np.fromfile(raw, dtype="<f4").reshape(360, 640, 4)
    if not np.isfinite(values).all():
        raise ValueError("nonfinite preview data")
    # GraphDeco参考训练通常直接拟合图像RGB数值；此预览不额外加gamma，避免二次编码变亮。
    # 黑色背景合成C+(1-A)*0=C。若训练资产实际色彩管理不同，需其元数据另行证明。
    pixels = (np.clip(values[..., :3], 0, 1) * 255 + .5).astype(np.uint8)
    destination = OUTPUT / "camera0.png"
    Image.fromarray(pixels).save(destination)
    report = json.loads((OUTPUT / "render.json").read_text(encoding="utf-8"))
    report["camera_and_provenance"] = json.loads((OUTPUT / "camera-provenance.json").read_text(encoding="utf-8"))
    report["float_sha256"] = hashlib.sha256(raw.read_bytes()).hexdigest()
    report["png_sha256"] = hashlib.sha256(destination.read_bytes()).hexdigest()
    report["output_color"] = "clamped upstream trained RGB values, black background, no extra gamma"
    report["output_rgb_mean"] = values[..., :3].mean(axis=(0, 1)).tolist()
    report["source_hashes"] = {
        str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in [ROOT / "tests/assets/reference_render.cpp", ROOT / "tests/assets/reference_build.ps1",
                     ROOT / "python/assets/reference_camera.py", ROOT / "python/assets/reference_preview.py",
                     ROOT / "src/gaussian/gaussian.cu", ROOT / "src/gaussian/gaussian.h",
                     ROOT / "src/gaussian/projection_math.cuh"]}
    (OUTPUT / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps({"preview": str(destination), "full_count": report["full_gaussian_count"],
                      "visible": report["visible_gaussian_count"], "wall_ms": report["single_render_wall_ms"]}, indent=2))


if __name__ == "__main__":
    main()
