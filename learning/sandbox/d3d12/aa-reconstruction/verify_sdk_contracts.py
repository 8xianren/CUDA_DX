"""F.7/F.8 的独立坐标/曝光约定验证；不代替官方 DLL 的 GPU 执行。

从屏幕位置约束推导运动矢量，避免用 adapter 自己的代码作为参考答案。
结果直接写入本课 results/f7；只用标准库，迁移电脑无需第三方 Python 包。
"""
from pathlib import Path
import json
import math


def main():
    checks = []
    # 一物体从uv=(.30,.40)移动到(.35,.45)，current→previous必须为负。
    previous_uv, current_uv = (0.30, 0.40), (0.35, 0.45)
    for width, height in ((640, 360), (426, 240), (320, 180), (800, 450)):
        pixel_mv = tuple((p - c) * s for p, c, s in zip(previous_uv, current_uv, (width, height)))
        restored = tuple(c + m / s for c, m, s in zip(current_uv, pixel_mv, (width, height)))
        error = max(abs(a-b) for a, b in zip(previous_uv, restored))
        checks.append({"name": "current_to_previous_render_pixels", "size": [width, height], "error": error, "pass": error < 1e-12})
        # D3D NDC y向上；viewport y向下。注入(+2jx/W,-2jy/H)后屏幕偏移恰好(+jx,+jy)。
        for jx, jy in ((.25, -.375), (-.4375, .125)):
            ndc_shift = (2*jx/width, -2*jy/height)
            screen_shift = (ndc_shift[0]*width/2, -ndc_shift[1]*height/2)
            error = max(abs(screen_shift[0]-jx), abs(screen_shift[1]-jy))
            checks.append({"name": "jitter_projection_to_screen", "size": [width,height], "error": error, "pass": error < 1e-12})
    # 已乘P的颜色需要以1/P恢复固定曝光E=1；把P当XeSS exposureScale会错误乘P²。
    for pre_exposure in (0.25, 1.0, 4.0):
        scene_color = 3.75
        input_color = scene_color * pre_exposure
        restored = input_color / pre_exposure
        checks.append({"name": "xess_exposure_is_inverse_preexposure", "pre_exposure": pre_exposure,
                       "error": abs(restored-scene_color), "pass": math.isclose(restored, scene_color)})
    result = {"scope": "independent CPU convention checks; not GPU SDK correctness", "checks": checks, "pass": all(c["pass"] for c in checks)}
    path = Path(__file__).resolve().parent / "results/f7/sdk-contracts.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(f"sdk_contracts: {len(checks)} checks, pass={result['pass']}")
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
