"""G.4 相机：显式区分本课 +Z 前向、OpenGL -Z 前向和 COLMAP +Y 向下。"""
from dataclasses import dataclass, asdict
import math
import torch


@dataclass
class Camera:
    width: int = 640
    height: int = 360
    eye: tuple = (0.0, 0.0, -3.0)
    target: tuple = (0.0, 0.0, 0.0)
    vfov_degrees: float = 50.0
    near: float = 0.1
    far: float = 10.0

    def intrinsics(self):
        # 方形像素要求 fx=fy；横向视场由宽高比自然决定，不能各自固定 FOV。
        focal = self.height / (2.0 * math.tan(math.radians(self.vfov_degrees / 2)))
        return focal, focal, self.width / 2.0, self.height / 2.0

    def basis(self, device="cpu", dtype=torch.float32):
        eye = torch.tensor(self.eye, device=device, dtype=dtype)
        forward = torch.tensor(self.target, device=device, dtype=dtype) - eye
        forward = torch.nn.functional.normalize(forward, dim=0)
        up_hint = torch.tensor([0.0, 1.0, 0.0], device=device, dtype=dtype)
        # 本课采用相机 +X 右、+Y 上、+Z 前。默认眼睛位于 -Z；因此 right=up×forward。
        # 这组相机基是左手图形约定；OpenGL 的第三轴需单独取反。
        right = torch.nn.functional.normalize(torch.linalg.cross(up_hint, forward), dim=0)
        up = torch.linalg.cross(forward, right)
        return eye, right, up, forward

    def rays(self, device="cpu", dtype=torch.float32):
        """返回 origins/directions: [H*W,3]，行优先，单位方向，距离 t 为世界长度。"""
        fx, fy, cx, cy = self.intrinsics()
        y, x = torch.meshgrid(torch.arange(self.height, device=device, dtype=dtype),
                              torch.arange(self.width, device=device, dtype=dtype), indexing="ij")
        eye, right, up, forward = self.basis(device, dtype)
        directions = ((x[..., None] + .5 - cx) / fx * right
                      - (y[..., None] + .5 - cy) / fy * up + forward)
        directions = torch.nn.functional.normalize(directions.reshape(-1, 3), dim=-1)
        return eye.expand_as(directions), directions

    def metadata(self):
        data = asdict(self)
        fx, fy, cx, cy = self.intrinsics()
        eye, right, up, forward = self.basis()
        data.update(fx=fx, fy=fy, cx=cx, cy=cy, pixel_center="x+0.5,y+0.5",
                    image_origin="top-left", forward=forward.tolist(), right=right.tolist(),
                    up=up.tolist(), camera_axes="+X right,+Y up,+Z forward",
                    depth="conditional expected camera +Z; far when alpha<1e-4")
        return data
