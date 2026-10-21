"""PT.8有厚度平行板：玻璃上表面z=0、下表面z=-1，外侧灯z=2/-3。
四个有限平面半宽256；本实验最多16次散射，测试射线均远离侧缘。
没有侧壁，因此不是任意方向均有效的闭合网格；解析平板模型的受限DXR实现。
Top/Bottom的名称由宿主显式映射到介质界面，不声称支持glTF透射扩展。
"""
from pathlib import Path
import json
import struct

out = Path(__file__).resolve().parent / 'results/slab'
out.mkdir(parents=True, exist_ok=True)
data = bytearray()
views, accessors, meshes, materials = [], [], [], []
planes = [('Top', 0, False, [0, 0, 0]),
          ('Bottom', -1, True, [0, 0, 0]),
          ('UpperLamp', 2, True, [.8, .3, .1]),
          ('LowerLamp', -3, False, [.2, .6, 1])]
for i, (name, z, reverse, emission) in enumerate(planes):
    start = len(data)
    for x, y in [(-256, -256), (256, -256), (256, 256), (-256, 256)]:
        data.extend(struct.pack('<3f', x, y, z))
    views.append(dict(buffer=0, byteOffset=start, byteLength=48, target=34962))
    accessors.append(dict(bufferView=2*i, componentType=5126, count=4,
                          type='VEC3', min=[-256, -256, z], max=[256, 256, z]))
    start = len(data)
    data.extend(struct.pack('<6H', *([0, 2, 1, 0, 3, 2] if reverse else [0, 1, 2, 0, 2, 3])))
    views.append(dict(buffer=0, byteOffset=start, byteLength=12, target=34963))
    accessors.append(dict(bufferView=2*i+1, componentType=5123, count=6, type='SCALAR'))
    meshes.append(dict(primitives=[dict(attributes={'POSITION': 2*i}, indices=2*i+1, material=i)]))
    materials.append(dict(name=name, emissiveFactor=emission,
                          pbrMetallicRoughness=dict(baseColorFactor=[0, 0, 0, 1], metallicFactor=0, roughnessFactor=0)))
scene = dict(asset={'version': '2.0', 'generator': 'PT.8 incoherent scalar slab'},
             scene=0, scenes=[dict(nodes=list(range(4)))], nodes=[dict(mesh=i) for i in range(4)],
             meshes=meshes, materials=materials, buffers=[dict(uri='slab.bin', byteLength=len(data))],
             bufferViews=views, accessors=accessors)
(out/'slab.bin').write_bytes(data)
(out/'slab.gltf').write_text(json.dumps(scene, indent=2), encoding='utf-8')
