"""G.4/G.5 场表示：解析教师、位置编码 MLP、从已训练 MLP 烘焙的 13 通道网格。"""
import math
import torch
from torch import nn
from torch.nn import functional as F


class AnalyticField:
    """只负责生成训练/验收图像；训练循环不能访问其 sigma 或隐含几何标签。"""
    def __call__(self, position, direction):
        first = position - position.new_tensor([-.23, -.05, 0.0])
        second = position - position.new_tensor([.34, .20, .14])
        # 两团连续的彩色雾。密度按世界长度的倒数计，非表面覆盖率。
        a = torch.exp(-((first / position.new_tensor([.33, .44, .36])) ** 2).sum(-1) * 2)
        b = torch.exp(-((second / position.new_tensor([.27, .27, .27])) ** 2).sum(-1) * 2)
        sigma = 15 * a + 19 * b
        inside = (position.abs() <= 1).all(-1)
        sigma = sigma * inside
        base = (a[..., None] * position.new_tensor([.92, .17, .07])
                + b[..., None] * position.new_tensor([.08, .48, .93])) / (a + b + 1e-8)[..., None]
        # 可控的小幅视角相关项；不是现场重新照明，也不改变几何。
        rgb = (base * (.9 + .1 * direction[..., 1:2])
               + .035 * (position + 1)).clamp(0, 1)
        return sigma, rgb


class TinyNeRF(nn.Module):
    """教学 NeRF：位置编码+4层MLP，方向用线性基展开，非原论文全部网络结构。"""
    def __init__(self, levels=4, width=64):
        super().__init__()
        self.levels, self.width = levels, width
        self.register_buffer("frequencies", 2 ** torch.arange(levels).float() * math.pi)
        layers = [nn.Linear(3 + 6 * levels, width), nn.ReLU()]
        for _ in range(3):
            layers.extend([nn.Linear(width, width), nn.ReLU()])
        self.body = nn.Sequential(*layers)
        self.output = nn.Linear(width, 13)
        nn.init.zeros_(self.output.bias)

    def coefficients(self, position):
        # 最后一维布局：原坐标3 | L×3的sin | L×3的cos；邻近位置可有不同频率响应。
        phases = position[..., None, :] * self.frequencies[:, None]
        encoded = torch.cat((position, phases.sin().flatten(-2), phases.cos().flatten(-2)), dim=-1)
        values = self.output(self.body(encoded))
        # 系数布局 [sigma, RGB-logits(3), RGB各自的方向xyz系数(9)]。
        # sigma 只依赖位置。对密度使用 softplus 可避免负消光，同时保留梯度。
        return torch.cat((F.softplus(values[..., :1] - 1), values[..., 1:]), dim=-1)

    @staticmethod
    def decode(coefficients, direction):
        sigma = coefficients[..., 0]
        directional = (coefficients[..., 4:].reshape(*direction.shape[:-1], 3, 3)
                       * direction[..., None, :]).sum(-1)
        rgb = torch.sigmoid(coefficients[..., 1:4] + directional)
        return sigma, rgb

    def forward(self, position, direction):
        sigma, rgb = self.decode(self.coefficients(position), direction)
        return sigma * (position.abs() <= 1).all(-1), rgb


class BakedField:
    """把已训练网络的系数缓存在规则网格；保留方向基，不把固定相机RGB当通用场。"""
    def __init__(self, grid):
        # PyTorch 3D grid_sample 输入为 [N,C,D,H,W]，此处是 [1,13,Z,Y,X]。
        self.grid = grid

    @classmethod
    @torch.no_grad()
    def from_model(cls, model, resolution=64):
        device = next(model.parameters()).device
        axis = torch.linspace(-1, 1, resolution, device=device)
        z, y, x = torch.meshgrid(axis, axis, axis, indexing="ij")
        positions = torch.stack((x, y, z), dim=-1).reshape(-1, 3)
        # 只在此调用已训练模型；绝不调用 AnalyticField 伪造“烘焙NeRF”。
        chunks = [model.coefficients(p) for p in positions.split(32768)]
        grid = torch.cat(chunks).reshape(resolution, resolution, resolution, 13)
        return cls(grid.permute(3, 0, 1, 2).unsqueeze(0).contiguous())

    def __call__(self, position, direction):
        original_shape = position.shape[:-1]
        # 3D输入使用 mode='bilinear' 实际执行三线性插值。
        # grid最后维始终(x,y,z)，align_corners=True对应节点恰位于[-1,1]两个端点。
        coordinates = position.reshape(1, 1, 1, -1, 3)
        values = F.grid_sample(self.grid, coordinates, mode="bilinear",
                               padding_mode="zeros", align_corners=True)
        coefficients = values.reshape(13, -1).T.reshape(*original_shape, 13)
        sigma, rgb = TinyNeRF.decode(coefficients, direction)
        return sigma * (position.abs() <= 1).all(-1), rgb
