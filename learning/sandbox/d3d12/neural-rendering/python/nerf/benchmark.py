"""G.5：同一已训练NeRF的MLP推理与烘焙推理对照，独立统计训练、烘焙、推理和上传边界。"""
from pathlib import Path
import argparse
import hashlib
import json
import math
import statistics
import time
import numpy as np
import torch
from camera import Camera
from fields import TinyNeRF, BakedField, AnalyticField
from rendering import render_image, sample_rays, composite
from train import ROOT, write_json, source_hashes


def measure(operation, repeats=12):
    """Event计GPU时间；每轮同步避免将异步提交耗时当GPU完成时间。另记录CPU墙钟。"""
    with torch.no_grad():
        for _ in range(3):
            operation()
        torch.cuda.synchronize()
        torch.cuda.reset_peak_memory_stats()
        samples, wall = [], []
        for _ in range(repeats):
            start, end = torch.cuda.Event(enable_timing=True), torch.cuda.Event(enable_timing=True)
            before = time.perf_counter()
            start.record()
            operation()
            end.record()
            end.synchronize()
            wall.append((time.perf_counter() - before) * 1000)
            samples.append(start.elapsed_time(end))
    return {"median_gpu_ms": statistics.median(samples), "min_gpu_ms": min(samples),
            "max_gpu_ms": max(samples), "median_wall_ms": statistics.median(wall),
            "peak_allocated_bytes": torch.cuda.max_memory_allocated(), "repeats": repeats, "warmups": 3}


def image_metrics(image, reference):
    difference = image[..., :3] - reference[..., :3]
    mse = float(difference.square().mean())
    return {"rgb_mse": mse, "rgb_psnr_db": -10 * math.log10(max(mse, 1e-20)),
            "rgba_max_abs": float((image - reference).abs().max())}


def save_export(field, camera, output):
    output.mkdir(parents=True, exist_ok=True)
    torch.cuda.synchronize()
    begin = time.perf_counter()
    rgba, depth = render_image(field, camera, 64)
    occluded, occluded_depth = render_image(field, camera, 64, mesh_occlusion=True)
    torch.cuda.synchronize()
    inference_seconds = time.perf_counter() - begin
    # .cpu()完成设备到主机复制与同步；之后numpy字节不再借用CUDA张量存储。
    # G10把主机文件经cudaMemcpyAsync写入自有device buffer，再复制进导入的D3D12共享array。
    # 这里不暴露框架内部CUDA张量；共享资源自身的external-fence由G10拥有和同步。
    arrays = {"nerf_color.f32": rgba.cpu().numpy().astype("<f4"),
              "nerf_depth.f32": depth.cpu().numpy().astype("<f4"),
              "nerf_color_occluded.f32": occluded.cpu().numpy().astype("<f4"),
              "nerf_depth_occluded.f32": occluded_depth.cpu().numpy().astype("<f4")}
    files = {}
    for name, array in arrays.items():
        path = output / name
        array.tofile(path)
        files[name] = {"bytes": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    metadata = {"schema": "cuda-dx-nerf-output-v1", "camera": camera.metadata(),
                "format": "little-endian float32; tightly packed row-major H,W,C",
                "color": "linear RGB, premultiplied alpha, no background, no tone mapping",
                "depth": "conditional expected positive camera-Z, far=10 if alpha<1e-4; NOT opaque depth",
                "occlusion": {"foreground_rectangle_world": [-.18, .18, -.8, .8, -.65],
                              "background_world_z": 1.5, "method": "truncate integration at mesh ray intersection"},
                "samples_per_ray": 64, "inference_and_occluded_wall_seconds": inference_seconds,
                "producer": "PyTorch trained coefficients -> grid_sample -> host float32 files",
                "consumer": "G10 host float files -> cudaMemcpyAsync HtoD owned linear buffer -> cudaMemcpy2DToArrayAsync imported D3D12 shared texture; explicit staging, NOT shared PyTorch tensor",
                "files": files}
    write_json(output / "nerf_camera.json", metadata)
    # PNG只供人眼观察：先合成棋盘背景，再线性转sRGB；不用于误差统计。
    from PIL import Image
    image = arrays["nerf_color.f32"]
    y, x = np.indices(image.shape[:2])
    background = np.where(((x // 24 + y // 24) % 2)[..., None], .16, .28)
    linear = image[..., :3] + (1 - image[..., 3:4]) * background
    srgb = np.where(linear <= .0031308, 12.92 * linear, 1.055 * np.maximum(linear, 0) ** (1 / 2.4) - .055)
    Image.fromarray((srgb.clip(0, 1) * 255 + .5).astype(np.uint8)).save(output / "nerf_preview.png")
    return metadata


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int, default=360)
    parser.add_argument("--grid", type=int, default=64)
    parser.add_argument("--export-only", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    torch.set_num_threads(4)
    torch.backends.cuda.matmul.allow_tf32 = False
    checkpoint_path = ROOT / "results" / "g4" / "tiny_nerf.pt"
    checkpoint = torch.load(checkpoint_path, map_location="cuda", weights_only=True)
    if checkpoint["schema"] != 1:
        raise ValueError("unknown NeRF checkpoint schema")
    model = TinyNeRF(checkpoint["levels"], checkpoint["width"]).cuda().eval()
    model.load_state_dict(checkpoint["state_dict"], strict=True)
    torch.cuda.synchronize()
    begin = time.perf_counter()
    baked = BakedField.from_model(model, args.grid)
    torch.cuda.synchronize()
    bake_seconds = time.perf_counter() - begin
    output = args.output or ROOT / "results" / "g5"
    output.mkdir(parents=True, exist_ok=True)
    if not args.export_only:
        camera = Camera(128, 96)
        reference, _ = render_image(AnalyticField(), camera, 192)
        direct, _ = render_image(model, camera, 64)
        cached, _ = render_image(baked, camera, 64)
        # 在相同射线、相同64步、相同合成器上只替换场查询，避免把降低分辨率当成加速。
        direct_timing = measure(lambda: render_image(model, camera, 64))
        cached_timing = measure(lambda: render_image(baked, camera, 64))
        origins, directions = camera.rays("cuda")
        points, t, delta = sample_rays(origins[:2048], directions[:2048], 64)
        expanded = directions[:2048, None, :].expand_as(points)
        with torch.no_grad():
            sigma, rgb = model(points, expanded)
        cost_split = {"rays": 2048, "samples_per_ray": 64,
                      "ray_sampling": measure(lambda: sample_rays(origins[:2048], directions[:2048], 64)),
                      "mlp_query": measure(lambda: model(points, expanded)),
                      "baked_query": measure(lambda: baked(points, expanded)),
                      "composite": measure(lambda: composite(sigma, rgb, t, delta))}
        # 在网格节点验证方向系数确实来自该checkpoint，非来自解析教师。
        axis = torch.linspace(-1, 1, args.grid, device="cuda")
        indices = torch.tensor([[0, 0, 0], [31, 27, 16], [63, 63, 63]], device="cuda").clamp_max(args.grid - 1)
        positions = axis[indices]
        direction = torch.nn.functional.normalize(torch.ones_like(positions), dim=-1)
        with torch.no_grad():
            direct_sigma, direct_color = model(positions, direction)
            cached_sigma, cached_color = baked(positions, direction)
            node_error = float(torch.cat((direct_sigma - cached_sigma, (direct_color - cached_color).flatten())).abs().max())
        training = json.loads((ROOT / "results/g4/training.json").read_text(encoding="utf-8"))
        report = {"status": "PASS" if image_metrics(cached, direct)["rgb_mse"] < 1e-4 and node_error < 1e-4 else "FAIL",
                  "gpu": torch.cuda.get_device_name(), "torch": torch.__version__,
                  "resolution": [camera.width, camera.height], "samples_per_ray": 64,
                  "grid_resolution": args.grid, "grid_channels": 13,
                  "grid_bytes": baked.grid.numel() * baked.grid.element_size(),
                  "mlp_parameter_bytes": sum(p.numel() * p.element_size() for p in model.parameters()),
                  "training_seconds_baseline": training["training_wall_seconds"],
                  "training_seconds_accelerated_path": training["training_wall_seconds"],
                  "additional_bake_seconds": bake_seconds, "training_speedup_claimed": False,
                  "direct_mlp": direct_timing, "baked_grid": cached_timing,
                  "inference_speedup": direct_timing["median_gpu_ms"] / cached_timing["median_gpu_ms"],
                  "direct_vs_analytic": image_metrics(direct, reference),
                  "baked_vs_analytic": image_metrics(cached, reference),
                  "baked_vs_direct": image_metrics(cached, direct), "grid_node_max_error": node_error,
                  "cost_split": cost_split, "source_hashes": source_hashes(),
                  "checkpoint_sha256": hashlib.sha256(checkpoint_path.read_bytes()).hexdigest(),
                  "timing_limits": ["PyTorch event interval includes host launch gaps, not pure kernel active duration",
                                    "peak allocated is process torch memory including both resident representations",
                                    "fixed camera/scene; no Instant-NGP or production real-time claim"]}
        write_json(output / "benchmark.json", report)
        print(json.dumps(report, indent=2), flush=True)
        if report["status"] != "PASS":
            raise RuntimeError("bake equivalence failed")
    metadata = save_export(baked, Camera(args.width, args.height), output)
    print(json.dumps({"export": str(output), "resolution": [args.width, args.height],
                      "files": metadata["files"]}, indent=2), flush=True)


if __name__ == "__main__":
    main()
