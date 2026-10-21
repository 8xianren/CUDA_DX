"""程序环境的独立数值验收；从任意工作目录运行 python audit_sky.py。

目标不是把一份公式在 CPU 上复制两遍再互相比较：
1. 天空参考用 Gauss-Legendre 半球积分；太阳参考用有限球冠照度解析式。
2. 待检估计器使用随机的 BSDF / 天空 NEE / 太阳 NEE 三个样本。
3. 额外制造“分项采样却除以二选一 PDF”的错误，必须被参考解检出。

需要 NumPy；默认 100 万组，固定种子，通常数秒。输出 JSON 明确记录源码哈希、
样本数、标准误与负对照。本脚本验证采样数学，不替代实际 DXR 遮挡、材质或显卡
浮点实现验证。光源参数从 shader 读取，不能在 shader 改参数后继续验收旧常量。
"""
import argparse
import hashlib
import json
import re
import time
from pathlib import Path

import numpy as np
from numpy.polynomial.legendre import leggauss


ROOT = Path(__file__).resolve().parent
SHADER = ROOT.parent.parent / 'path_tracing/dxr-path-tracer/sky_environment.hlsli'
INTEGRATOR = SHADER.with_name('path_integrator.hlsl')
PI = np.pi


def scalar(source, expression):
    match = re.search(expression, source)
    if match is None:
        raise ValueError('shader 结构改变，请同步审查参考模型：' + expression)
    return float(match.group(1))


def vector(source, expression):
    match = re.search(expression, source)
    if match is None:
        raise ValueError('shader 结构改变，请同步审查参考模型：' + expression)
    return np.array([float(part.strip()) for part in match.group(1).split(',')])


def parameters(source):
    # HLSL 常量首先舍入为 float32；独立积分再用 double 运算。这尤其影响很小的
    # 太阳角半径：1-cos(radius) 相减不能偷偷使用比 shader 更多的有效位。
    def f32(value):
        return np.asarray(value, dtype=np.float32).astype(np.float64)

    sun = vector(source, r'SkySunDirection\(\)\s*\{\s*return normalize\(float3\(([^)]*)\)\)')
    sun = f32(sun)
    sun /= np.linalg.norm(sun)
    return {
        'sun_direction': sun,
        'cos_radius': float(f32(scalar(source, r'SkySunCosRadius\s*=\s*([0-9.eE+-]+)'))),
        'sun_radiance': f32(vector(source, r'SkySunRadiance\s*=\s*float3\(([^)]*)\)')),
        'horizon': f32(vector(source, r'float3 horizon\s*=\s*float3\(([^)]*)\)')),
        'zenith': f32(vector(source, r'float3 zenith\s*=\s*float3\(([^)]*)\)')),
        'lower': f32(vector(source, r'float3 lower\s*=\s*float3\(([^)]*)\)')),
        'height_power': scalar(source, r'pow\(height,\s*([0-9.]+)\)'),
        'lower_scale': scalar(source, r'saturate\(-direction.y\s*\*\s*([0-9.]+)\)'),
        'halo_power': scalar(source, r'SkySunDirection\(\)\)\),\s*([0-9.]+)\)'),
        'halo_color': f32(vector(source, r'return color \+ float3\(([^)]*)\) \* halo')),
    }


def dome_radiance(direction, p):
    y = direction[:, 1]
    height = np.clip(y, 0, 1) ** p['height_power']
    color = p['horizon'] + height[:, None] * (p['zenith'] - p['horizon'])
    below = y < 0
    color[below] = (p['horizon'] + np.clip(-y[below] * p['lower_scale'], 0, 1)[:, None]
                    * (p['lower'] - p['horizon']))
    halo = np.clip(direction @ p['sun_direction'], 0, 1) ** p['halo_power']
    return color + halo[:, None] * p['halo_color']


def power(a, b):
    return a * a / (a * a + b * b)


def reference_radiance(p, albedo):
    # 水平、无遮挡的 Lambert 表面：Lo = albedo/pi * ∫ Ly cosθ dω。
    # y=cosθ，dω=dφdy。因此无需使用待检的随机采样映射，也无需 MIS PDF。
    # y>0 上的分数次幂在原点导数较陡；384 个 Gauss 节点仍足够稳定。
    nodes, weights = leggauss(384)
    y = (nodes + 1) / 2
    weights /= 2
    phi = (np.arange(1024) + .5) * 2 * PI / 1024
    y, phi = np.meshgrid(y, phi, indexing='ij')
    radius = np.sqrt(1 - y * y)
    directions = np.stack([radius * np.cos(phi), y, radius * np.sin(phi)], axis=-1)
    sky = dome_radiance(directions.reshape(-1, 3), p).reshape(384, 1024, 3)
    dome = (sky * y[:, :, None] * weights[:, None, None]).sum(axis=(0, 1))
    dome *= (2 * PI / 1024) * albedo / PI
    # 对完整可见的太阳球冠，∫cap w dω = π sin²(radius) * sunDirection。
    # 将它与表面法线点乘，并乘 albedo/pi，即得到太阳的解析出射辐亮度。
    assert p['sun_direction'][1] > np.sqrt(1 - p['cos_radius'] ** 2), '太阳盘必须整体位于地平线上'
    sun = p['sun_radiance'] * (1 - p['cos_radius'] ** 2) * p['sun_direction'][1] * albedo
    return dome, sun


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--samples', type=int, default=1_000_000)
    parser.add_argument('--output', type=Path, default=ROOT / 'results/visual/sky-numerical.json')
    args = parser.parse_args()
    if args.samples < 100_000:
        parser.error('至少 100000 个样本，防止把很宽的置信区间当成有效验收')
    start = time.perf_counter()
    source = SHADER.read_text(encoding='utf-8-sig')
    p = parameters(source)
    albedo = .75
    seed = 441
    count = args.samples
    reference_dome, reference_sun = reference_radiance(p, albedo)
    reference = reference_dome + reference_sun
    omega = 2 * PI * (1 - p['cos_radius'])
    pdf_dome, pdf_sun = 1 / (4 * PI), 1 / omega

    # 三条独立样本使用六个维度；同一 BSDF 样本可以估计两份不同的辐亮度积分。
    # 每份积分只有 BSDF 与其自己的 NEE 竞争，太阳 PDF 不参与低频天空的权重。
    random = np.random.default_rng(seed).random((count, 6))
    phi = 2 * PI * random[:, 1]
    y = np.sqrt(random[:, 0])
    radius = np.sqrt(1 - y * y)
    bsdf_direction = np.stack([radius * np.cos(phi), y, radius * np.sin(phi)], axis=1)
    pdf_bsdf = y / PI
    in_sun = bsdf_direction @ p['sun_direction'] >= p['cos_radius']
    sun_competitor = np.where(in_sun, pdf_sun, 0)
    bsdf_sky = dome_radiance(bsdf_direction, p)
    bsdf_sun = in_sun[:, None] * p['sun_radiance']
    estimate = albedo * (bsdf_sky * power(pdf_bsdf, pdf_dome)[:, None]
                         + bsdf_sun * power(pdf_bsdf, sun_competitor)[:, None])
    # 负对照：每个顶点已经各采一份 NEE，却误把 PDF 乘“选择这盏灯的 1/2”。
    # 若真的随机二选一，这个 1/2 才属于联合 PDF；本算法没有这一步选择。
    wrong = albedo * (bsdf_sky * power(pdf_bsdf, .5 * pdf_dome)[:, None]
                      + bsdf_sun * power(pdf_bsdf, .5 * sun_competitor)[:, None])

    y = 1 - 2 * random[:, 2]
    radius = np.sqrt(1 - y * y)
    phi = 2 * PI * random[:, 3]
    dome_direction = np.stack([radius * np.cos(phi), y, radius * np.sin(phi)], axis=1)
    cosine = np.maximum(y, 0)
    pdf_bsdf = cosine / PI
    sky = dome_radiance(dome_direction, p)
    estimate += albedo / PI * sky * (cosine / pdf_dome * power(pdf_dome, pdf_bsdf))[:, None]
    wrong += albedo / PI * sky * (cosine / (.5 * pdf_dome) * power(.5 * pdf_dome, pdf_bsdf))[:, None]

    tangent = np.cross([0, 1, 0], p['sun_direction'])
    tangent /= np.linalg.norm(tangent)
    bitangent = np.cross(p['sun_direction'], tangent)
    cosine = 1 - (1 - p['cos_radius']) * random[:, 4]
    sine = np.sqrt(1 - cosine * cosine)
    phi = 2 * PI * random[:, 5]
    sun_direction = (cosine[:, None] * p['sun_direction'] + sine[:, None]
                     * (np.cos(phi)[:, None] * tangent + np.sin(phi)[:, None] * bitangent))
    cosine_surface = sun_direction[:, 1]
    pdf_bsdf = cosine_surface / PI
    estimate += albedo / PI * p['sun_radiance'] * (cosine_surface / pdf_sun * power(pdf_sun, pdf_bsdf))[:, None]
    wrong += albedo / PI * p['sun_radiance'] * (cosine_surface / (.5 * pdf_sun) * power(.5 * pdf_sun, pdf_bsdf))[:, None]

    mean = estimate.mean(axis=0)
    stderr = estimate.std(axis=0, ddof=1) / np.sqrt(count)
    z_score = (mean - reference) / stderr
    wrong_mean = wrong.mean(axis=0)
    wrong_stderr = wrong.std(axis=0, ddof=1) / np.sqrt(count)
    wrong_z = (wrong_mean - reference) / wrong_stderr

    # PDF 归一化与采样分布相互独立检查：前者积分密度，后者检查输出方向矩。
    # 球面每个分量 E[w]=0，E[w²]=1/3；球冠 E[cosθ]=(1+c)/2。
    sphere_mean = dome_direction.mean(axis=0)
    sphere_second = (dome_direction ** 2).mean(axis=0)
    cone_mean = float((sun_direction @ p['sun_direction']).mean())
    cone_expected = (1 + p['cos_radius']) / 2
    cone_stderr = (1 - p['cos_radius']) / np.sqrt(12 * count)
    checks = {
        'dome_pdf_integral_one': abs(pdf_dome * 4 * PI - 1) < 1e-14,
        'sun_pdf_integral_one': abs(pdf_sun * omega - 1) < 1e-14,
        'sphere_first_moment': bool(np.max(np.abs(sphere_mean)) < 5 / np.sqrt(3 * count)),
        'sphere_second_moment': bool(np.max(np.abs(sphere_second - 1 / 3)) < 5 * np.sqrt(4 / (45 * count))),
        'cone_cosine_moment': bool(abs(cone_mean - cone_expected) < 5 * cone_stderr),
        'unit_directions': bool(np.max(np.abs(np.linalg.norm(sun_direction, axis=1) - 1)) < 1e-12),
        'samples_in_cone': bool(np.min(sun_direction @ p['sun_direction']) >= p['cos_radius'] - 1e-14),
        'mis_matches_independent_reference': bool(np.max(np.abs(z_score)) < 5),
        'wrong_mixture_pdf_detected': bool(np.min(np.abs(wrong_z)) > 20),
    }
    report = {
        'pass': all(checks.values()),
        'scope': 'CPU double采样数学验证；不代替GPU着色、遮挡、材质或实际图像验收',
        'samples': count, 'seed': seed, 'albedo': albedo,
        'shader_sha256': hashlib.sha256(SHADER.read_bytes()).hexdigest(),
        'integrator_sha256': hashlib.sha256(INTEGRATOR.read_bytes()).hexdigest(),
        'parameters': {k: v.tolist() if isinstance(v, np.ndarray) else v for k, v in p.items()},
        'pdf': {'dome_sr_inverse': pdf_dome, 'sun_sr_inverse': pdf_sun, 'sun_solid_angle_sr': omega,
                'dome_integral': pdf_dome * 4 * PI, 'sun_integral': pdf_sun * omega},
        'distribution': {'sphere_mean': sphere_mean.tolist(), 'sphere_second_moment': sphere_second.tolist(),
                         'cone_mean_cosine': cone_mean, 'cone_expected_cosine': cone_expected,
                         'cone_mean_standard_error': cone_stderr},
        'reference': {'method': '384x1024 Gauss-Legendre天空积分 + 有限太阳球冠解析照度',
                      'dome_rgb': reference_dome.tolist(), 'sun_rgb': reference_sun.tolist(), 'total_rgb': reference.tolist()},
        'mis': {'rgb': mean.tolist(), 'standard_error': stderr.tolist(), 'z_score': z_score.tolist()},
        'negative_control': {'fault': '两份NEE每次都采样，却错误地把各自PDF乘0.5',
                             'rgb': wrong_mean.tolist(), 'z_score': wrong_z.tolist()},
        'checks': checks, 'elapsed_seconds': time.perf_counter() - start,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'pass': report['pass'], 'mis_z_score': z_score.tolist(),
                      'negative_control_z_score': wrong_z.tolist(), 'output': str(args.output),
                      'seconds': report['elapsed_seconds']}, ensure_ascii=False))
    if not report['pass']:
        raise SystemExit('FAIL: ' + ', '.join(name for name, passed in checks.items() if not passed))


if __name__ == '__main__':
    main()
