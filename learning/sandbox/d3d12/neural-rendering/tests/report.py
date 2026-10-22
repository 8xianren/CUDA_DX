"""G课程收尾：读取实际验收证据，拒绝缺报告/失败；不生成虚构测量值。"""
from pathlib import Path
from collections import defaultdict
import csv
import hashlib
import json
import statistics

ROOT = Path(__file__).resolve().parents[1]
RESULT = ROOT / "results"


def read(name):
    return json.loads((RESULT / name).read_text(encoding="utf-8"))


def main():
    checks = []
    def require(name, condition):
        checks.append({"name": name, "pass": bool(condition)})
        if not condition:
            raise RuntimeError("course evidence failed: " + name)

    g1, g2 = read("g1/summary.json"), read("g2/core_validation.json")
    require("G1 weight partition and convergence", g1["status"] == "PASS" and g1["partition_error"] < 1e-12 and g1["monotonic_image_convergence"])
    require("G2 CPU GPU repeat and skip", g2["status"] == "PASS" and g2["cpu_gpu_max_abs"] < g2["tolerance"] and g2["repeat_max_abs"] == 0 and g2["skip_max_abs"] == 0)
    with (RESULT / "g3/quality_performance.csv").open(encoding="utf-8") as f:
        samples = list(csv.DictReader(f))
    require("G3 six measured step/skip variants", len(samples) == 6 and len({r["step"] for r in samples}) == 3 and all(float(r["gpu_median_ms"]) > 0 for r in samples))
    train, infer = read("g4/training.json"), read("g5/benchmark.json")
    require("G4 numerical/autograd contracts", read("g4/contracts.json")["checks"] == 14 and read("g4/contracts.json")["status"] == "PASS")
    require("G4 actual overfit on sm120", train["status"] == "PASS" and train["capability"] == [12, 0] and train["first_gradient_l2"] > 0)
    require("G5 measured inference and bake error", infer["status"] == "PASS" and infer["direct_mlp"]["repeats"] >= 10 and infer["baked_vs_direct"]["rgb_mse"] < 1e-4)
    require("G5 actual two-extent exports", read("g5/export-validation.json")["status"] == "PASS" and read("g5/export-validation.json")["checks"] == 42)
    projection, bins, splat = read("g6/projection.json"), read("g7/binning.json"), read("g8/splat.json")
    require("G6 projection and adversarial inputs", projection["known_analytic_cases"] >= 4 and projection["projection_max_abs_error"] < 1e-4 and projection["bounding_rectangles_equal"])
    require("G7 reference membership stable sort", bins["cpu_tile_membership_and_order_equal"] and bins["shuffle_keys_ids_equal"] and bins["gaussians"] == 100000)
    require("G8 CPU image and shuffle invariance", splat["rgba_max_abs_error"] < 1e-5 and splat["shuffle_bitwise_identical"] and splat["checks_passed"] >= 7153)
    for stage, names in (("g2", ("sanitizer_memcheck.log", "sanitizer_synccheck.log")),
                         ("g8", ("memcheck.log", "synccheck.log")),
                         ("g10", ("memcheck.log", "synccheck.log"))):
        for name in names:
            log = (RESULT / stage / name).read_text(encoding="utf-8", errors="replace")
            require(f"{stage} {name}", "ERROR SUMMARY: 0 errors" in log and "ERROR SUMMARY: 1" not in log)
    imported, failures = read("g9/import.json"), read("g9/import-tests.json")
    require("G9 full trained scene fields", imported["pass"] and imported["count"] == 741883 and imported["degree"] == 3 and imported["stride"] == 244)
    require("G9 malformed input and download tests", failures["status"] == "PASS" and failures["tests"] >= 21 and failures["failures"] == failures["errors"] == 0)
    paired = read("g9/reference-preview/report.json")
    require("G9 paired camera rendered", read("g9/reference-preview/render.json")["status"] == "PASS" and read("g9/reference-preview/render.json")["full_gaussian_count"] == 667872)
    integration = read("g10/validation/summary.json")
    for name in ("validation", "reference-asset"):
        report = read(f"g10/{name}/summary.json")
        require(f"G10 {name} four passes/resize/debug", report["pass"] and report["frames"] == 8 and report["oracle_cases"] == 8 and report["debug_messages"] == 0 and report["validation_enabled"] and report["nerf_enabled"] and report["resize_generations"] == 2)
        require(f"G10 {name} independent depth/volume oracle", report["volume_oracle_cases"] == 2 and report["ray_distance_max_error"] < 3e-6 and report["volume_occlusion_max_error"] < 5e-4)
    performance = read("g10/performance/summary.json")
    require("G10 repeated timing without validation", performance["pass"] and not performance["validation_enabled"] and performance["frames"] == 96)
    groups = defaultdict(list)
    with (RESULT / "g10/performance/frames.csv").open(encoding="utf-8") as f:
        for row in csv.DictReader(f):
            groups[(row["mode"], int(row["width"]), int(row["height"]))].append(row)
    table = []
    for (mode, width, height), rows in groups.items():
        measured = rows[2:]
        require(f"G10 {mode} {width} timing sample count", len(measured) == 10)
        times = [float(r["cuda_pass_ms"]) for r in measured]
        table.append({"mode": mode, "resolution": [width, height], "warmups": 2, "measured": 10,
                      "median_cuda_event_ms": statistics.median(times), "min_ms": min(times), "max_ms": max(times),
                      "representation_bytes": int(measured[0]["representation_bytes"]),
                      "shared_allocation_bytes": int(measured[0]["shared_allocation_bytes"])})
    out = RESULT / "verification"; out.mkdir(parents=True, exist_ok=True)
    (RESULT / "g10/performance/report.json").write_text(json.dumps({"samples": table,
        "limits": ["stationary matched camera, different scene representations; no cross-scene quality ranking",
                   "event interval includes host launch gaps; excludes D3D mesh/display/present",
                   "nerf_cached measures upload only; actual inference in g5/benchmark.json",
                   "representation bytes excludes runtime scratch; shared bytes is only two exported textures"]}, indent=2), encoding="utf-8")
    sources = {}
    for directory in ("src", "shaders", "python", "tests"):
        for path in sorted((ROOT / directory).rglob("*")):
            if path.is_file() and path.suffix in (".cpp", ".cu", ".cuh", ".h", ".hlsl", ".py", ".ps1"):
                sources[path.relative_to(ROOT).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    for name in ("CMakeLists.txt", "build.ps1", "verify.ps1"):
        sources[name] = hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
    report = {"status": "PASS_WITH_USER_APPROVED_COUNTER_WAIVER", "date": "2026-10-22",
              "checks": len(checks), "details": checks,
              "hardware_counter_analysis": {"G3": "WAIVED_BY_USER", "G8": "WAIVED_BY_USER", "reason": "ERR_NVGPUCTRPERM; user explicitly approved skip on 2026-10-22"},
              "hardware": {"gpu": "NVIDIA GeForce RTX 5070", "compute_capability": "sm_120", "cuda_toolkit": "13.3", "driver": "610.88"},
              "integration": integration, "source_sha256": sources}
    (out / "summary.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps({"status": report["status"], "checks": len(checks), "sources": len(sources)}, indent=2))


if __name__ == "__main__":
    main()
