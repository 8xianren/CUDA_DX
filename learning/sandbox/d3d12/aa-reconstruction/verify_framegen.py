"""F.9 官方帧生成窗口验收：真实 GPU/DLL + 独立 ETW 呈现证据。

不用 CPU 插值替代 SDK。Python 仅启动程序、检查日志/读回像素、汇总计时。
默认从固定版本 URL 恢复 PresentMon，验证 SHA256 后运行；另用 DXGI 系统统计交叉取证。
ETW 显示数据缺失时保留原始日志并让显示验收失败，绝不把显示回调的 CPU 时间
伪装成显示节奏。物理扫描/光子延迟仍不在本实验范围内。
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
from pathlib import Path
import statistics
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parent


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8-sig", newline="") as stream:
        return list(csv.DictReader(stream))


def stats(values: list[float]) -> dict[str, float | int]:
    values = sorted(x for x in values if math.isfinite(x))
    if not values:
        return {"count": 0}
    return {"count": len(values), "mean": statistics.mean(values),
            "p50": statistics.median(values), "p95": values[int(.95 * (len(values) - 1))],
            "min": values[0], "max": values[-1]}


def read_ppm(path: Path) -> tuple[int, int, bytes]:
    with path.open("rb") as stream:
        assert stream.readline() == b"P6\n"
        w, h = map(int, stream.readline().split())
        assert stream.readline() == b"255\n"
        pixels = stream.read()
    assert len(pixels) == w * h * 3
    return w, h, pixels


def inspect_image(path: Path) -> dict:
    w, h, p = read_ppm(path)
    bad = sum(p[(y*w+x)*3:(y*w+x)*3+3] != bytes((0, 255, 255))
              for y in range(20, 50) for x in range(20, 300))
    cross_pixels = {(x, y) for y in range(345, 375) for x in range(635, 645)}
    cross_pixels.update((x, y) for y in range(355, 365) for x in range(625, 655))
    cross_bad = sum(p[(y*w+x)*3:(y*w+x)*3+3] != bytes((255, 255, 255)) for x, y in cross_pixels)
    red = [i // 3 % w for i in range(0, len(p), 3)
           if p[i] > 200 and p[i+1] < 110 and p[i+2] < 70]
    assert red, f"{path}: moving object absent"
    return {"width": w, "height": h, "ui_checked_pixels": 280 * 30,
            "ui_bad_pixels": bad, "crosshair_checked_pixels": len(cross_pixels), "crosshair_bad_pixels": cross_bad,
            "red_centroid_x": statistics.mean(red),
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def presentmon_tool() -> Path:
    manifest = json.loads((ROOT / "framegen/presentmon-manifest.json").read_text(encoding="utf-8"))
    target = ROOT / manifest["installed_path"]
    if not target.exists():
        target.parent.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(manifest["url"], timeout=90) as response:
            target.write_bytes(response.read())
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    if digest != manifest["sha256"]:
        raise RuntimeError(f"PresentMon SHA256 mismatch: {digest}")
    return target


def run_mode(enabled: bool, frames: int, output: Path, collector: Path) -> dict:
    output.mkdir(parents=True, exist_ok=True)
    exe = ROOT / "build/framegen/Release/framegen_demo.exe"
    sources = ["src/framegen_demo.cpp", "shaders/framegen_scene.hlsl", "framegen/CMakeLists.txt",
               "build_framegen.ps1", "verify_framegen.py", "sdk_manifest.json", "framegen/presentmon-manifest.json"]
    provenance = {"source_sha256": {name: hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in sources},
                  "executable_sha256": hashlib.sha256(exe.read_bytes()).hexdigest(),
                  "presentmon_sha256": hashlib.sha256(collector.read_bytes()).hexdigest()}
    (output/"run-provenance.json").write_text(json.dumps(provenance, indent=2)+"\n", encoding="utf-8")
    with (output / "application.log").open("w", encoding="utf-8") as app_log, \
            (output / "presentmon.log").open("w", encoding="utf-8") as pm_log:
        app = subprocess.Popen([str(exe), "--fg", str(int(enabled)), "--frames", str(frames),
                                "--output", str(output)], cwd=ROOT, stdout=app_log, stderr=subprocess.STDOUT)
        # 按 PID 附着，不需要枚举另一用户的进程；Demo 在开始模拟前留 1 秒附着窗口。
        monitor = subprocess.Popen([str(collector), "--process_id", str(app.pid),
                                    "--output_file", str(output / "presentmon.csv"), "--qpc_time_ms",
                                    "--v2_metrics", "--no_track_gpu", "--no_track_input", "--timed", "12", "--terminate_after_timed",
                                    "--terminate_on_proc_exit", "--no_console_stats",
                                    "--session_name", f"CUDA_DX_F9_{app.pid}"],
                                   stdout=pm_log, stderr=subprocess.STDOUT,
                                   creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        rc = app.wait(timeout=60)
        pm_rc = monitor.wait(timeout=20)
    if rc:
        raise RuntimeError(f"F9 process failed ({rc}); see {output / 'application.log'}")
    if pm_rc:
        raise RuntimeError(f"PresentMon failed ({pm_rc}); see {output / 'presentmon.log'}")
    return analyze_mode(output)


def analyze_mode(output: Path) -> dict:
    runtime = json.loads((output / "runtime.json").read_text())
    real = read_csv(output / "real-frames.csv")
    composition = read_csv(output / "display-events.csv")
    pm = read_csv(output / "presentmon.csv")
    # 剔除前 30 个真实帧的 PSO/cache、窗口激活和节奏器启动影响；不修改原始 CSV。
    steady = [r for r in real if int(r["frame_id"]) >= 30]
    begin = float(steady[0]["input_sample_qpc_ms"])
    end = float(steady[-1]["present_end_qpc_ms"])
    pm_steady = [r for r in pm if begin <= float(r["CPUStartQPCTime"]) <= end]
    shown = [r for r in pm_steady if r.get("DisplayedTime", "NA") != "NA"]
    display_intervals = [float(r["DisplayedTime"]) for r in shown]
    display_intervals = [x for x in display_intervals if x > 0]
    assert len(display_intervals) > 50, "ETW 缺少足够有效显示记录；保留日志，不能把 callback 时间冒充显示节奏。"
    input_times = [float(r["input_sample_qpc_ms"]) for r in steady]
    metrics = {key: stats([float(r[key]) for r in steady])
               for key in ("scene_prepare_gpu_ms", "fg_gpu_ms", "input_to_cpu_submit_ms", "present_cpu_ms")}
    metrics["real_sample_interval_ms"] = stats([b-a for a, b in zip(input_times, input_times[1:])])
    metrics["real_sampling_fps"] = 1000 * (len(input_times)-1) / (input_times[-1]-input_times[0])
    metrics["os_displayed_interval_ms"] = stats(display_intervals)
    metrics["etw_displayed_fps"] = 1000 / statistics.mean(display_intervals) if display_intervals else None
    metrics["etw_present_records"] = len(pm_steady)
    metrics["etw_displayed_records"] = len(shown)
    metrics["etw_dropped_records"] = len(pm_steady)-len(shown)
    metrics["present_modes"] = sorted({r["PresentMode"] for r in pm_steady})
    # 这里是 PresentMon 按系统事件推算的 frame-start -> displayed，不是按键 -> 光子硬件测量。
    metrics["etw_frame_start_to_display_ms"] = stats([float(r["DisplayLatency"]) for r in shown
                                                     if r.get("DisplayLatency", "NA") != "NA"])
    dxgi = read_csv(output / "dxgi-display-observations.csv")
    dxgi_steady = [r for r in dxgi if begin <= float(r["cpu_observed_qpc_ms"]) <= end]
    assert len(dxgi_steady) > 50, "没有足够有效 DXGI 显示变化观测。"
    dxgi_times = [float(r["cpu_observed_qpc_ms"]) for r in dxgi_steady]
    dxgi_intervals = [b-a for a, b in zip(dxgi_times, dxgi_times[1:])]
    metrics["dxgi_observed_display_interval_ms"] = stats(dxgi_intervals)
    metrics["dxgi_observed_present_id_change_rate"] = 1000*(len(dxgi_times)-1)/(dxgi_times[-1]-dxgi_times[0])
    metrics["dxgi_observed_display_changes"] = len(dxgi_times)
    metrics["etw_valid_display_measurement"] = bool(display_intervals)
    metrics["dxgi_sync_intervals_ms"] = stats([float(b["sync_qpc_ms"])-float(a["sync_qpc_ms"])
                                              for a, b in zip(dxgi_steady, dxgi_steady[1:])])
    images = {name: inspect_image(output / f"{name}.ppm")
              for name in ("previous-real", "current-real")}
    if runtime["fg_enabled"]:
        images["generated"] = inspect_image(output / "generated.ppm")
        assert images["generated"]["sha256"] not in (images["current-real"]["sha256"], images["previous-real"]["sha256"]), "生成帧不是新的图像。"
        midpoint = .5 * (images["current-real"]["red_centroid_x"] + images["previous-real"]["red_centroid_x"])
        metrics["generated_centroid_midpoint_error_pixels"] = abs(images["generated"]["red_centroid_x"] - midpoint)
        assert metrics["generated_centroid_midpoint_error_pixels"] < 1, "生成方块没有落到前后两帧位置的中点附近。"
    assert all(im["ui_bad_pixels"] == 0 for im in images.values()), "后置 UI 的青色像素条发生变形。"
    assert all(im["crosshair_bad_pixels"] == 0 for im in images.values()), "后置准星发生变形。"
    assert runtime["real_frames"] == runtime["real_display_callbacks"]
    assert runtime["dxgi_last_present_count"] == len(composition)
    assert runtime["debug_errors"] == runtime["ffx_errors"] == runtime["callback_errors"] == 0
    assert runtime["generated_display_callbacks"] > 0 if runtime["fg_enabled"] else runtime["generated_display_callbacks"] == 0
    provenance_path = output / "run-provenance.json"
    provenance = json.loads(provenance_path.read_text()) if provenance_path.exists() else None
    return {"runtime": runtime, "metrics": metrics, "images": images, "run_provenance": provenance, "pass": True}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--analyze-only", action="store_true")
    parser.add_argument("--frames", type=int, default=240)
    args = parser.parse_args()
    base = ROOT / "results/f9"
    tool = presentmon_tool() if not args.analyze_only else None
    results = {}
    for enabled in (False, True):
        name = "on" if enabled else "off"
        results[name] = analyze_mode(base/name) if args.analyze_only else run_mode(enabled, args.frames, base/name, tool)
    summary = {"pass": all(mode["pass"] for mode in results.values()),
               "measurement_boundary": "Primary displayed cadence is independent PresentMon ETW DisplayedTime; DXGI present-ID polling is cross-check only (SDK proxy/VRR/polling semantics may differ). No optical sensor or end-to-end input-to-photon claim. GPU timings include D3D12 Debug layer.",
               "warmup_real_frames_excluded": 30, "modes": results}
    (base / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
    print(json.dumps({"pass": summary["pass"], "off_etw_displayed_fps": results["off"]["metrics"]["etw_displayed_fps"],
                      "on_etw_displayed_fps": results["on"]["metrics"]["etw_displayed_fps"],
                      "generated_frames": results["on"]["runtime"]["generated_display_callbacks"]}, indent=2))


if __name__ == "__main__":
    main()
