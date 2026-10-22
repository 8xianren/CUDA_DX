"""G.9独立复现：下载同一个固定revision中的PLY与相机，不将不同训练资产随意配对。"""
from pathlib import Path
import contextlib
import hashlib
import importlib.util
import io
import json
import struct
import tempfile
import urllib.request
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
REVISION = "c63df2ffae19c1d288f81c1d5faf53ff6661be84"
BASE = f"https://huggingface.co/camenduru/gaussian-splatting/resolve/{REVISION}/train/"
PLY_SHA256 = "e1bc6c22fa74db350a783385f578be0eb5465c1df0daaedb33fa10c99e10c380"
CAMERA_GIT_BLOB_SHA1 = "9161764757516dcd273d1e35b96569c81b19c223"
OUTPUT = ROOT / "results/g9/reference-preview"


def download(relative, destination, expected, kind="sha256"):
    def digest(data):
        if kind == "git-blob-sha1":
            return hashlib.sha1(f"blob {len(data)}\0".encode("ascii") + data).hexdigest()
        return hashlib.sha256(data).hexdigest()
    if not destination.exists() or digest(destination.read_bytes()) != expected:
        partial = destination.with_suffix(".partial")
        with urllib.request.urlopen(BASE + relative, timeout=120) as response, partial.open("wb") as out:
            while block := response.read(1024 * 1024):
                out.write(block)
        if digest(partial.read_bytes()) != expected:
            raise RuntimeError("paired reference hash mismatch: " + relative)
        partial.replace(destination)


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    downloads = ROOT / "downloads/reference"
    downloads.mkdir(parents=True, exist_ok=True)
    ply = downloads / "camera-paired-train-7000.ply"
    cameras = downloads / "camera-paired-cameras.json"
    runtime = downloads / "camera-paired-train-7000.gsbin"
    download("point_cloud/iteration_7000/point_cloud.ply", ply, PLY_SHA256)
    download("cameras.json", cameras, CAMERA_GIT_BLOB_SHA1, "git-blob-sha1")
    # 复用严格字段转换器，但隔离ROOT，不能覆盖另一套已验收资产的g9/import.json。
    spec = importlib.util.spec_from_file_location("paired_converter", ROOT / "python/assets/convert_ply.py")
    converter = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(converter)
    with tempfile.TemporaryDirectory(prefix="paired-import-", dir=OUTPUT) as temporary:
        # 临时输出固定在本课preview子树内，离开上下文仅清理本次唯一生成的目录。
        converter.ROOT = Path(temporary).resolve()
        converter.ROOT.relative_to(OUTPUT.resolve())
        with contextlib.redirect_stdout(io.StringIO()):
            converter.convert(ply, runtime)
        report = json.loads((converter.ROOT / "results/g9/import.json").read_text(encoding="utf-8"))
    (OUTPUT / "camera-paired-import.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    all_cameras = json.loads(cameras.read_text(encoding="utf-8"))
    camera = next(c for c in all_cameras if c["id"] == 0)
    rotation = np.asarray(camera["rotation"], dtype=np.float64)
    position = np.asarray(camera["position"], dtype=np.float64)
    # 上游camera_to_JSON先对world->camera求逆，再输出rotation与position，故这里是C2W。
    c2w = np.eye(4)
    c2w[:3, :3], c2w[:3, 3] = rotation, position
    w2c_colmap = np.linalg.inv(c2w)
    expected_w2c = np.eye(4)
    expected_w2c[:3, :3] = rotation.T
    expected_w2c[:3, 3] = -rotation.T @ position
    inverse_error = float(np.abs(w2c_colmap - expected_w2c).max())
    if inverse_error > 1e-10:
        raise ValueError("reference camera is not an orthonormal rigid transform")
    flip = np.diag([1., -1., 1., 1.])
    w2c_gs = flip @ w2c_colmap
    width, height = 640, 360
    fx, fy = camera["fx"] * width / camera["width"], camera["fy"] * height / camera["height"]
    cx, cy = width / 2, height / 2
    # 独立核对多个相机点：上游+Ydown投影和本课+Yup投影应映到相同像素。
    points_camera = np.array([[0, 0, 2, 1], [.5, -.2, 3, 1], [-.7, .6, 4, 1]])
    points_world = (c2w @ points_camera.T).T
    transformed = (w2c_gs @ points_world.T).T
    source_uv = np.stack((fx * points_camera[:, 0] / points_camera[:, 2] + cx,
                          fy * points_camera[:, 1] / points_camera[:, 2] + cy), axis=-1)
    gs_uv = np.stack((fx * transformed[:, 0] / transformed[:, 2] + cx,
                      cy - fy * transformed[:, 1] / transformed[:, 2]), axis=-1)
    projection_error = float(np.abs(gs_uv - source_uv).max())
    if projection_error > 1e-8:
        raise ValueError("reference camera convention conversion changed projection")
    float_transformed = (w2c_gs[:3].astype(np.float32).astype(np.float64) @ points_world.T).T
    float_uv = np.stack((np.float32(fx) * float_transformed[:, 0] / float_transformed[:, 2] + cx,
                         cy - np.float32(fy) * float_transformed[:, 1] / float_transformed[:, 2]), axis=-1)
    float_projection_error = float(np.abs(float_uv - source_uv).max())
    if float_projection_error > 1e-3:
        raise ValueError("float32 renderer camera conversion exceeded pixel tolerance")
    packed = struct.pack("<2I18f", width, height, *w2c_gs[:3].astype(np.float32).ravel(),
                         fx, fy, cx, cy, .05, 4096.)
    (downloads / "camera-paired-camera0.bin").write_bytes(packed)
    provenance = {"repository": "camenduru/gaussian-splatting", "revision": REVISION,
                  "source_ply_url": BASE + "point_cloud/iteration_7000/point_cloud.ply",
                  "source_camera_url": BASE + "cameras.json", "ply_sha256": PLY_SHA256,
                  "ply_bytes": ply.stat().st_size, "camera_git_blob_sha1": CAMERA_GIT_BLOB_SHA1,
                  "camera_sha256": hashlib.sha256(cameras.read_bytes()).hexdigest(),
                  "runtime_sha256": hashlib.sha256(runtime.read_bytes()).hexdigest(),
                  "camera_count": len(all_cameras), "source_camera": camera,
                  "output_resolution": [width, height], "camera_id": 0,
                  "world_to_camera_gs": w2c_gs.tolist(), "fx": fx, "fy": fy, "cx": cx, "cy": cy,
                  "inverse_max_abs_error": inverse_error, "projection_max_abs_error_pixels": projection_error,
                  "float32_projection_max_abs_error_pixels": float_projection_error,
                  "convention": "JSON rotation/position are C2W with camera +Ydown; GS W2C=diag(1,-1,1,1)*inverse(C2W)",
                  "resize": "fx scales by640/1959; fy scales by360/1090; no bbox normalization of asset",
                  "color_limit": "upstream trained image RGB values; preview clamps without extra gamma, not proven physical linear radiance",
                  "trained_locally": False, "source_training": "paired mirror of GraphDeco train/iteration_7000"}
    (OUTPUT / "camera-provenance.json").write_text(json.dumps(provenance, indent=2), encoding="utf-8")
    print(json.dumps({"count": report["count"], "degree": report["degree"],
                      "inverse_error": inverse_error, "pixel_error": projection_error,
                      "ply": str(ply), "runtime": str(runtime)}, indent=2))


if __name__ == "__main__":
    main()
