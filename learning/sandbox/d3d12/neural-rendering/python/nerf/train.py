"""G.4：小型多视角RGBA监督训练，检查真正的前向/反向/优化，不访问解析场内部标签。"""
from pathlib import Path
import argparse
import csv
import hashlib
import json
import math
import platform
import time
import torch
from camera import Camera
from fields import AnalyticField, TinyNeRF
from rendering import render_rays, render_image

ROOT = Path(__file__).resolve().parents[2]


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")


def source_hashes():
    return {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in Path(__file__).parent.glob("*.py")}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--steps", type=int, default=1800)
    parser.add_argument("--batch", type=int, default=512)
    parser.add_argument("--seed", type=int, default=20261022)
    args = parser.parse_args()
    torch.manual_seed(args.seed)
    if not torch.cuda.is_available() or torch.cuda.get_device_capability() != (12, 0):
        raise RuntimeError("本机验收要求RTX5070 sm_120可用；不静默转CPU并冒充GPU实测")
    torch.set_num_threads(4)
    torch.backends.cuda.matmul.allow_tf32 = False
    torch.backends.cudnn.allow_tf32 = False
    device = "cuda"
    output = ROOT / "results" / "g4"
    output.mkdir(parents=True, exist_ok=True)
    teacher = AnalyticField()
    origins, directions, targets = [], [], []
    # 12张32×32环绕视图：监督数据只有线性RGBA及相机；透明合成背景可任意改变。
    # 这是合成透明体测试，不声称RGB真实照片有可直接获取的alpha真值。
    with torch.no_grad():
        for view in range(12):
            angle = view * 2 * math.pi / 12
            camera = Camera(32, 32, (3 * math.sin(angle), .25 * math.sin(2 * angle), -3 * math.cos(angle)))
            origin, direction = camera.rays(device)
            rgba, _ = render_image(teacher, camera, samples=96)
            origins.append(origin)
            directions.append(direction)
            targets.append(rgba.reshape(-1, 4))
    origins, directions, targets = map(torch.cat, (origins, directions, targets))
    model = TinyNeRF().to(device)
    optimizer = torch.optim.Adam(model.parameters(), lr=.002)
    initial = None
    records = []
    first_gradient = None
    torch.cuda.synchronize()
    torch.cuda.reset_peak_memory_stats()
    begin = time.perf_counter()
    for step in range(args.steps):
        indices = torch.randint(len(origins), (args.batch,), device=device)
        # zero_grad(set_to_none=True)释放旧梯度引用；backward写新梯度；step只更新本模型参数。
        optimizer.zero_grad(set_to_none=True)
        predicted, _, weights = render_rays(model, origins[indices], directions[indices], 48, jitter=True)
        loss = (predicted - targets[indices]).square().mean()
        loss.backward()
        if step == 0:
            initial = float(loss.detach())
            first_gradient = float(torch.sqrt(sum(p.grad.square().sum() for p in model.parameters())))
            if not math.isfinite(first_gradient) or first_gradient <= 0:
                raise RuntimeError("前向有结果但反向梯度无效")
        optimizer.step()
        # 后半程减小学习率，数值结果记录不只保留最后一个随机batch。
        if step in (args.steps * 2 // 3, args.steps * 5 // 6):
            for group in optimizer.param_groups:
                group["lr"] *= .4
        if step % 100 == 0 or step == args.steps - 1:
            value = float(loss.detach())
            records.append({"step": step, "rgba_mse": value})
            print(f"step={step} rgba_mse={value:.8f}", flush=True)
    torch.cuda.synchronize()
    training_seconds = time.perf_counter() - begin
    peak = torch.cuda.max_memory_allocated()
    model.eval()
    with torch.no_grad():
        predicted = torch.cat([render_rays(model, o, d, 48)[0]
                               for o, d in zip(origins.split(1024), directions.split(1024))])
        mse = float((predicted - targets).square().mean())
        rgb_mse = float((predicted[:, :3] - targets[:, :3]).square().mean())
        held_camera = Camera(64, 64, (.55, .17, -2.95))
        held_reference, _ = render_image(teacher, held_camera, 96)
        held_prediction, _ = render_image(model, held_camera, 64)
        held_mse = float((held_prediction[..., :3] - held_reference[..., :3]).square().mean())
    checkpoint = output / "tiny_nerf.pt"
    # 只保存tensor与普通标量；加载时weights_only=True，避免反序列化任意Python类。
    torch.save({"schema": 1, "state_dict": model.state_dict(), "levels": model.levels,
                "width": model.width, "seed": args.seed, "steps": args.steps}, checkpoint)
    with (output / "loss.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=["step", "rgba_mse"])
        writer.writeheader()
        writer.writerows(records)
    report = {"status": "PASS" if mse < .001 and mse < initial / 20 else "FAIL",
              "torch": torch.__version__, "torch_cuda": torch.version.cuda,
              "python": platform.python_version(), "gpu": torch.cuda.get_device_name(),
              "capability": list(torch.cuda.get_device_capability()), "compiled_arches": torch.cuda.get_arch_list(),
              "seed": args.seed, "training_views": 12, "training_resolution": [32, 32],
              "steps": args.steps, "rays_per_step": args.batch, "samples_per_ray": 48,
              "initial_batch_rgba_mse": initial, "first_gradient_l2": first_gradient,
              "final_all_training_rgba_mse": mse, "final_all_training_rgb_mse": rgb_mse,
              "held_out_rgb_mse": held_mse, "held_out_rgb_psnr": -10 * math.log10(held_mse),
              "training_wall_seconds": training_seconds, "training_peak_allocated_bytes": peak,
              "parameters": sum(p.numel() for p in model.parameters()), "checkpoint_bytes": checkpoint.stat().st_size,
              "checkpoint_sha256": hashlib.sha256(checkpoint.read_bytes()).hexdigest(),
              "source_hashes": source_hashes(),
              "limits": ["synthetic RGBA supervision, not RGB-photo production reconstruction",
                         "small positional MLP with linear directional logits; not original NeRF architecture",
                         "training wall time includes sparse progress synchronization; dataset generation excluded"]}
    write_json(output / "training.json", report)
    print(json.dumps(report, indent=2), flush=True)
    if report["status"] != "PASS":
        raise RuntimeError("未满足固定过拟合验收阈值")


if __name__ == "__main__":
    main()
