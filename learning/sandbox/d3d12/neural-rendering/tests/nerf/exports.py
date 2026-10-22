"""CPU检验实际给D3D12的字节，而不仅是Python内的张量形状。"""
from pathlib import Path
import hashlib
import json
import numpy as np

ROOT = Path(__file__).resolve().parents[2]


def main():
    checks = []
    def check(name, value):
        checks.append({"name": name, "pass": bool(value)})
        if not value:
            raise AssertionError(name)
    for directory, expected_size in ((ROOT / "results/g5", (640, 360)),
                                     (ROOT / "results/g5/resize-320x240", (320, 240))):
        metadata = json.loads((directory / "nerf_camera.json").read_text(encoding="utf-8"))
        camera = metadata["camera"]
        width, height = camera["width"], camera["height"]
        prefix = f"{width}x{height}:"
        check(prefix + "expected_dimensions", (width, height) == expected_size)
        values = {}
        for name, record in metadata["files"].items():
            path = directory / name
            check(prefix + name + "_sha256", hashlib.sha256(path.read_bytes()).hexdigest() == record["sha256"])
            channels = 4 if "color" in name else 1
            check(prefix + name + "_bytes", path.stat().st_size == width * height * channels * 4)
            array = np.fromfile(path, dtype="<f4").reshape(height, width, channels)
            check(prefix + name + "_finite", np.isfinite(array).all())
            values[name] = array
        color, occluded = values["nerf_color.f32"], values["nerf_color_occluded.f32"]
        depth, clipped_depth = values["nerf_depth.f32"][..., 0], values["nerf_depth_occluded.f32"][..., 0]
        for label, image in (("plain", color), ("occluded", occluded)):
            check(prefix + label + "_alpha_bounded", (image[..., 3] >= 0).all() and (image[..., 3] <= 1.000001).all())
            check(prefix + label + "_premultiplied", (image[..., :3] >= 0).all() and (image[..., :3] <= image[..., 3:4] + 1e-6).all())
        y, x = np.indices((height, width))
        # z=-.65距默认eye的cameraZ为2.35；这里独立按针孔方程重建交点，不复用导出器代码。
        world_x = (x + .5 - camera["cx"]) / camera["fx"] * 2.35
        world_y = -(y + .5 - camera["cy"]) / camera["fy"] * 2.35
        front = (np.abs(world_x) <= .18) & (np.abs(world_y) <= .8)
        check(prefix + "outside_foreground_identical", np.array_equal(color[~front], occluded[~front]))
        check(prefix + "occlusion_changes_foreground", np.max(np.abs(color[front] - occluded[front])) > .1)
        valid = front & (occluded[..., 3] >= 1e-4)
        check(prefix + "truncated_expected_depth_before_mesh", np.all(clipped_depth[valid] <= 2.35001))
        check(prefix + "empty_depth_is_far", np.all(depth[color[..., 3] < 1e-4] == camera["far"]))
    report = {"status": "PASS", "checks": len(checks), "details": checks}
    (ROOT / "results/g5/export-validation.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
