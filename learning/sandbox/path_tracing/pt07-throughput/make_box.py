"""生成封闭[-1,1]^3盒腔：六个向内面共享均匀反射/自发光材质。
几何为真实glTF三角形；积分器的法线与灯采样仍限定于该轴对齐fixture。
"""
from pathlib import Path
import json,struct
out=Path(__file__).resolve().parent/'results/gpu';out.mkdir(parents=True,exist_ok=True)
data=bytearray();views=[];access=[];meshes=[]
for axis in range(3):
    for sign in [-1,1]:
        other=[i for i in range(3) if i!=axis]
        points=[]
        for a,b in [(-1,-1),(1,-1),(1,1),(-1,1)]:
            p=[0.,0.,0.];p[axis]=sign;p[other[0]]=a;p[other[1]]=b;points.append(p)
        start=len(data)
        for p in points:data.extend(struct.pack('<3f',*p))
        views.append(dict(buffer=0,byteOffset=start,byteLength=48,target=34962))
        access.append(dict(bufferView=len(views)-1,componentType=5126,count=4,type='VEC3',min=[min(p[i] for p in points) for i in range(3)],max=[max(p[i] for p in points) for i in range(3)]))
        # 向内绕序：基础叉积方向对x/z轴为正，对y轴为负。
        reverse=(1 if axis!=1 else -1)==sign
        indices=[0,2,1,0,3,2] if reverse else [0,1,2,0,2,3]
        start=len(data);data.extend(struct.pack('<6H',*indices))
        views.append(dict(buffer=0,byteOffset=start,byteLength=12,target=34963))
        access.append(dict(bufferView=len(views)-1,componentType=5123,count=6,type='SCALAR'))
        meshes.append(dict(primitives=[dict(attributes={'POSITION':len(access)-2},indices=len(access)-1,material=0)]))
scene=dict(asset={'version':'2.0','generator':'PT.7 closed diffuse box'},scene=0,scenes=[dict(nodes=list(range(6)))],
    nodes=[dict(mesh=i) for i in range(6)],meshes=meshes,
    materials=[dict(name='Cavity',pbrMetallicRoughness=dict(baseColorFactor=[.6,.4,.2,1],metallicFactor=0,roughnessFactor=1),emissiveFactor=[.1,.2,.3])],
    buffers=[dict(uri='box.bin',byteLength=len(data))],bufferViews=views,accessors=access)
(out/'box.bin').write_bytes(data);(out/'box.gltf').write_text(json.dumps(scene,indent=2),encoding='utf-8')
