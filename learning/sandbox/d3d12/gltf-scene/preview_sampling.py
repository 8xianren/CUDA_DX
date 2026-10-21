"""将D.3真实GPU读回的PPM转成PNG；不重新渲染，不改变颜色，不调用生成式图像工具。"""
from pathlib import Path
from PIL import Image
root = Path(__file__).resolve().parent / 'results' / 'd03'
for folder in ('fixture', 'official'):
    for path in (root / folder).glob('*.ppm'):
        with Image.open(path) as image:
            image.save(path.with_suffix('.png'))
print('Saved GPU readback PNG previews under results/d03')
