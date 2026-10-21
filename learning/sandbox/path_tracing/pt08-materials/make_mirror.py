"""两个独立glTF网格：z=0半宽8的镜面，z=2半宽1的朝下矩形灯。
标准glTF没有本课的常量反射率理想镜面语义；Mirror名称由宿主显式覆盖为教学材质。
基础色仅提供线性R输入，不宣称已实现glTF金属粗糙度模型。
"""
from pathlib import Path
import json, struct
out=Path(__file__).resolve().parent/'results/mirror';out.mkdir(parents=True,exist_ok=True)
data=bytearray();views=[];access=[];meshes=[]
for i,(z,h) in enumerate([(0,8),(2,1)]):
    points=[(-h,-h,z),(h,-h,z),(h,h,z),(-h,h,z)]
    start=len(data)
    for p in points:data.extend(struct.pack('<3f',*p))
    views.append(dict(buffer=0,byteOffset=start,byteLength=48,target=34962))
    access.append(dict(bufferView=len(views)-1,componentType=5126,count=4,type='VEC3',min=[-h,-h,z],max=[h,h,z]))
    start=len(data);data.extend(struct.pack('<6H',*([0,1,2,0,2,3] if i==0 else [0,2,1,0,3,2])))
    views.append(dict(buffer=0,byteOffset=start,byteLength=12,target=34963))
    access.append(dict(bufferView=len(views)-1,componentType=5123,count=6,type='SCALAR'))
    meshes.append(dict(primitives=[dict(attributes={'POSITION':2*i},indices=2*i+1,material=i)]))
scene=dict(asset={'version':'2.0','generator':'PT.8 ideal mirror fixture'},scene=0,scenes=[dict(nodes=[0,1])],nodes=[dict(mesh=0),dict(mesh=1)],meshes=meshes,
    materials=[dict(name='Mirror',pbrMetallicRoughness=dict(baseColorFactor=[.8,.5,.25,1],metallicFactor=1,roughnessFactor=0)),
               dict(name='Lamp',emissiveFactor=[.2,.6,1],pbrMetallicRoughness=dict(baseColorFactor=[0,0,0,1],metallicFactor=0,roughnessFactor=1))],
    buffers=[dict(uri='mirror.bin',byteLength=len(data))],bufferViews=views,accessors=access)
(out/'mirror.bin').write_bytes(data);(out/'mirror.gltf').write_text(json.dumps(scene,indent=2),encoding='utf-8')
