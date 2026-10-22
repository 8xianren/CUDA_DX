"""可微射线积分。所有采样、网络查询和合成都保留torch自动微分图。"""
import torch


def sample_rays(origins, directions, samples=48, jitter=False, max_distance=None):
    """射线与[-1,1]^3 slab求交；返回midpoints [R,S,3], t [R,S], delta [R,1]。"""
    # 平行射线不能直接0做除数。符号只影响不命中时的区间，显式inside判断补足平行情形。
    parallel = directions.abs() < 1e-9
    safe_direction = torch.where(parallel, torch.ones_like(directions), directions)
    t0, t1 = (-1 - origins) / safe_direction, (1 - origins) / safe_direction
    lo, hi = torch.minimum(t0, t1), torch.maximum(t0, t1)
    lo = torch.where(parallel, torch.full_like(lo, -1e9), lo)
    hi = torch.where(parallel, torch.full_like(hi, 1e9), hi)
    near = lo.max(-1).values.clamp_min(.1)
    far = hi.min(-1).values.clamp_max(10.0)
    if max_distance is not None:
        # 网格深度必须先从camera-Z转换成归一化射线距离，再截断积分上限。
        # 比较一张“期望深度图”无法正确解决雾中间插入网格的遮挡。
        far = torch.minimum(far, max_distance)
    parallel_outside = (parallel & (origins.abs() > 1)).any(-1)
    valid = (far > near) & ~parallel_outside
    length = torch.where(valid, far - near, torch.zeros_like(far))
    delta = length[:, None] / samples
    offsets = torch.rand((len(origins), samples), device=origins.device, dtype=origins.dtype) if jitter else .5
    t = near[:, None] + delta * (torch.arange(samples, device=origins.device) + offsets)
    return origins[:, None, :] + t[..., None] * directions[:, None, :], t, delta


def composite(sigma, rgb, t, delta):
    """按前到后计算alpha/T/weight。RGB是线性预乘结果，不预先加入背景。"""
    optical = sigma * delta
    # -expm1(-x)在x接近零时比1-exp(-x)稳定；避免小密度被舍入为零。
    alpha = -torch.expm1(-optical)
    # T_i = exp(-sum_{j<i} sigma_j delta_j)，exclusive scan用首个0和移位实现。
    prefix = torch.cat((torch.zeros_like(optical[:, :1]), optical.cumsum(-1)[:, :-1]), dim=-1)
    weights = torch.exp(-prefix) * alpha
    color = (weights[..., None] * rgb).sum(-2)
    opacity = weights.sum(-1)
    # 不透明度条件下的期望射线距离；这不是表面ZBuffer，合成限制在讲义/G10说明。
    distance = (weights * t).sum(-1) / opacity.clamp_min(1e-8)
    return torch.cat((color, opacity[:, None]), dim=-1), distance, weights


def render_rays(field, origins, directions, samples=48, jitter=False, max_distance=None):
    points, t, delta = sample_rays(origins, directions, samples, jitter, max_distance)
    expanded = directions[:, None, :].expand_as(points)
    sigma, rgb = field(points, expanded)
    rgba, distance, weights = composite(sigma, rgb, t, delta)
    return rgba, distance, weights


@torch.no_grad()
def render_image(field, camera, samples=64, device="cuda", chunk=2048, mesh_occlusion=False):
    origins, directions = camera.rays(device)
    rgba_chunks, depth_chunks = [], []
    forward = camera.basis(device)[-1]
    for start in range(0, len(origins), chunk):
        direction = directions[start:start + chunk]
        origin = origins[start:start + chunk]
        max_distance = None
        if mesh_occlusion:
            # G10固定网格：z=-.65上的窄矩形和z=1.5背景平面；这里只算同一几何的射线交点。
            # 导出的仍是截断后的预乘NeRF颜色，网格本身由D3D12画并执行Cvol+T*Cmesh。
            if abs(camera.eye[2] + 3) > 1e-6 or camera.eye[:2] != (0.0, 0.0):
                raise ValueError("G10 occlusion export currently requires fixed eye=(0,0,-3)")
            front_t = (-.65 - origin[:, 2]) / direction[:, 2]
            front_p = origin + front_t[:, None] * direction
            hit_front = (front_p[:, 0].abs() <= .18) & (front_p[:, 1].abs() <= .8)
            back_t = (1.5 - origin[:, 2]) / direction[:, 2]
            max_distance = torch.where(hit_front, front_t, back_t)
        rgba, distance, _ = render_rays(field, origin, direction, samples, max_distance=max_distance)
        depth = distance * (direction * forward).sum(-1)
        depth = torch.where(rgba[:, 3] >= 1e-4, depth, torch.full_like(depth, camera.far))
        rgba_chunks.append(rgba)
        depth_chunks.append(depth)
    return torch.cat(rgba_chunks).reshape(camera.height, camera.width, 4), torch.cat(depth_chunks).reshape(camera.height, camera.width)
