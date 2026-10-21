"""启动入口验收：在隔离副本中运行，不覆盖主课程的交互/验收轨迹。只需 Python 标准库。"""
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "results" / "startup"
OUT.mkdir(parents=True, exist_ok=True)
# 与 build/Release 保持相同深度，真实使用交付配置中的相对资源路径。
SMOKE = ROOT / "build" / "startup-smoke"
SMOKE.mkdir(parents=True, exist_ok=True)
for name in ("character_demo.exe", "cudart64_13.dll", "character_demo.json"):
    shutil.copy2(ROOT / "build" / "Release" / name, SMOKE / name)
config = json.loads((SMOKE / "character_demo.json").read_text(encoding="utf-8-sig"))
config["output"] = "../../results/startup/no-args"
(SMOKE / "character_demo.json").write_text(json.dumps(config, indent=2), encoding="utf-8")
exe = SMOKE / "character_demo.exe"
environment = dict(os.environ)
cwd = Path(os.environ["SystemRoot"])
environment["PATH"] = str(cwd / "System32")

user32 = ctypes.WinDLL("user32", use_last_error=True)
callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
user32.EnumWindows.argtypes = [callback_type, wintypes.LPARAM]
user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
user32.IsWindowVisible.argtypes = [wintypes.HWND]
user32.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]

def window_for(pid):
    handles = []
    @callback_type
    def visit(hwnd, _):
        owner = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        name = ctypes.create_unicode_buffer(256)
        user32.GetClassNameW(hwnd, name, len(name))
        # 排除失败弹窗；只操作这个测试子进程自己的实际渲染窗口。
        if owner.value == pid and user32.IsWindowVisible(hwnd) and name.value != "#32770":
            handles.append(hwnd)
        return True
    user32.EnumWindows(visit, 0)
    return handles[0] if handles else None

def run_case(name, arguments, expected=0, contains=None):
    result = subprocess.run([str(exe), *arguments], cwd=cwd, env=environment,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
    (OUT / f"{name}.txt").write_bytes(result.stdout)
    text = result.stdout.decode("utf-8", errors="replace")
    assert result.returncode == expected, (name, result.returncode, text[-1000:])
    if contains:
        assert contains in text, (name, text[-1000:])

# 无参数与双击走完全相同的入口；从 Windows 目录启动，PATH 中没有 CUDA Toolkit。
with (OUT / "no-args.txt").open("wb") as log:
    process = subprocess.Popen([str(exe)], cwd=cwd, env=environment, stdout=log, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 30
        window = None
        while process.poll() is None and time.monotonic() < deadline:
            window = window_for(process.pid)
            if window:
                break
            time.sleep(0.05)
        assert window, "No visible render window from no-argument startup"
        time.sleep(1)
        assert user32.PostMessageW(window, 0x0010, 0, 0), "WM_CLOSE failed"
        assert process.wait(timeout=30) == 0, "No-argument startup did not close normally"
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
no_args_text = (OUT / "no-args.txt").read_text(encoding="utf-8", errors="replace")
match = re.search(r"Demo closed normally; frames=(\d+)", no_args_text)
assert match and int(match[1]) > 0, no_args_text[-1000:]

# 默认配置的验证模式覆盖 resize/minimize/focus，且保留旧脚本的参数兼容性。
run_case("config-verification", ["--verify-frames", "24"], contains="debug_warning_error=0")
run_case("legacy-arguments", [str(ROOT / "assets/runtime"), str(ROOT / "build/shaders"),
    str(ROOT / "../../path_tracing/dxr-path-tracer/results/pt08/energy-lut.bin"),
    str(OUT / "legacy"), "24"], contains="Demo closed normally; frames=24")
bad = SMOKE / "invalid.json"
bad.write_text('{"assets": ', encoding="utf-8")
run_case("malformed-json", ["--config", str(bad)], 1, "Invalid JSON")
wrong = dict(config, assets="missing-assets")
bad.write_text(json.dumps(wrong), encoding="utf-8")
run_case("missing-assets", ["--config", str(bad)], 1, "Required runtime file is missing")
wrong = dict(config, render={"width": 0})
bad.write_text(json.dumps(wrong), encoding="utf-8")
run_case("invalid-size", ["--config", str(bad)], 1, "must be an integer in [16, 4096]")
run_case("missing-config", ["--config", str(SMOKE / "absent.json")], 1, "Cannot open startup config")
summary = {"pass": True, "no_argument_frames": int(match[1]), "cases": 7,
           "working_directory": str(cwd), "path": environment["PATH"],
           "legacy_arguments": True, "config_debug_errors": 0}
(OUT / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
print(json.dumps(summary, indent=2))
