"""把本课真实 CSV 结果绘成可随仓库保存的 SVG；不重写测量数据。"""
from pathlib import Path
import csv
import json

ROOT = Path(__file__).resolve().parents[2] / "results"


def rows(path):
    with path.open(encoding="utf-8", newline="") as stream:
        return list(csv.DictReader(stream))


def main():
    samples = rows(ROOT / "g3/quality_performance.csv")
    convergence = rows(ROOT / "g1/convergence.csv")
    log_path = ROOT / "g3/ncu_basic.csv"
    log = log_path.read_text(encoding="utf-8-sig", errors="replace") if log_path.exists() else ""
    permission_blocked = "ERR_NVGPUCTRPERM" in log
    counters_collected = '"Metric Name"' in log and "==ERROR==" not in log
    width, height = 1040, 480
    items = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
             '<rect width="1040" height="480" fill="#f8fafc"/>',
             '<g font-family="Segoe UI,Microsoft YaHei,sans-serif" fill="#172033">',
             '<text x="40" y="36" font-size="23">G.1–G.3: measured volume integration</text>',
             '<text x="40" y="62" font-size="14">RTX 5070 · 640×360 · 128³ density · 40 timed frames / variant</text>',
             '<text x="40" y="110" font-size="17">Render-only CUDA event median (ms)</text>']
    max_time = max(float(r["gpu_median_ms"]) for r in samples)
    for i, row in enumerate(samples):
        y = 138 + i * 41
        skip = row["skip"] == "1"
        color = "#0f766e" if skip else "#4f46e5"
        step = round(1 / float(row["step"]))
        value = float(row["gpu_median_ms"])
        bar_width = value / max_time * 280
        items.extend([f'<text x="40" y="{y+18}" font-size="14">1/{step}, skip={int(skip)}</text>',
                      f'<rect x="178" y="{y}" width="{bar_width:.2f}" height="25" rx="3" fill="{color}"/>',
                      f'<text x="{188+bar_width:.2f}" y="{y+18}" font-size="13">{value:.5f}</text>'])
    items.append('<text x="565" y="110" font-size="17">G.1 analytic CPU convergence (RGBA RMSE)</text>')
    for i, row in enumerate(convergence):
        y = 153 + i * 50
        step = round(1 / float(row["step"]))
        rmse = float(row["rgba_rmse_vs_1_over_1024"])
        items.append(f'<text x="580" y="{y}" font-size="16">step 1/{step:3d} → {rmse:.7f}</text>')
    profiler_label = "ERR_NVGPUCTRPERM" if permission_blocked else ("collected; inspect ncu_basic.csv" if counters_collected else "unavailable")
    items.extend([f'<text x="565" y="365" font-size="14">NCU hardware counters: {profiler_label}</text>',
                  '<text x="565" y="390" font-size="14">Interpret counters before a bottleneck claim.</text>',
                  '<text x="40" y="445" font-size="14">Fewer texture samples do not guarantee lower GPU time: coarse-step skip is slower.</text>',
                  '</g></svg>'])
    (ROOT / "g3/quality_performance.svg").write_text("\n".join(items), encoding="utf-8")
    # 把工具失败保留为结构化未完成项，不能把“工具已运行”误写成“指标已获得”。
    profiler = {
        "status": "COUNTERS_COLLECTED" if counters_collected else "WAIVED_BY_USER", "tool": "Nsight Compute 2026.2.0",
        "error": "ERR_NVGPUCTRPERM" if permission_blocked else None, "attempt_log": "ncu_basic.csv",
        "hardware_counters_collected": counters_collected,
        "bottleneck_attribution": "not established",
        "measured_without_hardware_counters": ["CUDA event duration", "per-pixel sample count", "early termination ratio"],
        "system_settings_changed": False,
        "user_waiver": "2026-10-22: skip hardware-counter analysis this round; retain measured timing and explicitly mark omission",
    }
    (ROOT / "g3/profiler_status.json").write_text(json.dumps(profiler, indent=2) + "\n", encoding="utf-8")
    print("volume SVG and permission status written")


if __name__ == "__main__":
    main()
