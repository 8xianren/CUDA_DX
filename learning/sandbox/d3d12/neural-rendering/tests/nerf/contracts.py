"""独立数值验收：相机约定、解析吸收、梯度有限差分、透明体网格截断。"""
from pathlib import Path
import json
import sys
import torch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "python" / "nerf"))
from camera import Camera
from rendering import composite, sample_rays, render_image


def main():
    checks = []
    def check(name, value, error=None):
        checks.append({"name": name, "pass": bool(value), "error": error})
        if not value:
            raise AssertionError(name)
    camera = Camera(5, 5)
    origins, rays = camera.rays(dtype=torch.float64)
    check("center_ray_forward", torch.allclose(rays[12], torch.tensor([0., 0., 1.], dtype=torch.float64)))
    check("top_left_right_up_sign", rays[0, 0] < 0 and rays[0, 1] > 0 and rays[0, 2] > 0)
    check("all_rays_normalized", torch.allclose(rays.norm(dim=-1), torch.ones(25, dtype=torch.float64)))
    # 从同一物理相机出发：OpenGL的backward轴=-forward；COLMAP的down轴=-up。
    eye, right, up, forward = camera.basis(dtype=torch.float64)
    _, _, cx, cy = camera.intrinsics()
    fx, fy, _, _ = camera.intrinsics()
    for pixel in (0, 12, 24):
        y, x = divmod(pixel, camera.width)
        local = torch.tensor([(x + .5 - cx) / fx, -(y + .5 - cy) / fy, 1.], dtype=torch.float64)
        gl_direction = torch.stack((right, up, -forward), dim=1) @ (local * torch.tensor([1., 1., -1.]))
        cv_direction = torch.stack((right, -up, forward), dim=1) @ (local * torch.tensor([1., -1., 1.]))
        check(f"OpenGL_same_world_ray_{pixel}", torch.allclose(torch.nn.functional.normalize(gl_direction, dim=0), rays[pixel]))
        check(f"COLMAP_same_world_ray_{pixel}", torch.allclose(torch.nn.functional.normalize(cv_direction, dim=0), rays[pixel]))
    sigma = torch.tensor([[.4, .4, .4, .4]], dtype=torch.float64, requires_grad=True)
    color = torch.tensor([[[.2, .5, .8]] * 4], dtype=torch.float64)
    t = torch.tensor([[.25, .75, 1.25, 1.75]], dtype=torch.float64)
    delta = torch.tensor([[.5]], dtype=torch.float64)
    rgba, _, weights = composite(sigma, color, t, delta)
    expected_alpha = 1 - torch.exp(torch.tensor(-.8, dtype=torch.float64))
    check("homogeneous_closed_form", torch.allclose(rgba[0, 3], expected_alpha, atol=1e-12))
    check("weights_positive_sum_bounded", (weights >= 0).all() and weights.sum() <= 1)
    rgba[0, 0].backward()
    analytic_gradient = sigma.grad[0, 2].item()
    epsilon = 1e-5
    perturb = torch.zeros_like(sigma)
    perturb[0, 2] = epsilon
    plus = composite(sigma.detach() + perturb, color, t, delta)[0][0, 0]
    minus = composite(sigma.detach() - perturb, color, t, delta)[0][0, 0]
    finite = ((plus - minus) / (2 * epsilon)).item()
    check("backprop_matches_central_difference", abs(finite - analytic_gradient) < 1e-9, abs(finite - analytic_gradient))
    parallel_origin = torch.tensor([[2., 0., -3.]], dtype=torch.float64)
    parallel_direction = torch.tensor([[0., 0., 1.]], dtype=torch.float64)
    _, _, length = sample_rays(parallel_origin, parallel_direction)
    check("parallel_outside_misses_aabb", length.item() == 0)
    class ConstantField:
        def __call__(self, p, d):
            return torch.ones_like(p[..., 0]), torch.ones_like(p) * .5
    # 中心射线的盒入口t=2，前景矩形t=2.35，透明体只积分长度.35。
    clipped, _ = render_image(ConstantField(), camera, device="cpu", mesh_occlusion=True)
    check("mesh_truncates_volume_integral", abs(clipped[2, 2, 3].item() - (1 - torch.exp(torch.tensor(-.35)).item())) < 1e-6)
    result = {"status": "PASS", "checks": len(checks), "details": checks}
    output = ROOT / "results" / "g4" / "contracts.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
